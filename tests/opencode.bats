#!/usr/bin/env bats
# tests/opencode.bats — atualização do opencode (H1).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  QUIET=0
  STEP_REASON=""
}

@test "opencode: ausente retorna 0" {
  has() { return 1; }
  run update_opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "opencode: upgrade ok retorna 0 e loga versões" {
  has() { [[ "$1" == opencode ]]; }
  opencode() {
    case "$1" in
      --version) printf '0.5.0\n' ;;
      upgrade)   printf 'upgraded\n' ;;
    esac
  }
  run_network_cmd() { opencode upgrade; return 0; }
  run update_opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode atual"* ]]
  [[ "$output" == *"opencode agora"* ]]
}

@test "opencode: falha de rede vira RC_WARN" {
  has() { [[ "$1" == opencode ]]; }
  opencode() { [[ "$1" == --version ]] && printf '0.5.0\n'; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run update_opencode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}

@test "opencode: falha não-rede do upgrade vira RC_WARN (não fatal)" {
  has() { [[ "$1" == opencode ]]; }
  opencode() { [[ "$1" == --version ]] && printf '0.5.0\n'; }
  run_network_cmd() { printf 'erro qualquer\n'; return 1; }
  run update_opencode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao atualizar"* ]]
}
