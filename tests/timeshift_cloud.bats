#!/usr/bin/env bats
# tests/timeshift_cloud.bats — política do backup off-site de snapshots Timeshift.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cloud_backup.sh"
}

@test "timeshift cloud: retenção padrão e inválida mantêm 3 versões" {
  unset TIMESHIFT_CLOUD_KEEP
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  TIMESHIFT_CLOUD_KEEP=0
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "timeshift cloud: retenção configurada é preservada" {
  TIMESHIFT_CLOUD_KEEP=7
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "timeshift cloud: seleciona o snapshot Timeshift mais recente" {
  local root="${BATS_TEST_TMPDIR}/top"
  mkdir -p \
    "${root}/timeshift-btrfs/snapshots/2026-08-30_10-00-00/@" \
    "${root}/timeshift-btrfs/snapshots/2026-08-31_13-00-00/@"

  run timeshift_cloud_latest_name "$root"

  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-31_13-00-00" ]
}

@test "timeshift cloud: sem snapshots retorna falha limpa" {
  local root="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "$root"

  run timeshift_cloud_latest_name "$root"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "timeshift cloud: modo desligado é no-op" {
  TIMESHIFT_CLOUD_BACKUP=0
  run backup_timeshift_cloud

  [ "$status" -eq 0 ]
}

# ── Reparo de posse do rclone.conf na ENTRADA do step ────────────────────────
# Regressão real: o rclone roda sob sudo e reescreve o rclone.conf ao renovar o
# token, deixando-o root-owned. O chown de volta só existia no FIM do step, de
# modo que um run interrompido entre a reescrita e o conserto travava o backup
# para sempre: a guarda de credenciais barrava com "credenciais ausentes" antes
# de a linha de conserto ser alcançada, e só este step conserta.
@test "timeshift cloud: rclone.conf ilegível dispara chown antes da guarda" {
  # root lê arquivo 000 e o reparo nunca dispararia: o cenário não existe.
  [ "$(id -u)" -ne 0 ] || skip "root ignora o modo 000 que este teste depende"

  local cfg="${BATS_TEST_TMPDIR}/rclone.conf"
  local pwf="${BATS_TEST_TMPDIR}/restic-pass"
  local marker="${BATS_TEST_TMPDIR}/chown-chamado"
  printf 'segredo\n' >"$pwf"
  printf '[onedrive]\n' >"$cfg"
  chmod 000 "$cfg"

  # As guardas de dependência e de Btrfs vêm antes do reparo de posse: sem os
  # stubs, uma máquina sem restic/rclone/timeshift (todo runner de CI) sai do
  # step em RC_TODO e o trecho sob teste nunca roda — foi assim que este teste
  # passou localmente e quebrou no CI.
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  local tool
  for tool in restic rclone timeshift; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${bin}/${tool}"
    chmod +x "${bin}/${tool}"
  done
  # FSTYPE precisa dizer btrfs; SOURCE volta vazio de propósito para encerrar o
  # step logo depois do trecho sob teste, sem montar nada.
  cat >"${bin}/findmnt" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" FSTYPE "* ]] && { printf 'btrfs\n'; exit 0; }
exit 0
STUB
  chmod +x "${bin}/findmnt"
  PATH="${bin}:${PATH}"

  # Stub de sudo: registra o chown pedido e o executa de verdade no tmpdir.
  sudo() {
    if [[ "$1" == "-n" && "$2" == "chown" ]]; then
      printf '%s\n' "$4" >>"$marker"
      chmod 600 "$4"
      return 0
    fi
    return 1
  }
  export -f sudo 2>/dev/null || true

  TIMESHIFT_CLOUD_BACKUP=1 \
  TIMESHIFT_CLOUD_REPOSITORY="rclone:teste:repo" \
  TIMESHIFT_CLOUD_PASSWORD_FILE="$pwf" \
  TIMESHIFT_CLOUD_RCLONE_CONFIG="$cfg" \
    run backup_timeshift_cloud

  # O chown foi tentado no arquivo certo — é o que este teste protege.
  [ -s "$marker" ]
  grep -qF "$cfg" "$marker"
  # E o step não pode mais fechar com "credenciais ausentes" por posse.
  [[ "$output" != *"credenciais Restic/rclone ausentes"* ]]
}
