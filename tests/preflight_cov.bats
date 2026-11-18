#!/usr/bin/env bats
# tests/preflight_cov.bats — lock do run (lockfile não abrível, outra instância
# segurando o flock) e keyring (base travada depois do -Sy, fallback pelo DB em
# cache). XDG_RUNTIME_DIR descartável; pacman/sudo stubados.

load test_helper
load stub_helper

setup() {
  FLOCK_REAL="$(type -P flock)"
  load_libs
  source "${FU_LIB}/steps/pacman.sh"
  source "${FU_LIB}/steps/preflight.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"; mkdir -p "$XDG_RUNTIME_DIR"
}

@test "lock: lockfile não abrível segue sem lock" {
  XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/nao-existe" run acquire_run_lock
  [ "$status" -eq 0 ]
  [[ "$output" == *"seguindo sem lock"* ]]
}

@test "lock: outra instância segurando o flock vira TODO com o pid" {
  ln -s "$FLOCK_REAL" "$STUB_SAFE/flock"; hash -r
  echo 4242 > "$XDG_RUNTIME_DIR/full-upgrade.lock"
  "$FLOCK_REAL" "$XDG_RUNTIME_DIR/full-upgrade.lock" sleep 10 &
  sleep 0.3
  acquire_run_lock >/dev/null || status=$?
  kill %1 2>/dev/null || true
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "outra instância em execução (pid 4242)" ]
}

@test "keyring: base travada depois do sync e fallback pelo DB em cache" {
  SUDO_READY=1
  stub_privilege
  stub_script pacman 'case "$1" in -Sy) [[ -n "${LOCK_AFTER:-}" ]] && touch "$BATS_TEST_TMPDIR/db/db.lck"; exit 1 ;; -S) exit 0 ;; esac'
  stub pacman-conf 0 "$BATS_TEST_TMPDIR/db/"
  mkdir -p "$BATS_TEST_TMPDIR/db"
  run update_archlinux_keyring
  [ "$status" -eq 0 ]
  [[ "$output" == *"archlinux-keyring OK (via DB em cache)"* ]]
  LOCK_AFTER=1 update_archlinux_keyring >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "banco do pacman bloqueado durante atualização do keyring" ]
}
