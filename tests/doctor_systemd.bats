#!/usr/bin/env bats
# tests/doctor_systemd.bats — regressões de auditoria systemd --user

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
}

@test "systemd_user_scope_status: sem XDG_RUNTIME_DIR é parcial" {
  unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "no-runtime" ]
}

@test "systemd_user_scope_status: runtime sem bus é parcial" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  unset DBUS_SESSION_BUS_ADDRESS
  mkdir -p "$XDG_RUNTIME_DIR"

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "no-bus" ]
}

@test "systemd_user_scope_status: bus por env torna checagem disponível" {
  unset XDG_RUNTIME_DIR
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$BATS_TEST_TMPDIR/bus"

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "available" ]
}

@test "systemd_user_scope_status: bus padrão no runtime torna checagem disponível" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  unset DBUS_SESSION_BUS_ADDRESS
  mkdir -p "$XDG_RUNTIME_DIR"
  touch "$XDG_RUNTIME_DIR/bus"

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "available" ]
}

# ── doctor_failed_systemd_units: reclassificação de app-autostart ──────────────
# Units app-<nome>@autostart.service são geradas pelo systemd-xdg-autostart-
# generator (a partir de .desktop em ~/.config/autostart) com Restart=no. Ficam
# "failed" quando o app de sessão é fechado/KILLado — artefato do generator, não
# serviço quebrado. Se só há app-autostart, vira informativo (rc 0, não RC_TODO).

_setup_failed_units() {
  # $1 = saída de `systemctl --failed` (sistema); $2 = saída --user
  # Mocka systemctl e systemd_user_scope_status (que lê env/socket).
  has() { [[ "$1" == systemctl ]]; }
  systemctl() {
    # O doctor chama: systemctl --failed ...  e  systemctl --user --failed ...
    if [[ "$1" == "--user" ]]; then
      printf '%s' "$_MOCK_USER_FAILED"
    else
      printf '%s' "$_MOCK_SYS_FAILED"
    fi
  }
  systemd_user_scope_status() { printf 'available'; }
  export _MOCK_SYS_FAILED="$1" _MOCK_USER_FAILED="$2"
}

@test "failed_units: sem units falhadas => rc 0" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma unit systemd falhada"* ]]
}

@test "failed_units: unit de serviço real falhada => RC_TODO" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" "nginx.service loaded failed failed failed"
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"nginx.service"* ]]
}

@test "failed_units: só app-autostart => rc 0 (informativo, não TODO)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" "app-9router@autostart.service loaded failed failed 9Router"
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"app(s) de autostart em estado failed"* ]]
  [[ "$output" == *"app-9router@autostart.service"* ]]
  [[ "$output" == *"Nenhuma unit de serviço real falhada"* ]]
}

@test "failed_units: app-autostart + unit real => RC_TODO (a real prevalece)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" \
    $'app-foo@autostart.service loaded failed failed Foo\nnginx.service loaded failed failed failed'
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"nginx.service"* ]]
  [[ "$output" == *"app-foo@autostart.service"* ]]
}

@test "failed_units: unit de sistema falhada + app-autostart => RC_TODO" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "docker.service loaded failed failed failed" \
    "app-bar@autostart.service loaded failed failed Bar"
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"docker.service"* ]]
}
