#!/usr/bin/env bats
# tests/report_json_cov.bats — escolha do JSONL do --report (por run_id exato
# e parcial, latest real, pula dry-run), evento pkg_changes, diff com linha
# inválida e --resume sem run real. LOG_DIR descartável.

load test_helper

setup() {
  load_libs
  source "${FU_LIB}/report.sh"
  export LOG_DIR="$BATS_TEST_TMPDIR/logs"; mkdir -p "$LOG_DIR"
  LATEST_JSONL_LINK="$LOG_DIR/latest.jsonl"
  RUN_ID=20261118-010000-1 JSONL_FILE="$LOG_DIR/out.jsonl"
}

_jsonl() { printf '{"event":"run_start","dry_run":%s}\n' "$2" > "$LOG_DIR/full-upgrade-$1.jsonl"; touch -d "$3" "$LOG_DIR/full-upgrade-$1.jsonl"; }

@test "report: run_id exato, prefixo, inexistente" {
  _jsonl 20261101-100000-1 false '2 days ago'
  [ "$(_report_resolve_jsonl 20261101-100000-1)" = "$LOG_DIR/full-upgrade-20261101-100000-1.jsonl" ]
  [ "$(_report_resolve_jsonl 20261101)" = "$LOG_DIR/full-upgrade-20261101-100000-1.jsonl" ]
  run _report_resolve_jsonl 19990101
  [ "$status" -eq 1 ]
}

@test "report: latest real, latest dry-run cai no real mais novo, nenhum" {
  run _report_resolve_jsonl ""
  [ "$status" -eq 1 ]
  _jsonl 20261101-100000-1 false '2 days ago'
  _jsonl 20261102-100000-1 true '1 day ago'
  ln -s "$LOG_DIR/full-upgrade-20261102-100000-1.jsonl" "$LATEST_JSONL_LINK"
  [ "$(_report_resolve_jsonl "")" = "$LOG_DIR/full-upgrade-20261101-100000-1.jsonl" ]
  ln -sf "$LOG_DIR/full-upgrade-20261101-100000-1.jsonl" "$LATEST_JSONL_LINK"
  [ "$(_report_resolve_jsonl "")" = "$LATEST_JSONL_LINK" ]
}

@test "pkg_changes: grava contagens e lista; sem mudança não grava" {
  printf 'a 1\nb 1\n' > "$BATS_TEST_TMPDIR/antes"
  printf 'a 2\nc 1\n' > "$BATS_TEST_TMPDIR/depois"
  write_pkg_changes_json "$BATS_TEST_TMPDIR/antes" "$BATS_TEST_TMPDIR/depois"
  grep -q '"event":"pkg_changes".*"upgraded":1,"installed":1,"removed":1' "$JSONL_FILE"
  : > "$JSONL_FILE"
  write_pkg_changes_json "$BATS_TEST_TMPDIR/antes" "$BATS_TEST_TMPDIR/antes"
  [ ! -s "$JSONL_FILE" ]
  [ "$(pkg_diff_json $'X lixo\nI a 1')" = '[{"action":"installed","name":"a","version":"1"}]' ]
}

@test "resume: sem run real não há pendências" {
  _jsonl 20261102-100000-1 true '1 day ago'
  run resume_latest_real_jsonl
  [ "$status" -eq 1 ]
  run resume_pending_steps
  [ "$status" -eq 1 ]
}
