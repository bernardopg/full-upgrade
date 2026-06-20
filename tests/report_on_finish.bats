#!/usr/bin/env bats
# tests/report_on_finish.bats — relatório Markdown automático ao fim do run (G3).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/report.sh"
  QUIET=1   # log() não polui; só checamos efeitos
  LOG_DIR="$(mktemp -d)"
  RUN_ID="20260620-000000-1"
  JSONL_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.jsonl"
  cat > "$JSONL_FILE" <<'JSONL'
{"event":"run_start","run_id":"20260620-000000-1","timestamp":"2026-06-20T00:00:00-03:00","script_version":"3.6.0","log_file":"/x.log"}
{"event":"step","run_id":"20260620-000000-1","timestamp":"2026-06-20T00:00:10-03:00","step":"Atualizar pacotes do sistema e AUR","status":"ok","duration_seconds":42,"reason":""}
{"event":"summary","run_id":"20260620-000000-1","timestamp":"2026-06-20T00:05:00-03:00","ok":1,"warn":0,"todo":0,"fail":0,"skip":0,"duration_seconds":300,"has_fail":0,"category_totals":{},"slowest_steps":[]}
{"event":"run_end","run_id":"20260620-000000-1","timestamp":"2026-06-20T00:05:01-03:00","script_version":"3.6.0","log_file":"/x.log"}
JSONL
  OUTFILE="${LOG_DIR}/full-upgrade-${RUN_ID}.md"
}

teardown() {
  [[ -n "${LOG_DIR:-}" ]] && rm -rf "$LOG_DIR"
}

@test "on-finish: off-switch não gera arquivo" {
  REPORT_ON_FINISH=0
  run generate_report_on_finish
  [ "$status" -eq 0 ]
  [ ! -e "$OUTFILE" ]
}

@test "on-finish: ligado gera o .md do run" {
  REPORT_ON_FINISH=1
  run generate_report_on_finish
  [ "$status" -eq 0 ]
  [ -f "$OUTFILE" ]
  grep -q "Relatório full-upgrade — 20260620-000000-1" "$OUTFILE"
  grep -q "1 ok · 0 warn · 0 todo · 0 fail · 0 skip" "$OUTFILE"
}

@test "on-finish: JSONL ausente não gera arquivo e retorna 0" {
  REPORT_ON_FINISH=1
  JSONL_FILE="${LOG_DIR}/inexistente.jsonl"
  run generate_report_on_finish
  [ "$status" -eq 0 ]
  [ ! -e "$OUTFILE" ]
}
