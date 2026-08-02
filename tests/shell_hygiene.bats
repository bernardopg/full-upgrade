#!/usr/bin/env bats
# tests/shell_hygiene.bats — invariantes de shell que já causaram bug real.
#
# `cmd | grep -q PADRÃO` é uma armadilha sob `set -o pipefail` (ativo no
# entrypoint): o grep sai no primeiro match e o produtor toma SIGPIPE, então o
# pipeline devolve 141 mesmo com o padrão casando. O `if` lê isso como "não
# casou" — falso negativo silencioso, sem mensagem nenhuma.
#
# Aconteceu de verdade no v3.32.0: `Doctor: TRIM de SSD` reportou "SSD sem
# TRIM" numa máquina com `discard=async` montado, porque `findmnt | tr | grep -q`
# devolvia 141. Herestring (`grep -q PADRÃO <<<"$var"`) não é pipeline e não tem
# o problema.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
}

@test "pipefail: 'produtor | grep -q' com match cedo NÃO devolve 0 (a armadilha)" {
  # Prova que a armadilha é real neste bash, não folclore. Se um dia o bash
  # mudar esse comportamento, este teste avisa que o resto do arquivo perdeu o
  # motivo de existir.
  #
  # O status exato varia com o ambiente: 141 quando o produtor morre de SIGPIPE,
  # 1 quando ele trata o EPIPE e reporta erro de escrita. O que importa é que
  # não é 0 — o padrão casou e o `if` vai ler "não casou".
  run bash -c 'set -uo pipefail
    big="$(printf "MATCH\n"; seq 1 200000)"
    printf "%s\n" "$big" | grep -q "^MATCH$"'
  [ "$status" -ne 0 ]
}

@test "pipefail: herestring com match cedo devolve 0 (a correção)" {
  run bash -c 'set -uo pipefail
    big="$(printf "MATCH\n"; seq 1 200000)"
    grep -q "^MATCH$" <<<"$big"'
  [ "$status" -eq 0 ]
}

@test "fonte: nenhum 'cmd | grep -q' sobrevive em lib/ ou steps.d/" {
  local hits
  hits="$(grep -rnE '\| *grep +-q' \
    "${FU_ROOT}/lib" "${FU_ROOT}/steps.d" \
    "${FU_ROOT}/full-upgrade.sh" "${FU_ROOT}/build.sh" "${FU_ROOT}/install.sh" \
    | grep -vE '^\S+: *#' || true)"
  # `|| grep -q ... <<<` é operador booleano, não pipeline: não conta.
  hits="$(grep -v '<<<' <<<"$hits" | grep -E '[^[:space:]]' || true)"
  if [[ -n "$hits" ]]; then
    echo "use 'grep -q PADRÃO <<<\"\$var\"' em vez de pipeline:"
    echo "$hits"
  fi
  [ -z "$hits" ]
}

# ── mounts_with_discard (extração pura usada pelo Doctor de TRIM) ─────────────

@test "mounts_with_discard: casa discard=async e discard puro" {
  in=$'/ rw,relatime,compress=zstd:3,ssd,discard=async,subvol=/\n/data rw,discard'
  run mounts_with_discard <<<"$in"
  [ "${lines[0]}" = "/" ]
  [ "${lines[1]}" = "/data" ]
}

@test "mounts_with_discard: nodiscard NÃO conta como TRIM" {
  # Substring casaria; token não. É a diferença entre reportar TRIM ativo numa
  # máquina que desligou TRIM de propósito e acertar.
  in=$'/ rw,relatime,nodiscard,subvol=/'
  run mounts_with_discard <<<"$in"
  [ -z "$output" ]
}

@test "mounts_with_discard: sem opção discard => vazio" {
  in=$'/ rw,relatime,compress=zstd:3,ssd,space_cache=v2\n/boot rw,relatime,fmask=0077'
  run mounts_with_discard <<<"$in"
  [ -z "$output" ]
}

@test "mounts_with_discard: dedup de subvolumes do mesmo mount" {
  in=$'/ rw,discard=async\n/ rw,discard=async\n/home rw,discard=async'
  run mounts_with_discard <<<"$in"
  [ "${#lines[@]}" -eq 2 ]
}

# ── doctor_trim_health (regressão do falso positivo do v3.32.0) ───────────────

_fake_ssd_sysblock() {
  # sysfs falso com um NVMe (rotational=0), para o teste não depender do disco
  # real da máquina/CI.
  export FU_SYSBLOCK_DIR="${BATS_TEST_TMPDIR}/sysblock"
  mkdir -p "${FU_SYSBLOCK_DIR}/nvme0n1/queue"
  printf '0\n' >"${FU_SYSBLOCK_DIR}/nvme0n1/queue/rotational"
}

@test "trim_health: discard=async montado => ok mesmo com fstrim.timer parado" {
  QUIET=0 LOG_FILE=/dev/null
  set -o pipefail
  _fake_ssd_sysblock
  has() { [[ "$1" == systemctl || "$1" == findmnt ]]; }
  systemctl() { return 1; }   # fstrim.timer inativo
  findmnt() { printf '%s\n' "/ rw,relatime,compress=zstd:3,ssd,discard=async,subvol=/"; }

  run doctor_trim_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRIM contínuo ativo"* ]]
  [[ "$output" == *"/"* ]]
}

@test "trim_health: fstrim.timer ativo => ok sem olhar mount" {
  QUIET=0 LOG_FILE=/dev/null
  _fake_ssd_sysblock
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 0; }
  findmnt() { return 1; }

  run doctor_trim_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRIM periódico ativo"* ]]
}

@test "trim_health: SSD sem nenhum mecanismo => todo" {
  QUIET=0 LOG_FILE=/dev/null
  set -o pipefail
  _fake_ssd_sysblock
  has() { [[ "$1" == systemctl || "$1" == findmnt ]]; }
  systemctl() { return 1; }
  findmnt() { printf '%s\n' "/ rw,relatime,compress=zstd:3,ssd,space_cache=v2"; }

  run doctor_trim_health
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"sem mecanismo de TRIM ativo"* ]]
}

@test "trim_health: máquina só com disco rotacional => não aplicável" {
  QUIET=0 LOG_FILE=/dev/null
  export FU_SYSBLOCK_DIR="${BATS_TEST_TMPDIR}/sysblock-hdd"
  mkdir -p "${FU_SYSBLOCK_DIR}/sda/queue"
  printf '1\n' >"${FU_SYSBLOCK_DIR}/sda/queue/rotational"

  run doctor_trim_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum SSD/NVMe detectado"* ]]
}
