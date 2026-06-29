#!/usr/bin/env bats
# tests/doctor_pure.bats — testes para funções puras de lib/testable/doctor_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/doctor_pure.sh"
}

@test "fwupdmgr_get_device_count: conta DeviceId no JSON" {
  json='{"Devices":[{"DeviceId":"a"},{"DeviceId":"b"},{"DeviceId":"c"}]}'
  run fwupdmgr_get_device_count "$json"
  [ "$output" = "3" ]
}

@test "fwupdmgr_get_device_count: zero devices" {
  json='{"Devices":[]}'
  run fwupdmgr_get_device_count "$json"
  [ "$output" = "0" ]
}

@test "fwupdmgr_get_device_count: JSON sem DeviceId" {
  json='{}'
  run fwupdmgr_get_device_count "$json"
  [ "$output" = "0" ]
}

@test "fwupdmgr_has_updates: rc=2 => true (sem updates)" {
  run fwupdmgr_has_updates 2
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_has_updates: rc=0 => false (tem updates)" {
  run fwupdmgr_has_updates 0
  [ "$status" -ne 0 ]
}

@test "fwupdmgr_has_updates: rc=1 => false (erro)" {
  run fwupdmgr_has_updates 1
  [ "$status" -ne 0 ]
}

@test "fwupdmgr_is_network_error: detecta DNS failure" {
  run fwupdmgr_is_network_error "could not resolve host: fwupd.org"
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_is_network_error: detecta connection timeout" {
  run fwupdmgr_is_network_error "connection timed out after 30 seconds"
  [ "$status" -eq 0 ]
}

@test "fwupdmgr_is_network_error: não detecta erro de permissão" {
  run fwupdmgr_is_network_error "Permission denied"
  [ "$status" -ne 0 ]
}

@test "btrfs_scrub_state: running" {
  out="Status: running (123456)"
  run btrfs_scrub_state "$out"
  [ "$output" = "running" ]
}

@test "btrfs_scrub_state: finished" {
  out="Status: finished"
  run btrfs_scrub_state "$out"
  [ "$output" = "finished" ]
}

@test "btrfs_scrub_state: error" {
  out="Status: error (uncorrectable)"
  run btrfs_scrub_state "$out"
  [ "$output" = "error" ]
}

@test "btrfs_scrub_state: unknown vira none" {
  out="Status: foobar"
  run btrfs_scrub_state "$out"
  [ "$output" = "none" ]
}

@test "btrfs_scrub_state: sem Status vira none" {
  out="Progress: 50%"
  run btrfs_scrub_state "$out"
  [ "$output" = "none" ]
}

@test "bootctl_update_already_applied: detecta mensagem de já atualizado" {
  run bootctl_update_already_applied "same boot loader version in place already"
  [ "$status" -eq 0 ]
}

@test "bootctl_update_already_applied: não detecta output diferente" {
  run bootctl_update_already_applied "Updated successfully"
  [ "$status" -ne 0 ]
}