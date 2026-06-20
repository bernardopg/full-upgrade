#!/usr/bin/env bats
# tests/audit.bats — modo --audit: framework de achados consolidados (F6).
# Testa as partes puras (add/format/json/rank) injetando achados; as probes
# em si dependem de ferramentas do sistema e não são exercitadas aqui.

load test_helper

setup() {
  load_libs
  # json_escape vive em json.sh (não carregado pelo test_helper); sourcing
  # apenas define funções, sem efeitos colaterais.
  # shellcheck source=/dev/null
  source "${FU_LIB}/json.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/audit.sh"
  AUDIT_FINDINGS=()
  JSON_SUMMARY=0
}

@test "audit: relatório vazio diz 'nenhum achado'" {
  run audit_report_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum achado de segurança"* ]]
}

@test "audit: _audit_add acumula e relatório lista por severidade" {
  _audit_add high cargo "CVEs em binários cargo" "2 binários" "rustup update"
  _audit_add low python "pip quebrado" "incompatível" "pip check"
  [ "${#AUDIT_FINDINGS[@]}" -eq 2 ]
  run audit_report_text
  [[ "$output" == *"[ALTA]"* ]]
  [[ "$output" == *"CVEs em binários cargo"* ]]
  [[ "$output" == *"[BAIXA]"* ]]
  [[ "$output" == *"pip quebrado"* ]]
  [[ "$output" == *"1 alta"* ]]
}

@test "audit: severidade ALTA aparece antes de BAIXA" {
  _audit_add low python "achado baixo" "x" ""
  _audit_add high cargo "achado alto" "y" ""
  run audit_report_text
  # índice de [ALTA] deve ser menor que [BAIXA] mesmo inserindo baixo primeiro
  local out="$output"
  local ialta="${out%%\[ALTA\]*}"
  local ibaixa="${out%%\[BAIXA\]*}"
  [ "${#ialta}" -lt "${#ibaixa}" ]
}

@test "audit: remediação é exibida quando presente" {
  _audit_add medium fwupd "HSI baixo" "HSI:2 de 4" "fwupdmgr security"
  run audit_report_text
  [[ "$output" == *"remediação: fwupdmgr security"* ]]
}

@test "audit: rank ordena high>medium>low>info" {
  [ "$(audit_severity_rank high)" -gt "$(audit_severity_rank medium)" ]
  [ "$(audit_severity_rank medium)" -gt "$(audit_severity_rank low)" ]
  [ "$(audit_severity_rank low)" -gt "$(audit_severity_rank info)" ]
}

@test "audit: JSON contém findings e counts" {
  _audit_add high cargo "CVEs" "2 bins" "rustup update"
  _audit_add medium systemd "units falhadas" "a.service" "systemctl --failed"
  run audit_json_section
  [[ "$output" == *'"event":"audit"'* ]]
  [[ "$output" == *'"severity":"high"'* ]]
  [[ "$output" == *'"title":"CVEs"'* ]]
  [[ "$output" == *'"counts":{"high":1,"medium":1,"low":0,"info":0}'* ]]
}

@test "audit: campos com pipe são sanitizados" {
  _audit_add low test "a|b" "c|d" "e|f"
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  # o item deve ter exatamente 5 campos (4 separadores '|')
  local item="${AUDIT_FINDINGS[0]}"
  local seps="${item//[^|]/}"
  [ "${#seps}" -eq 4 ]
}

@test "audit: run_audit_mode roda sem erro e imprime cabeçalho" {
  # Neutraliza todas as ferramentas → nenhuma probe gera achado.
  has() { return 1; }
  run run_audit_mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auditoria de segurança consolidada"* ]]
  [[ "$output" == *"Nenhum achado"* ]]
}

# ── G4: relatório Markdown da auditoria ───────────────────────────────────────

@test "audit-md: relatório vazio diz nenhum achado" {
  run audit_report_markdown
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Auditoria de segurança consolidada"* ]]
  [[ "$output" == *"_Nenhum achado"* ]]
}

@test "audit-md: agrupa por severidade com remediação e total" {
  _audit_add high cargo "CVEs em binários cargo" "2 bins" "rustup update"
  _audit_add low python "pip quebrado" "incompatível" ""
  run audit_report_markdown
  [[ "$output" == *"## Alta"* ]]
  [[ "$output" == *"- **CVEs em binários cargo** (cargo)"* ]]
  [[ "$output" == *"remediação: \`rustup update\`"* ]]
  [[ "$output" == *"## Baixa"* ]]
  [[ "$output" == *"**Total:** 1 alta, 0 média, 1 baixa, 0 info"* ]]
}

@test "audit-md: sem ANSI no Markdown" {
  _audit_add high cargo "CVE" "x" "y"
  run audit_report_markdown
  # nenhum escape ESC (\033) na saída
  [[ "$output" != *$'\033'* ]]
}

@test "audit: --report grava Markdown no arquivo (combo --audit --report)" {
  has() { return 1; }          # sem probes ativas
  DO_REPORT=1
  REPORT_FILE="$(mktemp)"
  run run_audit_mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"Relatório de auditoria gravado"* ]]
  grep -q "# Auditoria de segurança consolidada" "$REPORT_FILE"
  rm -f "$REPORT_FILE"
}

@test "audit: --report sem arquivo emite Markdown no stdout" {
  has() { return 1; }
  DO_REPORT=1
  REPORT_FILE=""
  run run_audit_mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Auditoria de segurança consolidada"* ]]
}
