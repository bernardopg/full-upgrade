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
  # Neutraliza execução real das mutações e presença de ferramentas. O default
  # de _rust_run_capture é saída vazia, que rustup_output_unchanged trata como
  # "assuma que mudou" — ou seja, os testes pré-existentes seguem exercitando o
  # caminho COM re-auditoria. Testes do atalho no-op sobrescrevem o stub.
  run_logged() { return 0; }
  _rust_run_capture() { return 0; }
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

# --- atalho no-op: dispensa a re-auditoria quando nada foi reescrito ---------

@test "rustup_output_unchanged: tudo unchanged => true" {
  run rustup_output_unchanged 'rustup unchanged - 1.29.0
stable-x86_64-unknown-linux-gnu unchanged - rustc 1.97.1 (8bab26f4f 2026-07-14)'
  [ "$status" -eq 0 ]
}

@test "rustup_output_unchanged: qualquer updated => false" {
  run rustup_output_unchanged 'rustup unchanged - 1.29.0
stable-x86_64-unknown-linux-gnu updated - rustc 1.98.0 (from rustc 1.97.1)'
  [ "$status" -ne 0 ]
}

@test "rustup_output_unchanged: saída vazia/desconhecida => false (conservador)" {
  run rustup_output_unchanged ''
  [ "$status" -ne 0 ]
  run rustup_output_unchanged 'self-update is disabled for this build of rustup'
  [ "$status" -ne 0 ]
}

@test "cargo_install_update_unchanged: nada a atualizar => true" {
  run cargo_install_update_unchanged 'No packages need updating.'
  [ "$status" -eq 0 ]
}

@test "cargo_install_update_unchanged: houve update => false" {
  run cargo_install_update_unchanged 'Updating tokei v13.0.0-alpha.0 -> v13.0.0'
  [ "$status" -ne 0 ]
}

@test "autofix: remediação no-op pula a re-auditoria (1 sweep, não 2)" {
  echo 0 > "$STATEF"
  _rust_collect_vuln_bins() {
    local n; n="$(cat "$STATEF")"; echo $((n + 1)) > "$STATEF"
    printf 'rustup\n'; return 0
  }
  # rustup relata "unchanged" nas duas invocações => nada foi reescrito.
  _rust_run_capture() { printf 'rustup unchanged - 1.29.0\n'; return 0; }
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"Re-auditoria dispensada"* ]]
  [[ "$output" != *"Re-auditando após remediação"* ]]
  # exatamente 1 sweep: o "antes". O "depois" foi deduzido, não medido.
  [ "$(cat "$STATEF")" -eq 1 ]
}

@test "autofix: rustup atualizado de fato ainda re-audita (2 sweeps)" {
  echo 0 > "$STATEF"
  _rust_collect_vuln_bins() {
    local n; n="$(cat "$STATEF")"; n=$((n + 1)); echo "$n" > "$STATEF"
    (( n == 1 )) && printf 'rustup\n'
    return 0
  }
  _rust_run_capture() { printf 'rustup updated - 1.29.1 (from 1.29.0)\n'; return 0; }
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"Re-auditando após remediação"* ]]
  [[ "$output" == *"remediadas"* ]]
  [ "$(cat "$STATEF")" -eq 2 ]
}

@test "autofix: no-op preserva o veredito informativo de toolchain (K3)" {
  _rust_collect_vuln_bins() { printf 'rustup\n'; return 0; }
  _rust_run_capture() { printf 'rustup unchanged - 1.29.0\n'; return 0; }
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"CVEs antes: 1 → depois: 1"* ]]
  [[ "$output" == *"não acionável"* ]]
}
