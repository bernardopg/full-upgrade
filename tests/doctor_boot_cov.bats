#!/usr/bin/env bats
# tests/doctor_boot_cov.bats — fwupd ausente, com erro, com HSI:1 só por Locked
# MTD e com ✘ sem nível legível; systemd-boot com status falho e com kernel,
# initrd e fallback presentes (arquivos descartáveis). PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
}

@test "fwupd: ausente, erro, HSI:1 só por MTD e ✘ sem nível" {
  run doctor_fwupd_security
  [[ "$output" == *"fwupdmgr não instalado"* ]]
  stub fwupdmgr 3 "erro do daemon"
  run doctor_fwupd_security
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"retornou código 3"* ]]
  stub fwupdmgr 0 "Host Security ID: HSI:1 (v2.1.7)"
  fwupd_hsi_only_mtd_measurement_gap() { return 0; }
  run doctor_fwupd_security
  [ "$status" -eq 0 ]
  [[ "$output" == *"limitado apenas por Locked MTD"* ]]
  stub fwupdmgr 0 "Atributo X: ✘ Desativado"
  doctor_fwupd_security >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "fwupd security reportou falha(s) sem nível HSI legível" ]
}

@test "systemd-boot: status falho e arquivos presentes no ESP" {
  _doctor_sudo_ok() { return 0; }
  stub_privilege
  stub_script bootctl 'case "$1" in is-installed) exit 0 ;; status) exit "${STATUS_RC:-0}" ;; esac'
  STATUS_RC=1 run doctor_boot_health
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"bootctl status retornou código 1"* ]]
  esp="$BATS_TEST_TMPDIR/esp"; mkdir -p "$esp"
  touch "$esp/vmlinuz-linux" "$esp/initramfs-linux.img" "$esp/initramfs-linux-fallback.img"
  stub_script bootctl "case \"\$1\" in is-installed) exit 0 ;; status) printf '%s\n' 'Default Boot Loader Entry:' '         title: Arch Linux' '         linux: $esp/vmlinuz-linux' '        initrd: $esp/initramfs-linux.img' ;; esac"
  run doctor_boot_health
  [[ "$output" == *"kernel OK: $esp/vmlinuz-linux"* ]]
  [[ "$output" == *"initrd OK: $esp/initramfs-linux.img"* ]]
  [[ "$output" == *"fallback initramfs OK"* ]]
}

@test "fwupd sem nível nem ✘ é ok; initrd ausente no ESP vira TODO" {
  stub fwupdmgr 0 "nada relevante"
  run doctor_fwupd_security
  [ "$status" -eq 0 ]
  _doctor_sudo_ok() { return 0; }
  stub_privilege
  esp="$BATS_TEST_TMPDIR/esp2"; mkdir -p "$esp"; touch "$esp/vmlinuz-linux"
  stub_script bootctl "case \"\$1\" in is-installed) exit 0 ;; status) printf '%s\n' '         title: Arch' '         linux: $esp/vmlinuz-linux' '        initrd: $esp/initramfs-linux.img' ;; esac"
  run doctor_boot_health
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"initrd: $esp/initramfs-linux.img"* ]]
}
