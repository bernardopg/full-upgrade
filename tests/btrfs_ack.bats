#!/usr/bin/env bats
setup() {
  load test_helper
  load_libs
  source "${FU_LIB}/steps/doctor/storage.sh"
  UUID='d0671dec-2072-43fc-9ae1-0ca1d13ab5ec'
  STATS=$'[/dev/nvme0n1p2].write_io_errs 0\n[/dev/nvme0n1p2].read_io_errs 0\n[/dev/nvme0n1p2].flush_io_errs 0\n[/dev/nvme0n1p2].corruption_errs 28\n[/dev/nvme0n1p2].generation_errs 0'
  has() { return 0; }
  findmnt() { if [[ "$*" == *UUID* ]]; then printf '%s\n' "$UUID"; else printf 'btrfs\n'; fi; }
  _doctor_sudo_ok() { return 0; }
  SCRUB_STATE='ok:4'
  btrfs_scrub_state() { printf '%s' "$SCRUB_STATE"; }
  sudo() { if [[ "$*" == *'device stats'* ]]; then printf '%s\n' "$STATS"; else printf 'scrub fixture\n'; fi; }
  STEP_REASON=''
  BTRFS_DEVICE_STATS_ACK_SHA256=''
}

@test "Btrfs: contadores positivos sem reconhecimento mantêm TODO" {
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: baseline exato reconhecido não zera contadores e mantém nota" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  doctor_btrfs_health && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
  [[ "$STEP_REASON" == *'histórico reconhecido'* ]]
  [[ "$STATS" == *'corruption_errs 28'* ]]
}

@test "Btrfs: incremento após baseline volta a TODO" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  STATS="${STATS/corruption_errs 28/corruption_errs 29}"
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: alteração compensada de contadores não é ocultada por soma igual" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  STATS="${STATS/corruption_errs 28/corruption_errs 27}"
  STATS="${STATS/read_io_errs 0/read_io_errs 1}"
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: outro filesystem não herda reconhecimento" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  UUID='00000000-0000-0000-0000-000000000000'
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: scrub com erro continua TODO apesar do baseline" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  SCRUB_STATE=errors
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: erro ao consultar stats não é ocultado pelo baseline" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  sudo() { if [[ "$*" == *'device stats'* ]]; then printf '%s\n' "$STATS"; return 1; else printf 'scrub fixture\n'; fi; }
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: novo erro após reset de stats não reutiliza baseline antigo" {
  BTRFS_DEVICE_STATS_ACK_SHA256="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  STATS="${STATS/corruption_errs 28/corruption_errs 1}"
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
}

@test "Btrfs: fingerprint recusa estatísticas parciais e duplicadas" {
  run btrfs_device_stats_fingerprint "$UUID" '[/dev/nvme0n1p2].corruption_errs 28'
  [ "$status" -ne 0 ]
  run btrfs_device_stats_fingerprint "$UUID" "$STATS"$'\n[/dev/nvme0n1p2].corruption_errs 28'
  [ "$status" -ne 0 ]
}

@test "Btrfs: fingerprint normaliza ordem e espaços" {
  expected="$(btrfs_device_stats_fingerprint "$UUID" "$STATS")"
  reordered="$(printf '%s\n' "$STATS" | sort -r)"
  reordered="${reordered// /   }"
  run btrfs_device_stats_fingerprint "$UUID" "$reordered"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
