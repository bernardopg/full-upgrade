#!/usr/bin/env bats
# tests/firmware_pure.bats — testes para funções puras de lib/testable/firmware_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/firmware_pure.sh"
}

@test "fwupdmgr_get_device_count: conta DeviceId no JSON (uma por linha)" {
  json=$'"DeviceId": "a",\n"DeviceId": "b",'
  run fwupdmgr_get_device_count "$(printf '%b' "$json")"
  [ "$output" = "2" ]
}

@test "fwupdmgr_get_device_count: zero devices" {
  run fwupdmgr_get_device_count '{"Devices":[]}'
  [ "$output" = "0" ]
}

@test "fwupdmgr_get_device_count: JSON sem DeviceId" {
  run fwupdmgr_get_device_count '{}'
  [ "$output" = "0" ]
}

@test "fwupdmgr_has_updates: rc=2 => true (nenhuma atualização)" {
  run fwupdmgr_has_updates 2
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_has_updates: rc=0 => false (tem atualizações)" {
  run fwupdmgr_has_updates 0
  [ "$status" -ne 0 ]
}

@test "fwupdmgr_has_updates: rc=1 => false (erro)" {
  run fwupdmgr_has_updates 1
  [ "$status" -ne 0 ]
}

@test "fwupdmgr_is_network_error: detecta could not resolve" {
  run fwupdmgr_is_network_error "could not resolve host: fwupd.org"
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_is_network_error: detecta connection timed out" {
  run fwupdmgr_is_network_error "connection timed out after 30 seconds"
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_is_network_error: detecta connection refused" {
  run fwupdmgr_is_network_error "connection refused"
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_is_network_error: não detecta erro de permissão" {
  run fwupdmgr_is_network_error "Permission denied"
  [ "$status" -ne 0 ]
}

@test "bootctl_update_already_applied: detecta mensagem de já atualizado" {
  run bootctl_update_already_applied "same boot loader version in place already"
  [ "$status" -eq 0 ]
}

@test "bootctl_update_already_applied: não detecta output diferente" {
  run bootctl_update_already_applied "Updated successfully"
  [ "$status" -ne 0 ]
}

@test "bootctl_is_installed: rc 0 quando bootctl confirma instalação" {
  bootctl() { [[ "$1" == is-installed ]]; }
  run bootctl_is_installed
  [ "$status" -eq 0 ]
}

@test "bootctl_is_installed: propaga rc não-zero sem depender do host" {
  bootctl() { return 1; }
  run bootctl_is_installed
  [ "$status" -eq 1 ]
}
