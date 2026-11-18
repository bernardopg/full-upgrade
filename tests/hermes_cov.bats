#!/usr/bin/env bats
# tests/hermes_cov.bats — Hermes ausente, check que diz "atualizado", check que
# falha (cai no update) e captura do stderr do Git indisponível. PATH isolado:
# o `env ... hermes update --check` executa o binário, não uma função, então o
# hermes é um stub no PATH (nunca o da máquina).

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/10-hermes.sh"
  stub_path_init
  LOG_DIR="$BATS_TEST_TMPDIR" RUN_ID=t LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  sleep() { :; }
  with_updater_github_token() { "$@"; }
}

@test "hermes: ausente do PATH é no-op" {
  run update_hermes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hermes não encontrado no PATH"* ]]
}

@test "hermes: check atual pula; check falho cai no update sem captura do Git" {
  stub hermes 0 "Already up to date."
  run update_hermes
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está na versão mais recente (check)"* ]]
  stub_script hermes 'case "$*" in "update --check") exit 3 ;; *) echo "✓ Update complete!" ;; esac'
  hermes_prepare_git_capture() { return 1; }
  run update_hermes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Check do Hermes falhou (rc=3)"* ]]
  [[ "$output" == *"Não foi possível preparar captura do stderr Git"* ]]
}
