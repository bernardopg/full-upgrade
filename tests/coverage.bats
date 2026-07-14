#!/usr/bin/env bats
# tests/coverage.bats — funções puras de lib/steps/coverage.sh.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/coverage.sh"
}

@test "mirror_is_fresh: mirrorlist recente (1 dia) é fresco com limite 7" {
  now=1000000000
  mtime=$(( now - 86400 ))      # 1 dia atrás
  run mirror_is_fresh "$mtime" "$now" 7
  [ "$status" -eq 0 ]
}

@test "mirror_is_fresh: mirrorlist antigo (10 dias) não é fresco com limite 7" {
  now=1000000000
  mtime=$(( now - 10 * 86400 ))
  run mirror_is_fresh "$mtime" "$now" 7
  [ "$status" -ne 0 ]
}

@test "mirror_is_fresh: limite 0 nunca é fresco (roteia sempre)" {
  run mirror_is_fresh 999999999 1000000000 0
  [ "$status" -ne 0 ]
}

@test "mirror_is_fresh: entradas não-numéricas => não-fresco" {
  run mirror_is_fresh "abc" 1000000000 7
  [ "$status" -ne 0 ]
}

@test "mirror_is_fresh: exatamente no limite (7 dias) já não é fresco" {
  now=1000000000
  mtime=$(( now - 7 * 86400 ))   # delta == 7d == limite; '<' estrito => não-fresco
  run mirror_is_fresh "$mtime" "$now" 7
  [ "$status" -ne 0 ]
}

@test "timeshift: progresso acima de 100 fica só no log, terminal mostra resumo" {
  SNAPSHOT_TOOL=timeshift
  SNAPSHOT_MIN_FREE_GIB=0
  QUIET=0
  has() { [[ "$1" == timeshift ]]; }
  findmnt() { printf 'btrfs\n'; }
  sudo() { printf '100.93%% complete\r107.20%% complete\rRSYNC Snapshot saved successfully (2s)\n'; }

  run preupgrade_snapshot

  [ "$status" -eq 0 ]
  [[ "$output" == *"Snapshot saved successfully (2s)"* ]]
  [[ "$output" != *"100.93"* ]]
  [[ "$output" != *"107.20"* ]]
}

@test "timeshift_terminal_output: remove aviso de rotação após snapshot bem-sucedido" {
  run timeshift_terminal_output <<< $'Snapshot saved successfully\nMaximum backups exceeded for backup level daily\nfinalizado'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Snapshot saved successfully"* ]]
  [[ "$output" == *"finalizado"* ]]
  [[ "$output" != *"Maximum backups exceeded"* ]]
}

# ── update_archlinux_keyring ──────────────────────────────────────────────────

@test "keyring: pacman ausente => 0 sem chamar sudo" {
  has() { return 1; }
  QUIET=0
  run update_archlinux_keyring
  [ "$status" -eq 0 ]
  [[ "$output" == *"pacman ausente"* ]]
}

@test "keyring: sudo indisponível (SUDO_READY=0) => 0 com aviso" {
  has() { [[ "$1" == pacman ]]; }
  SUDO_READY=0
  QUIET=0
  run update_archlinux_keyring
  [ "$status" -eq 0 ]
  [[ "$output" == *"sudo indisponível"* ]]
}

@test "keyring: sudo ok e pacman ok => 0 e mensagem de atualizado" {
  has() { [[ "$1" == pacman ]]; }
  SUDO_READY=1
  run_logged() { return 0; }
  QUIET=0
  run update_archlinux_keyring
  [ "$status" -eq 0 ]
  [[ "$output" == *"atualizado"* ]]
}

@test "keyring: falha do pacman => RC_WARN" {
  has() { [[ "$1" == pacman ]]; }
  SUDO_READY=1
  run_logged() { return 1; }
  QUIET=0
  run update_archlinux_keyring
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Aviso"* ]]
}
