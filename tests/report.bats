#!/usr/bin/env bats
# tests/report.bats — relatório Markdown a partir do JSONL (F2).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/report.sh"
  FIXTURE="$(mktemp)"
  cat > "$FIXTURE" <<'JSONL'
{"event":"run_start","run_id":"20260613-142301-900745","timestamp":"2026-06-13T14:23:01-03:00","script_version":"3.2.2","script_path":"/x","script_sha256":"abc","log_file":"/home/u/.cache/system-upgrade/full-upgrade-20260613-142301-900745.log","jsonl_file":"/x.jsonl","pid":"900745"}
{"event":"step","run_id":"20260613-142301-900745","timestamp":"2026-06-13T14:23:10-03:00","step":"Atualizar pacotes do sistema e AUR","status":"ok","duration_seconds":75,"exit_code":0,"reason":"","category":"pacman","tags":"update","effect":"mutating","timeout":600,"cmd_deps":"paru","func_name":"update_system_aur","command":"update_system_aur","description":"x","started_at":"2026-06-13T14:23:08-03:00"}
{"event":"step","run_id":"20260613-142301-900745","timestamp":"2026-06-13T14:24:00-03:00","step":"Auditar binários cargo (CVEs)","status":"warn","duration_seconds":12,"exit_code":10,"reason":"7 CVEs em rustup","category":"doctor","tags":"rust","effect":"read","timeout":120,"cmd_deps":"cargo-audit","func_name":"audit_cargo_bins","command":"audit_cargo_bins","description":"x","started_at":"2026-06-13T14:23:48-03:00"}
{"event":"step","run_id":"20260613-142301-900745","timestamp":"2026-06-13T14:24:30-03:00","step":"Doctor: reboot pendente","status":"todo","duration_seconds":1,"exit_code":11,"reason":"kernel 7.0.11 vs 7.0.12","category":"doctor","tags":"kernel","effect":"read","timeout":15,"cmd_deps":"","func_name":"doctor_reboot_pending","command":"doctor_reboot_pending","description":"x","started_at":"2026-06-13T14:24:29-03:00"}
{"event":"summary","run_id":"20260613-142301-900745","timestamp":"2026-06-13T14:28:00-03:00","ok":1,"warn":1,"todo":1,"fail":0,"skip":0,"duration_seconds":283,"has_fail":0,"category_totals":{"Doctor":{"duration_seconds":13,"ok":0,"warn":1,"todo":1,"fail":0,"skip":0}},"slowest_steps":[],"reboot_recommendation":"kernel 7.0.11 vs 7.0.12","log_file":"/x.log","jsonl_file":"/x.jsonl"}
{"event":"run_end","run_id":"20260613-142301-900745","timestamp":"2026-06-13T14:28:01-03:00","script_version":"3.2.2","script_path":"/x","script_sha256":"abc","log_file":"/x.log","jsonl_file":"/x.jsonl","pid":"900745"}
JSONL
}

teardown() {
  [[ -n "${FIXTURE:-}" ]] && rm -f "$FIXTURE"
}

@test "report: cabeçalho com run_id e versão" {
  run report_markdown_from_jsonl "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Relatório full-upgrade — 20260613-142301-900745"* ]]
  [[ "$output" == *"**Versão:** 3.2.2"* ]]
}

@test "report: linha de resultado usa contagens do summary" {
  run report_markdown_from_jsonl "$FIXTURE"
  [[ "$output" == *"1 ok · 1 warn · 1 todo · 0 fail · 0 skip"* ]]
}

@test "report: duração formatada do summary" {
  run report_markdown_from_jsonl "$FIXTURE"
  [[ "$output" == *"**Duração:** 4m 43s"* ]]
}

@test "report: steps agrupados por categoria (mesmos grupos do terminal) com símbolo de status" {
  run report_markdown_from_jsonl "$FIXTURE"
  [[ "$output" == *"### Sistema / Pacman — 1m 15s"* ]]
  [[ "$output" == *"| | Step | Tempo | Motivo |"* ]]
  [[ "$output" == *"| ${SYM_OK} | Atualizar pacotes do sistema e AUR | 1m 15s |"* ]]
  [[ "$output" == *"### Doctor (auditorias)"* ]]
  [[ "$output" == *"| ${SYM_WARN} | Auditar binários cargo (CVEs) | 12s | 7 CVEs em rustup |"* ]]
}

@test "report: seção de pendências lista o todo com motivo" {
  run report_markdown_from_jsonl "$FIXTURE"
  [[ "$output" == *"## Pendências (ação manual)"* ]]
  [[ "$output" == *"- ${SYM_TODO} **Doctor: reboot pendente**: kernel 7.0.11 vs 7.0.12"* ]]
}

@test "report: seção de avisos lista o warn" {
  run report_markdown_from_jsonl "$FIXTURE"
  [[ "$output" == *"## Avisos"* ]]
  [[ "$output" == *"- ${SYM_WARN} **Auditar binários cargo (CVEs)**: 7 CVEs em rustup"* ]]
}

@test "report: sem seção de falhas quando não há fail" {
  run report_markdown_from_jsonl "$FIXTURE"
  [[ "$output" != *"## Falhas"* ]]
}

@test "report: ok com reason aparece em notas operacionais" {
  local notes; notes="$(mktemp)"
  cat > "$notes" <<'JSONL'
{"event":"run_start","run_id":"notes","timestamp":"2026-07-01T10:00:00Z","script_version":"1.0"}
{"event":"step","step":"Atualizar servidores MCP","status":"ok","duration_seconds":15,"reason":"cache uv em uso (server ativo); refrescar ocioso: uv cache clean serena"}
{"event":"summary","ok":1,"warn":0,"todo":0,"fail":0,"skip":0,"duration_seconds":15}
JSONL
  run report_markdown_from_jsonl "$notes"
  rm -f "$notes"
  [[ "$output" == *"## Notas operacionais"* ]]
  [[ "$output" == *"uv cache clean serena"* ]]
}

@test "report: JSONL inexistente retorna erro" {
  run report_markdown_from_jsonl "/nao/existe.jsonl"
  [ "$status" -eq 1 ]
}

@test "report: fallback de contagens sem evento summary" {
  grep -v '"event":"summary"' "$FIXTURE" > "${FIXTURE}.nosum"
  run report_markdown_from_jsonl "${FIXTURE}.nosum"
  rm -f "${FIXTURE}.nosum"
  [[ "$output" == *"1 ok · 1 warn · 1 todo · 0 fail · 0 skip"* ]]
}

# ── J2: saída JSON (--report --json) ─────────────────────────────────────────

@test "report-json: emite JSON válido com run_id, versão e summary" {
  run report_json_from_jsonl "$FIXTURE"
  [ "$status" -eq 0 ]
  assert_json "$output" 'd["run_id"]=="20260613-142301-900745" and d["script_version"]=="3.2.2" and [d["summary"][k] for k in ("ok","warn","todo","fail","skip")]==[1,1,1,0,0]'
}

@test "report-json: steps array preserva status, duração e reason" {
  run report_json_from_jsonl "$FIXTURE"
  assert_json "$output" 'len(d["steps"])==3 and any(s["status"]=="warn" and s["reason"]=="7 CVEs em rustup" and s["duration_seconds"]==12 for s in d["steps"])'
}

@test "report-json: escape de aspas/contrabarra no reason" {
  local esc; esc="$(mktemp)"
  cat > "$esc" <<'JSONL'
{"event":"run_start","run_id":"x","timestamp":"2026-06-21T10:00:00Z","script_version":"1.0"}
{"event":"step","step":"T \"x\"","status":"fail","duration_seconds":2,"reason":"C:\\temp falhou"}
{"event":"summary","ok":0,"warn":0,"todo":0,"fail":1,"skip":0,"duration_seconds":2}
JSONL
  run report_json_from_jsonl "$esc"
  [ "$status" -eq 0 ]
  assert_json "$output" 'd["steps"][0]["step"]=="T \"x\"" and d["steps"][0]["reason"]=="C:\\temp falhou"'
  rm -f "$esc"
}

@test "report-json: fallback de contagens sem summary" {
  grep -v '"event":"summary"' "$FIXTURE" > "${FIXTURE}.nosum"
  run report_json_from_jsonl "${FIXTURE}.nosum"
  rm -f "${FIXTURE}.nosum"
  assert_json "$output" '[d["summary"][k] for k in ("ok","warn","todo","fail","skip")]==[1,1,1,0,0]'
}
