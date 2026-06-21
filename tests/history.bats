#!/usr/bin/env bats
# tests/history.bats — tendência/histórico de runs (F8).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/history.sh"
  LOG_DIR="$(mktemp -d)"

  # Run mais antigo: 2 warns (rede + cargo), duração 100s, v3.4.0.
  cat > "${LOG_DIR}/full-upgrade-20260610-100000-1.jsonl" <<'JSONL'
{"event":"run_start","run_id":"20260610-100000-1","timestamp":"2026-06-10T10:00:00-03:00","script_version":"3.4.0"}
{"event":"step","step":"Doctor: saúde de rede","status":"warn","duration_seconds":5,"reason":"DNS lento"}
{"event":"step","step":"Auditar binários cargo (CVEs)","status":"warn","duration_seconds":12,"reason":"CVEs"}
{"event":"summary","ok":50,"warn":2,"todo":0,"fail":0,"skip":3,"duration_seconds":100,"has_fail":0,"category_totals":{},"slowest_steps":[]}
JSONL

  # Run mais recente: 1 warn (cargo de novo) + 1 todo, duração 130s, v3.5.0.
  cat > "${LOG_DIR}/full-upgrade-20260613-142301-9.jsonl" <<'JSONL'
{"event":"run_start","run_id":"20260613-142301-9","timestamp":"2026-06-13T14:23:01-03:00","script_version":"3.5.0"}
{"event":"step","step":"Auditar binários cargo (CVEs)","status":"warn","duration_seconds":12,"reason":"CVEs"}
{"event":"step","step":"Doctor: reboot pendente","status":"todo","duration_seconds":1,"reason":"kernel"}
{"event":"summary","ok":51,"warn":1,"todo":1,"fail":0,"skip":3,"duration_seconds":130,"has_fail":0,"category_totals":{},"slowest_steps":[]}
JSONL
  # Garante mtime crescente (mais recente por último).
  touch -d '2026-06-10 10:05' "${LOG_DIR}/full-upgrade-20260610-100000-1.jsonl"
  touch -d '2026-06-13 14:28' "${LOG_DIR}/full-upgrade-20260613-142301-9.jsonl"
}

teardown() {
  [[ -n "${LOG_DIR:-}" ]] && rm -rf "$LOG_DIR"
}

@test "history: lista ambos os runs com versão e contagens" {
  run report_history 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"3.5.0"* ]]
  [[ "$output" == *"3.4.0"* ]]
  [[ "$output" == *"Histórico dos últimos 2 run(s)"* ]]
}

@test "history: mostra tendência de duração (subiu)" {
  run report_history 10
  # 100s -> 130s, mais recente vs anterior
  [[ "$output" == *"Tendência de duração"* ]]
  [[ "$output" == *"↑"* ]]
}

@test "history: detecta warn recorrente (cargo em 2 runs)" {
  run report_history 10
  [[ "$output" == *"recorrentes"* ]]
  [[ "$output" == *"2× Auditar binários cargo (CVEs)"* ]]
}

@test "history: N limita a quantidade" {
  run report_history 1
  [[ "$output" == *"últimos 1 run(s)"* ]]
  [[ "$output" == *"3.5.0"* ]]
  [[ "$output" != *"3.4.0"* ]]
}

@test "history: diretório sem runs retorna erro" {
  LOG_DIR="$(mktemp -d)"
  run report_history 10
  rmdir "$LOG_DIR" 2>/dev/null || true
  [ "$status" -eq 1 ]
}

@test "history: N inválido cai para o default" {
  run report_history abc
  [ "$status" -eq 0 ]
  [[ "$output" == *"Histórico dos últimos 2 run(s)"* ]]
}

# ── J2: saída JSON (--history --json) ────────────────────────────────────────

@test "history-json: emite JSON válido com runs e contagens" {
  JSON_SUMMARY=1
  run report_history 10
  [ "$status" -eq 0 ]
  assert_json "$output" 'len(d["runs"])==2 and d["runs"][0]["version"]=="3.5.0" and d["runs"][0]["ok"]==51 and d["runs"][1]["version"]=="3.4.0"'
}

@test "history-json: sem --json mantém a tabela" {
  JSON_SUMMARY=0
  run report_history 10
  [[ "$output" == *"Histórico dos últimos"* ]]
  [[ "$output" != *'"runs"'* ]]
}
