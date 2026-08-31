#!/usr/bin/env bats
# tests/timeshift_cloud.bats — política do backup off-site de snapshots Timeshift.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cloud_backup.sh"
}

@test "timeshift cloud: retenção padrão e inválida mantêm 3 versões" {
  unset TIMESHIFT_CLOUD_KEEP
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  TIMESHIFT_CLOUD_KEEP=0
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "timeshift cloud: retenção configurada é preservada" {
  TIMESHIFT_CLOUD_KEEP=7
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "timeshift cloud: seleciona o snapshot Timeshift mais recente" {
  local root="${BATS_TEST_TMPDIR}/top"
  mkdir -p \
    "${root}/timeshift-btrfs/snapshots/2026-08-30_10-00-00/@" \
    "${root}/timeshift-btrfs/snapshots/2026-08-31_13-00-00/@"

  run timeshift_cloud_latest_name "$root"

  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-31_13-00-00" ]
}

@test "timeshift cloud: sem snapshots retorna falha limpa" {
  local root="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "$root"

  run timeshift_cloud_latest_name "$root"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "timeshift cloud: modo desligado é no-op" {
  TIMESHIFT_CLOUD_BACKUP=0
  run backup_timeshift_cloud

  [ "$status" -eq 0 ]
}
