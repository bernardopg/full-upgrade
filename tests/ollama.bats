#!/usr/bin/env bats
# tests/ollama.bats — atualização do Ollama (H2).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  QUIET=0
  STEP_REASON=""
  OLLAMA_SELF_UPDATE=0
}

@test "parse: extrai versão de 'ollama version is X'" {
  run bash -c 'source '"${FU_LIB}"'/steps/ai.sh; printf "ollama version is 0.22.0\n" | parse_ollama_version'
  [ "$output" = "0.22.0" ]
}

@test "ollama: ausente retorna 0" {
  has() { return 1; }
  run update_ollama
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "ollama: off-switch só reporta versão (RC 0)" {
  has() { [[ "$1" == ollama ]]; }
  ollama() { [[ "$1" == --version ]] && printf 'ollama version is 0.22.0\n'; }
  run update_ollama
  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama atual: 0.22.0"* ]]
  [[ "$output" == *"desligada"* ]]
}

@test "ollama: on + instalador ok => RC 0 e versão nova" {
  OLLAMA_SELF_UPDATE=1
  has() { [[ "$1" == ollama || "$1" == curl ]]; }
  ollama() { [[ "$1" == --version ]] && printf 'ollama version is 0.23.0\n'; }
  curl() { printf 'https://github.com/ollama/ollama/releases/tag/v0.24.0'; }
  run_network_cmd() { printf 'echo instalado\n'; return 0; }   # "script" é um echo inofensivo
  run update_ollama
  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama agora: 0.23.0"* ]]
}

@test "ollama: on + falha de rede => RC_WARN" {
  OLLAMA_SELF_UPDATE=1
  has() { [[ "$1" == ollama || "$1" == curl ]]; }
  ollama() { [[ "$1" == --version ]] && printf 'ollama version is 0.22.0\n'; }
  curl() { printf 'https://github.com/ollama/ollama/releases/tag/v0.23.0'; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run update_ollama
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}

@test "ollama: on sem curl => RC 0 com aviso" {
  OLLAMA_SELF_UPDATE=1
  has() { [[ "$1" == ollama ]]; }   # curl ausente
  ollama() { [[ "$1" == --version ]] && printf 'ollama version is 0.22.0\n'; }
  run update_ollama
  [ "$status" -eq 0 ]
  [[ "$output" == *"curl não instalado"* ]]
}
