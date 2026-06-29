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

@test "arch_audit_affected_count: conta formato moderno" {
  run arch_audit_affected_count <<< $'pkg1 is affected by CVE-2024-1234\npkg2 is affected by CVE-2024-5678'
  [ "$output" = "2" ]
}

@test "arch_audit_affected_count: conta formato Package prefix" {
  run arch_audit_affected_count <<< "Package pkg1 is affected by CVE-2024-1234"
  [ "$output" = "1" ]
}

@test "arch_audit_affected_count: ignora linhas irrelevantes" {
  run arch_audit_affected_count <<< $'nenhum aviso\neverything ok'
  [ "$output" = "0" ]
}

@test "_ai_cli_first_version: retorna primeira linha com dígito" {
  run _ai_cli_first_version <<< $'banner sem versão\nv1.2.3 (abc)\noutra linha'
  [ "$output" = "v1.2.3 (abc)" ]
}

@test "_ai_cli_first_version: falha quando sem dígito" {
  run _ai_cli_first_version <<< "sem versao aqui"
  [ "$status" -ne 0 ]
}

@test "unique_btrfs_mountpoints: dedup por device idêntico (CSV)" {
  run unique_btrfs_mountpoints <<< $'TARGET,SOURCE\n"/","/dev/sda2"\n"/home","/dev/sda2"'
  [ "$output" = "/" ]
}

@test "unique_btrfs_mountpoints: dois devices distintos retornam dois mountpoints" {
  run unique_btrfs_mountpoints <<< $'TARGET,SOURCE\n"/","/dev/sda2"\n"/mnt/data","/dev/sdb1"'
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "days_since_epoch: retorna inteiro para data válida" {
  run days_since_epoch "2026-01-01"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}