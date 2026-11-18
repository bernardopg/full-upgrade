#!/usr/bin/env bats
# tests/cloud_backup_cov.bats — backup_timeshift_cloud de ponta a ponta com
# sudo/findmnt/mountpoint stubados: pré-requisitos, mount do top-level Btrfs,
# seleção do snapshot, upload, retenção e limpeza. Nada é montado de verdade:
# o sudo stub só registra a chamada e devolve o rc configurado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/cloud_backup.sh"
  BDEV="$(find /dev -maxdepth 1 -type b -print -quit)"
  [ -n "$BDEV" ]
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export TIMESHIFT_CLOUD_BACKUP=1 HOME="$BATS_TEST_TMPDIR/home" BDEV
  mkdir -p "$HOME"
  export TIMESHIFT_CLOUD_REPOSITORY="rclone:od:fu"
  export TIMESHIFT_CLOUD_PASSWORD_FILE="$BATS_TEST_TMPDIR/pass"
  export TIMESHIFT_CLOUD_RCLONE_CONFIG="$BATS_TEST_TMPDIR/rclone.conf"
  echo segredo > "$TIMESHIFT_CLOUD_PASSWORD_FILE"
  echo "[od]" > "$TIMESHIFT_CLOUD_RCLONE_CONFIG"
}

# Ambiente completo: dependências presentes, raiz Btrfs, sudo com rc por verbo.
_ready() {
  stub restic 0 ""; stub rclone 0 ""; stub timeshift 0 ""
  stub_script findmnt 'case "$*" in *FSTYPE*) echo btrfs ;; *SOURCE*) echo "$BDEV[/@]" ;; esac'
  stub mountpoint 1 ""
  stub_script sudo 'shift; case "$1" in
  umount) exit "${UMOUNT_RC:-0}" ;;
  mkdir) exit "${MKDIR_RC:-0}" ;;
  mount) exit "${MOUNT_RC:-0}" ;;
  *) exit 0 ;;
esac'
  timeshift_cloud_latest_name() { printf '2026-11-17_10-00-00'; return "${LATEST_RC:-0}"; }
  timeshift_cloud_snapshot_state() { return "${STATE_RC:-0}"; }
  _timeshift_cloud_restic() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/restic"
    case "$1" in
      backup) printf '%s\n' '{"message_type":"summary","files_new":1,"files_changed":0,"data_added":10,"total_bytes_processed":10,"total_duration":1}'; return "${BACKUP_RC:-0}" ;;
      forget) return "${FORGET_RC:-0}" ;;
    esac
  }
}

@test "pré-requisitos: dependências, raiz não-Btrfs, config e credenciais" {
  run backup_timeshift_cloud
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"requer: restic, rclone, timeshift"* ]]
  _ready
  stub findmnt 0 "ext4"
  run backup_timeshift_cloud
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"requer raiz Btrfs"* ]]
  _ready
  TIMESHIFT_CLOUD_REPOSITORY="" run backup_timeshift_cloud
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"Configure TIMESHIFT_CLOUD_REPOSITORY"* ]]
  : > "$TIMESHIFT_CLOUD_PASSWORD_FILE"
  run backup_timeshift_cloud
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"Password file do Restic"* ]]
}

@test "mount: órfão ocupado, mkdir e mount falhando viram warn" {
  _ready
  stub mountpoint 0 ""
  UMOUNT_RC=1 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "mount temporário anterior ainda está ocupado" ]
  stub mountpoint 1 ""; unset status
  MKDIR_RC=1 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "não foi possível criar mount temporário" ]
  unset status
  MOUNT_RC=1 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "falha ao montar top-level Btrfs" ]
}

@test "snapshot: listagem falha, ausente e sem @home recusam o envio" {
  _ready
  LATEST_RC=2 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "falha ao listar snapshots Timeshift com privilégio" ]
  unset status
  STATE_RC=1 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "snapshot Timeshift ausente"* ]]
  unset status
  STATE_RC=2 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"@home ausente ou ilegível"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/restic" ]
}

@test "upload com exclusões, retenção e devolução de posse do cache" {
  _ready
  export TIMESHIFT_CLOUD_EXCLUDE_FILE="$BATS_TEST_TMPDIR/excl"; echo '*.cache' > "$TIMESHIFT_CLOUD_EXCLUDE_FILE"
  mkdir -p "$HOME/.cache/restic"
  run backup_timeshift_cloud
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exclusões de caches/artefatos"* ]]
  [[ "$output" == *"armazenado no OneDrive via Restic"* ]]
  [[ "$output" == *"manter as 3 versões"* ]]
  grep -q -- "--exclude-file $TIMESHIFT_CLOUD_EXCLUDE_FILE" "$BATS_TEST_TMPDIR/restic"
  grep -q -- "forget --tag full-upgrade-timeshift --group-by  --keep-last 3 --prune" "$BATS_TEST_TMPDIR/restic"
  stub_calls sudo | grep -q "chown -R"
}

@test "upload, retenção e desmontagem falhando viram warn" {
  _ready
  BACKUP_RC=1 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "falha no upload Restic do snapshot 2026-11-17_10-00-00" ]
  unset status
  FORGET_RC=1 backup_timeshift_cloud >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "backup enviado, mas retenção remota falhou" ]
  unset status
  UMOUNT_RC=1 run backup_timeshift_cloud
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"não foi possível desmontar"* ]]
}

@test "restic: sudo -n env com credenciais; erro e linhas ignoradas no progresso" {
  stub_script sudo 'printf "%s\n" "$@" > "$STUB_LOG.args"'
  _timeshift_cloud_restic snapshots
  grep -qx -- "-n" "$STUB_LOG.args"
  grep -qx "RESTIC_PASSWORD_FILE=$TIMESHIFT_CLOUD_PASSWORD_FILE" "$STUB_LOG.args"
  grep -qx "rclone:od:fu" "$STUB_LOG.args"
  run timeshift_cloud_consume_progress <<'EOF'
{"message_type":"error","error":{"message":"leitura negada"},"during":"archival"}

{"message_type":"verbose_status","action":"new"}
{"message_type":"summary","files_new":2,"files_changed":1,"data_added":1,"total_bytes_processed":1,"total_duration":1}
EOF
  [[ "$output" == *"restic: leitura negada"* ]]
  [[ "$output" == *"2 novo(s), 1 alterado(s)"* ]]
  [[ "$output" != *verbose_status* ]]
  run timeshift_cloud_latest_name /x invalido
  [ "$status" -eq 2 ]
}
