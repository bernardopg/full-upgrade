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
