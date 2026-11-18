#!/usr/bin/env bats
# tests/backup_cov.bats — backup de configs com gzip (sem zstd), --dry-run,
# diretório de backup não criável, tar via sudo, tar falho, publicação falha e
# rotação que não consegue remover arquivos antigos. Paths e destino ficam em
# $BATS_TEST_TMPDIR; PATH isolado.

load test_helper
load stub_helper

setup() {
  RM_REAL="$(type -P rm)"
  load_libs
  source "${FU_LIB}/steps/backup.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON="" DRY_RUN=0 SUDO_READY=0 RUN_ID=t1
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"; mkdir -p "$HOME"
  mkdir -p "$BATS_TEST_TMPDIR/etc"; echo a=1 > "$BATS_TEST_TMPDIR/etc/app.conf"
  export BACKUP_PATHS="$BATS_TEST_TMPDIR/etc/app.conf"
  BK="$XDG_CACHE_HOME/system-upgrade/backups"
  mv "$STUB_SAFE/zstd" "$STUB_SAFE/zstd.x"; hash -r
}

@test "gzip sem zstd: --dry-run lista e o backup real publica .tar.gz" {
  DRY_RUN=1 run backup_critical_configs
  [[ "$output" == *"[dry-run] arquivaria 1 path(s)"*"configs-t1.tar.gz"* ]]
  run backup_critical_configs
  [ "$status" -eq 0 ]
  [ -s "$BK/configs-t1.tar.gz" ]
}

@test "diretório de backup não criável vira warn" {
  mkdir -p "$XDG_CACHE_HOME"; chmod 555 "$XDG_CACHE_HOME"
  run backup_critical_configs
  chmod 755 "$XDG_CACHE_HOME"
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"não foi possível criar"* ]]
}

@test "tar via sudo devolve a posse do parcial" {
  stub_privilege
  SUDO_READY=1 run backup_critical_configs
  [ "$status" -eq 0 ]
  stub_calls sudo | grep -q "^tar --gzip"
  stub_calls sudo | grep -q "^chown"
}

@test "tar falho e publicação falha não deixam parcial" {
  stub tar 2 ""
  run backup_critical_configs
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"backup de configs incompleto ou vazio (rc=2)"* ]]
  rm "$STUB_BIN/tar"; hash -r
  mv() { return 1; }
  run backup_critical_configs
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"não foi possível publicar o backup"* ]]
  [ -z "$(find "$BK" -name '.configs-*partial*')" ]
}

@test "rotação: arquivos antigos que não saem viram warn" {
  mkdir -p "$BK"
  touch "$BK/configs-20260101-000000.tar.gz" "$BK/configs-20260102-000000.tar.gz" "$BK/configs-20260103-000000.tar.gz"
  stub_script rm "for a; do [[ \"\$a\" == */configs-2026* ]] && exit 1; done; exec '$RM_REAL' \"\$@\""
  BACKUP_KEEP=2 run backup_critical_configs
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"não foi possível remover backup antigo"* ]]
}
