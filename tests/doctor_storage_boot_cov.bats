#!/usr/bin/env bats
# tests/doctor_storage_boot_cov.bats — Doctors de disco, SMART/NVMe, systemd-boot
# e tempo de boot com df, smartctl, nvme, bootctl, findmnt e systemd-analyze
# stubados. PATH isolado: nenhum comando real de disco ou boot é executado.

load test_helper
load stub_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
}

# ── doctor_disk_health ────────────────────────────────────────────────────────

_df_usage() {
  # $1 = uso de / (%), $2 = uso de inodes de / (%)
  stub_script df "case \"\$1\" in
    -Pi) printf 'Fs I IU IF IUse Mounted\n/dev/x 100 $2 1 $2%% /\n' ;;
    -P) printf 'Fs 1K Used Avail Cap Mounted\n/dev/x 100 $1 1 $1%% /\n' ;;
    *) printf 'Fs Size Used Avail Use Mounted\n/dev/x 1G 1G 0 1%% /\n' ;;
  esac"
}

@test "disk_health: sem df não checa; níveis normais => ok" {
  run doctor_disk_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"df não encontrado"* ]]
  _df_usage 40 10
  run doctor_disk_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"níveis aceitáveis"* ]]
}

@test "disk_health: espaço crítico => TODO; inodes altos => warn" {
  _df_usage 97 10
  doctor_disk_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  unset status
  _df_usage 40 92
  doctor_disk_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

# ── doctor_smart_health ───────────────────────────────────────────────────────

@test "smart_health: sem sudo pula; sem ferramentas avisa" {
  run doctor_smart_health
  [[ "$output" == *"requerem sudo sem prompt"* ]]
  stub_privilege
  run doctor_smart_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"smartctl e nvme não encontrados"* ]]
}

@test "smart_health: SMART FAILED => TODO; setores realocados => warn; NVMe ok e com aviso" {
  stub_privilege
  stub_script smartctl 'case "$*" in
    --scan) echo "/dev/sda -d sat" ;;
    "-H /dev/sda") echo "SMART overall-health self-assessment test result: FAILED!" ;;
    "-A /dev/sda") printf "  5 Reallocated_Sector_Ct 0x0033 100 100 010 Pre-fail Always - 12\n198 Offline_Uncorrectable 0x0010 100 100 000 Old_age Offline - 3\n" ;;
  esac'
  stub_script nvme 'case "$*" in
    list) printf "Node SN\n---- --\n/dev/nvme0n1 X\n/dev/nvme1n1 Y\n" ;;
    "smart-log /dev/nvme0n1") printf "critical_warning : 0\navail_spare : 100%%\n" ;;
    "smart-log /dev/nvme1n1") printf "critical_warning : 0x4\n" ;;
  esac'
  doctor_smart_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "/dev/sda: SMART FAILED!"* ]]
}

@test "smart_health: scan vazio e disco saudável" {
  stub_privilege
  stub smartctl 0 ""
  run doctor_smart_health
  [[ "$output" == *"nenhum disco encontrado"* ]]
  stub_script smartctl 'case "$*" in --scan) echo "/dev/sda -d sat" ;; "-H /dev/sda") echo "SMART overall-health self-assessment test result: PASSED" ;; esac'
  run doctor_smart_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"saúde SMART OK (PASSED)"* ]]
}

# ── doctor_boot_health ────────────────────────────────────────────────────────

_bootctl_status() {
  stub_script bootctl "case \"\$*\" in
    is-installed) exit \${BOOT_INSTALLED_RC:-0} ;;
    status) printf '  Default Boot Loader Entry:\n         title: Arch Linux\n         linux: $1/vmlinuz-linux\n        initrd: $1/initramfs-linux.img\n' ;;
  esac"
}

@test "boot_health: sem bootctl, sem sudo e sem systemd-boot pulam" {
  run doctor_boot_health
  [[ "$output" == *"bootctl não encontrado"* ]]
  stub bootctl 0
  run doctor_boot_health
  [[ "$output" == *"requer sudo sem prompt"* ]]
  stub_privilege
  BOOT_INSTALLED_RC=1 _bootctl_status /boot
  BOOT_INSTALLED_RC=1 run doctor_boot_health
  [[ "$output" == *"systemd-boot não instalado"* ]]
}

@test "boot_health: kernel/initrd presentes, fallback ausente e ESP cheio" {
  stub_privilege
  esp="$BATS_TEST_TMPDIR/esp"; mkdir -p "$esp"
  touch "$esp/vmlinuz-linux" "$esp/initramfs-linux.img"
  _bootctl_status "$esp"
  stub findmnt 0 "/boot"
  stub_script df 'case "$*" in -h*) printf "Fs Size Used Avail Use Mounted\n/dev/x 1G 1G 50M 95%% /boot\n" ;; *) printf "Fs 1K Used Avail Use Mounted\n/dev/x 100 95 5 95%% /boot\n" ;; esac'
  doctor_boot_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "boot_health: kernel ausente no ESP => TODO" {
  stub_privilege
  esp="$BATS_TEST_TMPDIR/esp2"; mkdir -p "$esp"
  touch "$esp/initramfs-linux.img" "$esp/initramfs-linux-fallback.img"
  _bootctl_status "$esp"
  doctor_boot_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}

# ── doctor_boot_time ──────────────────────────────────────────────────────────

@test "boot_time: sem systemd-analyze ou sem dados pula" {
  run doctor_boot_time
  [[ "$output" == *"não disponível"* ]]
  stub systemd-analyze 0 ""
  run doctor_boot_time
  [[ "$output" == *"sem dados de boot"* ]]
}

@test "boot_time: boot rápido ok; boot e loader lentos viram warn" {
  stub_script systemd-analyze 'case "$1" in
    time) echo "Startup finished in 3.0s (firmware) + 2.0s (loader) + 1.5s (kernel) + 8.0s (userspace) = 14.500s" ;;
    blame) printf "5.1s NetworkManager-wait-online.service\n2.0s udisks2.service\n" ;;
  esac'
  run doctor_boot_time
  [ "$status" -eq 0 ]
  [[ "$output" == *"dentro do limite"* ]]
  stub_script systemd-analyze 'case "$1" in
    time) echo "Startup finished in 3.0s (firmware) + 12.0s (loader) + 1.5s (kernel) + 1min 8.0s (userspace) = 1min 24.500s" ;;
  esac'
  doctor_boot_time >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"acima do limite"* ]]
}
