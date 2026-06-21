#!/usr/bin/env bats
# tests/lang_rust_autofix.bats — auto-remediação de CVEs Rust (F7).
#
# A função autofix_rust_cves orquestra cargo audit + rustup/cargo. Os testes
# isolam a rede stubando _rust_collect_vuln_bins (a coleta) e neutralizando
# run_logged/has, validando a máquina de estados sem tocar a toolchain real.
#
# NOTA: a coleta roda em command-substitution (subshell), então um contador em
# variável não persiste entre a auditoria "antes" e "depois" — usamos um arquivo.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_rust.sh"
  QUIET=0            # garante que log() vá para o stdout capturado pelo bats
  AUTO_FIX_RUST_CVES=1
  ASSUME_YES=1
  STEP_REASON=""
  # Neutraliza execução real das mutações e presença de ferramentas.
  run_logged() { return 0; }
  has() { return 0; }
  STATEF="$(mktemp)"
}

teardown() {
  [[ -n "${STATEF:-}" ]] && rm -f "$STATEF"
}

@test "autofix: off-switch retorna 0 sem agir" {
  AUTO_FIX_RUST_CVES=0
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"desligado"* ]]
}

@test "autofix: sem CVEs retorna 0" {
  _rust_collect_vuln_bins() { return 0; }
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem CVEs corrigíveis"* ]]
}

@test "autofix: aplica e re-audita limpo (RC 0)" {
  echo 0 > "$STATEF"
  _rust_collect_vuln_bins() {
    local n; n="$(cat "$STATEF")"; n=$((n + 1)); echo "$n" > "$STATEF"
    (( n == 1 )) && printf 'rustup\n'   # vulnerável na 1ª auditoria, limpo na 2ª
    return 0
  }
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"remediadas"* ]]
}

@test "autofix: CVE remanescente só de toolchain (rustup) => RC 0 informativo (K3)" {
  _rust_collect_vuln_bins() { printf 'rustup\n'; return 0; }   # nunca some; é toolchain
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"não acionável"* ]]
}

@test "autofix: CVE remanescente em binário cargo-installed => RC_WARN" {
  _rust_collect_vuln_bins() { printf 'tokei\n'; return 0; }    # nunca some; não-toolchain
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"remanescentes acionáveis"* ]]
}

@test "autofix: falha de rede na coleta vira RC_WARN" {
  _rust_collect_vuln_bins() { return "$RC_WARN"; }
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}

@test "autofix: não interativo sem --yes vira RC_TODO" {
  ASSUME_YES=0
  _rust_collect_vuln_bins() { printf 'rustup\n'; return 0; }
  run autofix_rust_cves
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"não interativa"* ]]
}
