#!/usr/bin/env bats
# tests/doctor_storage_more_cov.bats — uso de disco/inodes (sem mounts, aviso de
# espaço e de inodes, inodes críticos), saúde do btrfs (ausente, raiz não-btrfs,
# sem sudo, contadores ilegíveis, status do scrub indisponível) e o autofix de
# scrub (prompt recusado/aceito, scrub iniciado com outro mountpoint pendente).
# PATH isolado: df/btrfs/findmnt/sudo são stubs.

load test_helper
load stub_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON="" ASSUME_YES=0
}

# df: espaço em $USE%, inodes em $IUSE% (mesmo mount "/").
_df() {
  stub_script df 'case "$*" in
  *-Pi*|*-Pih*) printf "Filesystem Inodes IUsed IFree IUse%% Mounted\n/dev/x 100 1 99 %s%% /\n" "${IUSE:-10}" ;;
  *) printf "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 100 1 99 %s%% /\n" "${USE:-10}" ;;
esac'
}

@test "disco: sem mounts, espaço em aviso, inodes em aviso e inodes críticos" {
  stub df 1 ""
  run doctor_disk_health
  [[ "$output" == *"Nenhum mount essencial encontrado"* ]]
  _df
  USE=91 run doctor_disk_health
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Aviso: / está com 91% de uso"* ]]
  IUSE=92 run doctor_disk_health
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Aviso: / está com 92% de inodes usados"* ]]
  IUSE=97 run doctor_disk_health
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"Ação necessária: / está com 97% de inodes usados"* ]]
}

@test "btrfs: ausente, raiz não-btrfs, sem sudo e contadores ilegíveis" {
  run doctor_btrfs_health
  [[ "$output" == *"btrfs-progs não instalado"* ]]
  stub btrfs 1 ""
  stub findmnt 0 "ext4"
  run doctor_btrfs_health
  [[ "$output" == *"Raiz não é btrfs (ext4)"* ]]
  stub findmnt 0 "btrfs"
  _doctor_sudo_ok() { return 1; }
  doctor_btrfs_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "btrfs: integridade não verificada (sudo indisponível)" ]
  _doctor_sudo_ok() { return 0; }
  stub sudo 1 ""
  run doctor_btrfs_health
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"não foi possível consultar os contadores de device"* ]]
}

@test "autofix scrub: sem btrfs; scrub iniciado com outro mountpoint pendente" {
  AUTO_BTRFS_SCRUB=1
  run autofix_btrfs_scrub
  [[ "$output" == *"btrfs-progs não instalado"* ]]
  stub btrfs 0 ""
  list_btrfs_mountpoints() { printf '/\n/data\n'; }
  _doctor_sudo_ok() { return 0; }
  btrfs_scrub_state() { [[ "$1" == *data* ]] && echo errors || echo never; }
  stub_script sudo 'shift; case "$*" in "btrfs scrub status /data") echo data ;; "btrfs scrub status /") echo raiz ;; esac; exit 0'
  ASSUME_YES=1 autofix_btrfs_scrub >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "btrfs: scrub iniciado nos mountpoints vencidos; outros"* ]]
}

@test "autofix scrub: prompt recusado e aceito" {
  stub btrfs 0 ""
  stub sudo 0 ""
  local defs="AUTO_BTRFS_SCRUB=1 ASSUME_YES=0
list_btrfs_mountpoints() { echo /; }
_doctor_sudo_ok() { return 0; }
btrfs_scrub_state() { echo never; }
autofix_btrfs_scrub; echo \"rc=\$?\""
  pty_call "steps/doctor/_common.sh steps/doctor/storage.sh" "$defs" 'n\r'
  [[ "$output" == *"Iniciar 'btrfs scrub start' em 1 mountpoint(s)?"* ]]
  [[ "$output" == *"Scrub cancelado pelo usuário"* ]]
  [[ "$output" == *"rc=$RC_TODO"* ]]
  pty_call "steps/doctor/_common.sh steps/doctor/storage.sh" "$defs" 's\r'
  [[ "$output" == *"Scrub iniciado em 1 mountpoint(s)"* ]]
  [[ "$output" == *"rc=0"* ]]
}
