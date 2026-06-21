#!/usr/bin/env bats
# tests/kimi.bats — atualização do Kimi CLI (H5).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  QUIET=0
  STEP_REASON=""
}

@test "kimi: ausente retorna 0" {
  has() { return 1; }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "kimi: npm global => RC 0 e menciona cobertura do step npm" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.18.0\n'; }
  npm() { printf '@moonshot-ai/kimi-code@0.18.0\n'; }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"kimi atual: 0.18.0"* ]]
  [[ "$output" == *"coberto por 'Atualizar npm global'"* ]]
}

@test "kimi: standalone (não-npm) => RC_TODO" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.18.0\n'; }
  npm() { :; }
  run update_kimi
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"fora do npm"* ]]
}
