#!/usr/bin/env bats
# tests/doctor_ai_clis.bats — inventário de versões de CLIs de IA (H4).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
  QUIET=0
}

@test "first_version: pega a primeira linha com número" {
  run bash -c 'source '"${FU_LIB}"'/steps/doctor.sh; printf "banner\nv1.2.3 (abc)\n" | _ai_cli_first_version'
  [ "$output" = "v1.2.3 (abc)" ]
}

@test "first_version: vazio quando não há número" {
  run bash -c 'source '"${FU_LIB}"'/steps/doctor.sh; printf "sem versao aqui\n" | _ai_cli_first_version'
  [ -z "$output" ]
}

@test "doctor: nenhuma CLI instalada => 0 e mensagem" {
  has() { return 1; }
  run doctor_ai_clis
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma CLI de IA"* ]]
}

@test "doctor: detecta e versiona CLIs presentes" {
  has() { [[ "$1" == claude || "$1" == codex || "$1" == ollama ]]; }
  claude() { [[ "$1" == --version ]] && printf '2.1.0 (claude)\n'; }
  codex()  { [[ "$1" == --version ]] && printf 'codex 0.141.0\n'; }
  ollama() { [[ "$1" == --version ]] && printf 'ollama version is 0.22.0\n'; }
  run doctor_ai_clis
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: 2.1.0 (claude)"* ]]
  [[ "$output" == *"codex: codex 0.141.0"* ]]
  [[ "$output" == *"ollama: ollama version is 0.22.0"* ]]
  [[ "$output" == *"3 CLI(s) de IA detectada(s)"* ]]
}

@test "doctor: CLI sem --version reporta 'versão indisponível'" {
  has() { [[ "$1" == cline ]]; }
  cline() { return 1; }   # --version falha/sem saída numérica
  run doctor_ai_clis
  [ "$status" -eq 0 ]
  [[ "$output" == *"cline: instalado (versão indisponível)"* ]]
}
