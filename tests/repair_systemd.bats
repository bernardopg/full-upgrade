#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  source "${FU_LIB}/steps/doctor.sh"
  source "${FU_LIB}/steps/repair.sh"
  QUIET=0 LOG_FILE=/dev/null
}

@test "repair_stale_user_app_scopes: limpa somente app scopes" {
  local calls="${BATS_TEST_TMPDIR}/calls"
  export calls
  has() { [[ "$1" == systemctl ]]; }
  systemd_user_scope_status() { printf 'available'; }
  systemctl() {
    if [[ "$*" == "--user --failed --plain --no-legend" ]]; then
      printf '%s\n' \
        'app-orca-87907.scope loaded failed failed app-orca-87907.scope' \
        'real.service loaded failed failed real.service'
      return 0
    fi
    printf '%s\n' "$*" >> "$calls"
  }

  run repair_stale_user_app_scopes
  [ "$status" -eq 0 ]
  [ "$(<"$calls")" = "--user reset-failed app-orca-87907.scope" ]
  ! grep -q 'real.service' "$calls"
}

@test "repair_coredump_obsolete_keys: remove só chaves inválidas e cria backup" {
  local conf="${BATS_TEST_TMPDIR}/limit.conf"
  cat > "$conf" <<'EOF'
[Coredump]
MaxUse=200M
MaxAge=1week
Keep=no
EOF
  COREDUMP_CONFIG_PATHS="$conf"
  sudo() { [[ "$1" == "-n" ]] && shift; "$@"; }
  export COREDUMP_CONFIG_PATHS

  run repair_coredump_obsolete_keys
  [ "$status" -eq 0 ]
  grep -q '^MaxUse=200M$' "$conf"
  ! grep -q '^MaxAge=' "$conf"
  ! grep -q '^Keep=' "$conf"
  compgen -G "${conf}.full-upgrade.bak.*" >/dev/null
}
