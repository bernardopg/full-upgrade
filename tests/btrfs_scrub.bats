#!/usr/bin/env bats
# tests/btrfs_scrub.bats — auto-remediação de scrub btrfs (G1).
#
# btrfs_scrub_state é puro (parser de texto + data) e testado com fixtures.
# autofix_btrfs_scrub orquestra sudo/btrfs; os testes isolam o sistema stubando
# has/findmnt/_doctor_sudo_ok/sudo/run_logged e validam a máquina de estados.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
  QUIET=0
  AUTO_BTRFS_SCRUB=1
  ASSUME_YES=1
  BTRFS_SCRUB_MAX_DAYS=30
  STEP_REASON=""
  # Stubs default: ferramentas presentes, 1 mountpoint btrfs (/ em /dev/sda2),
  # sudo ok, mutações no-op. findmnt emite "TARGET SOURCE" (formato list_btrfs).
  has() { return 0; }
  findmnt() { printf '/ /dev/sda2\n'; }
  _doctor_sudo_ok() { return 0; }
  run_logged() { return 0; }
  # sudo emite o status de scrub do fixture corrente (sobrescrito por teste).
  SCRUB_FIXTURE="no stats available"
  sudo() { printf '%s\n' "$SCRUB_FIXTURE"; }
}

# ── helper puro unique_btrfs_mountpoints ─────────────────────────────────────

@test "unique: 1 mountpoint passa intacto" {
  out="$(printf '%s\n' '/ /dev/sda2' | unique_btrfs_mountpoints)"
  [ "$out" = "/" ]
}

@test "unique: subvolumes do mesmo dispositivo são dedupados" {
  out="$(printf '%s\n' '/ /dev/sda2' '/home /dev/sda2[/@home]' '/.snapshots /dev/sda2[/@snapshots]' | unique_btrfs_mountpoints | sort)"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]
  [ "$out" = "/" ]
}

@test "unique: dispositivos distintos são mantidos" {
  out="$(printf '%s\n' '/ /dev/sda2' '/mnt/data /dev/sdb1' | unique_btrfs_mountpoints | sort | paste -sd,)"
  [ "$out" = "/,/mnt/data" ]
}

@test "unique: linha sem source é ignorada" {
  out="$(printf '%s\n' '/' '/ /dev/sda2' | unique_btrfs_mountpoints)"
  [ "$out" = "/" ]
}

# ── helper puro btrfs_scrub_state ─────────────────────────────────────────────

@test "state: 'no stats available' => never" {
  run btrfs_scrub_state "no stats available for /" 30
  [ "$output" = "never" ]
}

@test "state: scrub antigo => due:<dias>" {
  local old; old="$(LC_ALL=C date -d '90 days ago' '+%a %b %d %T %Y')"
  run btrfs_scrub_state "Scrub started:    $old" 30
  [[ "$output" == due:* ]]
  [ "${output#due:}" -ge 89 ]
}

@test "state: scrub recente => ok:<dias>" {
  local recent; recent="$(LC_ALL=C date -d '2 days ago' '+%a %b %d %T %Y')"
  run btrfs_scrub_state "Scrub started:    $recent" 30
  [[ "$output" == ok:* ]]
  [ "${output#ok:}" -le 3 ]
}

@test "state: texto sem data => unknown" {
  run btrfs_scrub_state "scrub status: running, 12% done" 30
  [ "$output" = "unknown" ]
}

# ── máquina de estados autofix_btrfs_scrub ────────────────────────────────────

@test "autofix: off-switch retorna 0 sem agir" {
  AUTO_BTRFS_SCRUB=0
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [[ "$output" == *"desligado"* ]]
}

@test "autofix: nenhum btrfs montado retorna 0" {
  findmnt() { :; }
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum filesystem btrfs"* ]]
}

@test "autofix: sem sudo sem prompt vira RC_TODO" {
  _doctor_sudo_ok() { return 1; }
  run autofix_btrfs_scrub
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"sudo"* ]]
}

@test "autofix: scrub recente não dispara nada (RC 0)" {
  local recent; recent="$(LC_ALL=C date -d '1 day ago' '+%a %b %d %T %Y')"
  SCRUB_FIXTURE="Scrub started:    $recent"
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a fazer"* ]]
}

@test "autofix: scrub ausente + --yes inicia (RC 0)" {
  SCRUB_FIXTURE="no stats available"
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scrub iniciado"* ]]
}

@test "autofix: scrub vencido + --yes inicia (RC 0)" {
  local old; old="$(LC_ALL=C date -d '120 days ago' '+%a %b %d %T %Y')"
  SCRUB_FIXTURE="Scrub started:    $old"
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scrub iniciado"* ]]
}

@test "autofix: não interativo sem --yes vira RC_TODO" {
  ASSUME_YES=0
  # bats roda sem TTY em stdin, então [[ -t 0 ]] é falso => ramo não interativo.
  run autofix_btrfs_scrub
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"não interativa"* ]]
}

@test "autofix: falha ao iniciar scrub vira RC_WARN" {
  run_logged() { return 1; }
  run autofix_btrfs_scrub
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falhou em 1"* ]]
}

# ── J3: multi-mount ──────────────────────────────────────────────────────────

@test "autofix: 2 mountpoints, ambos nunca-scrubbed => inicia nos 2" {
  findmnt() { printf '/ /dev/sda2\n/mnt/data /dev/sdb1\n'; }
  sudo() { printf '%s\n' "$SCRUB_FIXTURE"; }
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Iniciando scrub em')" -eq 2 ]
  [[ "$output" == *"2 mountpoint(s)"* ]]
}

@test "autofix: 2 subvolumes do mesmo device => scrub só 1 vez" {
  # / e /home são o mesmo dispositivo (/dev/sda2) => 1 scrub apenas.
  findmnt() { printf '/ /dev/sda2\n/home /dev/sda2[/@home]\n'; }
  sudo() { printf '%s\n' "$SCRUB_FIXTURE"; }
  run autofix_btrfs_scrub
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Iniciando scrub em')" -eq 1 ]
}
