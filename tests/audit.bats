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

# ── Probes com ferramentas mockadas ──────────────────────────────────────────

@test "probe arch-audit: ausente pula sem achado" {
  has() { return 1; }
  _audit_probe_arch_audit
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe arch-audit: CVE corrigível => high" {
  has() { [[ "$1" == arch-audit ]]; }
  arch-audit() {
    case "$*" in
      *-u*) printf 'pkg1\n' ;;
      *)    printf 'pkg1\npkg2\n' ;;
    esac
  }
  _audit_probe_arch_audit
  [ "${#AUDIT_FINDINGS[@]}" -ge 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "high|"* ]]
}

@test "probe arch-audit: CVE sem correção upstream => info" {
  has() { [[ "$1" == arch-audit ]]; }
  arch-audit() {
    case "$*" in
      *-u*) return 0 ;;
      *)    printf 'pkg1\n' ;;
    esac
  }
  _audit_probe_arch_audit
  [ "${#AUDIT_FINDINGS[@]}" -ge 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "info|"* ]]
}

@test "probe fwupd: ausente pula sem achado" {
  has() { return 1; }
  _audit_probe_fwupd
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe fwupd: HSI:2 => medium" {
  has() { [[ "$1" == fwupdmgr ]]; }
  fwupdmgr() { printf 'HSI:2\n'; }
  _audit_probe_fwupd
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "medium|fwupd|"* ]]
}

@test "probe fwupd: HSI:3 => info (não medium)" {
  has() { [[ "$1" == fwupdmgr ]]; }
  fwupdmgr() { printf 'HSI:3\n'; }
  _audit_probe_fwupd
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "info|fwupd|"* ]]
}

@test "probe fwupd: sem HSI na saída => sem achado" {
  has() { [[ "$1" == fwupdmgr ]]; }
  fwupdmgr() { printf 'nenhuma informação de firmware\n'; }
  _audit_probe_fwupd
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe secure-boot: mokutil disabled => medium" {
  has() { [[ "$1" == mokutil ]]; }
  mokutil() { printf 'SecureBoot disabled\n'; }
  _audit_probe_secure_boot
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "medium|secureboot|"* ]]
}

@test "probe secure-boot: mokutil enabled => info" {
  has() { [[ "$1" == mokutil ]]; }
  mokutil() { printf 'SecureBoot enabled\n'; }
  _audit_probe_secure_boot
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "info|secureboot|"* ]]
}

@test "probe secure-boot: mokutil ausente e bootctl ausente => sem achado" {
  has() { return 1; }
  _audit_probe_secure_boot
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe secure-boot: fallback para bootctl quando mokutil ausente" {
  has() { [[ "$1" == bootctl ]]; }
  bootctl() { printf 'Secure Boot: disabled (setup mode)\n'; }
  _audit_probe_secure_boot
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "medium|secureboot|"* ]]
}

@test "probe secure-boot: bootctl reporta enabled via fallback => info" {
  has() { [[ "$1" == bootctl ]]; }
  bootctl() { printf 'Secure Boot: enabled\n'; }
  _audit_probe_secure_boot
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "info|secureboot|"* ]]
}

@test "probe failed-units: ausente pula sem achado" {
  has() { return 1; }
  _audit_probe_failed_units
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe failed-units: units falhadas => medium" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { printf 'ssh.service\nfoo.service\n'; }
  _audit_probe_failed_units
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "medium|systemd|"* ]]
}

@test "probe failed-units: sem units falhadas => sem achado" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 0; }
  _audit_probe_failed_units
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe journal-auth: ausente pula sem achado" {
  has() { return 1; }
  _audit_probe_journal_auth
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe journal-auth: falha de auth => low" {
  has() { [[ "$1" == journalctl ]]; }
  journalctl() { printf 'Jun 29 10:00:01 host sshd[1234]: pam_unix(sshd:auth): authentication failure\n'; }
  _audit_probe_journal_auth
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "low|journal|"* ]]
}

@test "probe journal-auth: journal limpo => sem achado" {
  has() { [[ "$1" == journalctl ]]; }
  journalctl() { printf 'tudo ok\n'; }
  _audit_probe_journal_auth
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe pip: python ausente => sem achado" {
  has() { return 1; }
  _audit_probe_pip
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe pip: pip check detecta incompatível => low" {
  has() { [[ "$1" == python ]]; }
  # rc=0 mas output com "has requirement" — evita set -e do bats; a condição
  # '(( rc != 0 )) || grep ...' ainda é verdadeira pelo grep match
  python() {
    case "$*" in
      *pip*--version*) return 0 ;;
      *pip*check*)     printf 'requests 2.28 has requirement urllib3>=1.21\n'; return 0 ;;
    esac
  }
  _audit_probe_pip
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "low|python|"* ]]
}

@test "probe pip: pip check limpo => sem achado" {
  has() { [[ "$1" == python ]]; }
  python() { return 0; }
  _audit_probe_pip
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe cargo: ausente pula sem achado" {
  has() { return 1; }
  _audit_probe_cargo
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe cargo: CVEs encontrados => high" {
  has() { [[ "$1" == cargo-audit || "$1" == cargo ]]; }
  CARGO_HOME="$BATS_TEST_TMPDIR/cargo"
  mkdir -p "$CARGO_HOME/bin"
  touch "$CARGO_HOME/bin/tokei"
  chmod +x "$CARGO_HOME/bin/tokei"
  # rc=0 para não disparar set -e do bats; output com CVE é suficiente para
  # parse_cargo_vuln_bins detectar o binário afetado
  cargo() {
    printf 'Vulnerabilities found in /home/user/.cargo/bin/tokei\n'
    return 0
  }
  _audit_probe_cargo
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "high|cargo|"* ]]
}

@test "probe cargo: sem binários em CARGO_HOME/bin => sem achado" {
  has() { [[ "$1" == cargo-audit || "$1" == cargo ]]; }
  CARGO_HOME="$BATS_TEST_TMPDIR/cargo-empty"
  mkdir -p "$CARGO_HOME/bin"
  _audit_probe_cargo
  [ "${#AUDIT_FINDINGS[@]}" -eq 0 ]
}

@test "probe cargo: falha de rede => info (não high)" {
  has() { [[ "$1" == cargo-audit || "$1" == cargo ]]; }
  CARGO_HOME="$BATS_TEST_TMPDIR/cargo-net"
  mkdir -p "$CARGO_HOME/bin"
  touch "$CARGO_HOME/bin/tokei"
  chmod +x "$CARGO_HOME/bin/tokei"
  cargo() {
    printf 'name or service not known\n'
    return 1
  }
  # cargo retorna 1 para simular falha de rede; desabilita set -e temporariamente
  # para que a linha 'output="$(cargo ...)"' não aborte a função antes de _audit_add
  set +e
  _audit_probe_cargo
  set -e
  [ "${#AUDIT_FINDINGS[@]}" -eq 1 ]
  [[ "${AUDIT_FINDINGS[0]}" == "info|cargo|"* ]]
}
