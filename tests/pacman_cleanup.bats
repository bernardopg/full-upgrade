#!/usr/bin/env bats
# tests/pacman_cleanup.bats — regressões de cleanup de órfãos

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"; source "${FU_LIB}/steps/cleanup.sh"
  ASSUME_YES=1
  ORPHAN_CALLS_FILE="$BATS_TEST_TMPDIR/orphan_calls"
  printf '0' >"$ORPHAN_CALLS_FILE"
  RUN_LOGGED_FILE="$BATS_TEST_TMPDIR/run_logged_calls"
  : >"$RUN_LOGGED_FILE"
  export ORPHAN_CALLS_FILE RUN_LOGGED_FILE
  eval 'run_logged() { printf "%s\n" "$*" >>"$RUN_LOGGED_FILE"; return 0; }'
  eval 'log() { :; }'
  # Isola do host: um pacman rodando de verdade não pode mudar o resultado.
  eval 'pacman_db_is_locked() { return 1; }'
}

pacman() {
  if [[ "$1" == "-Qdtq" ]]; then
    local calls
    calls="$(<"$ORPHAN_CALLS_FILE")"
    calls=$(( calls + 1 ))
    printf '%s' "$calls" >"$ORPHAN_CALLS_FILE"
    case "$calls" in
      1) printf 'pkg-a\n' ;;
      2) printf 'pkg-b\n' ;;
      *) return 0 ;;
    esac
    return 0
  fi
  return 1
}

run_logged() {
  RUN_LOGGED_CALLS+="$*"$'\n'
  return 0
}

log() { :; }

@test "cleanup_orphans: repete até não surgirem novos órfãos" {
  cleanup_orphans

  calls="$(<"$ORPHAN_CALLS_FILE")"
  logged="$(<"$RUN_LOGGED_FILE")"
  [ "$calls" -eq 3 ]
  [[ "$logged" == *"sudo pacman -Rns --noconfirm -- pkg-a"* ]]
  [[ "$logged" == *"sudo pacman -Rns --noconfirm -- pkg-b"* ]]
}

@test "cleanup_orphans: base bloqueada vira RC_WARN sem chamar pacman -Rns" {
  pacman_db_is_locked() { return 0; }
  STEP_REASON=""
  cleanup_orphans || status=$?

  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *db.lck* ]]
  [ ! -s "$RUN_LOGGED_FILE" ]
}

@test "pacman_release_stale_lock: sem gerenciador rodando remove o lock via sudo -n" {
  local db="$BATS_TEST_TMPDIR/db"
  mkdir -p "$db"; : >"$db/db.lck"
  pacman-conf() { printf '%s/\n' "$db"; }
  pgrep() { return 1; }
  sudo() { [[ "$1" == -n ]] && shift; "$@"; }
  pacman_release_stale_lock

  [ ! -e "$db/db.lck" ]
}

@test "pacman_release_stale_lock: gerenciador ainda rodando mantém o lock" {
  local db="$BATS_TEST_TMPDIR/db"
  mkdir -p "$db"; : >"$db/db.lck"
  pacman-conf() { printf '%s/\n' "$db"; }
  pgrep() { return 0; }
  sleep() { :; }
  sudo() { echo "sudo não deveria rodar" >&2; return 9; }
  pacman_release_stale_lock

  [ -e "$db/db.lck" ]
}
