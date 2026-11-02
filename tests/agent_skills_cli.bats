#!/usr/bin/env bats
# tests/agent_skills_cli.bats — escolha de versão do CLI `skills` e fallback
# quando a versão nova estoura o orçamento. npx/npm são sempre funções stub:
# nada toca rede nem ~/.agents.
#
# Caso real: skills@1.7.5 varre os diretórios de 54 agentes de forma
# quadrática (5s na 1.7.4, 71s na 1.7.5) e um run estourou os 300s do catálogo.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  STEP_REASON=""
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.agents/skills"
  LOG_FILE=/dev/null
  CALLS="$BATS_TEST_TMPDIR/npx.calls"
  has() { [[ "$1" == npx ]]; }
  agent_skills_git_ff() { :; }
  with_updater_github_token() { "$@"; }
  # timeout real não executa funções: o stub devolve o rc do npx simulado.
  timeout() { shift; "$@"; }
  npm() {
    case "$*" in
      'view skills version') printf '%s\n' "${MOCK_LATEST:-1.7.5}" ;;
      'view skills versions --json') printf '["1.7.3","1.7.4","1.7.5"]\n' ;;
    esac
  }
  # MOCK_SLOW = versões que "estouram" (rc 124 como o timeout real).
  npx() {
    printf '%s\n' "$2" >> "$CALLS"
    [[ " ${MOCK_SLOW:-} " == *" ${2#skills@} "* ]] && return 124
    printf '✓ All global skills are up to date\n'
  }
}

@test "agent_skills_cli_pick: sem estado usa a mais nova" {
  run agent_skills_cli_pick 1.7.5
  [ "$output" = "skills@1.7.5" ]
}

@test "agent_skills_cli_pick: mais nova marcada lenta com boa conhecida usa a boa" {
  agent_skills_cli_state_set good 1.7.4
  agent_skills_cli_state_set slow 1.7.5
  run agent_skills_cli_pick 1.7.5
  [ "$output" = "skills@1.7.4" ]
}

@test "agent_skills_cli_pick: release nova depois da lenta volta a ser testada" {
  agent_skills_cli_state_set good 1.7.4
  agent_skills_cli_state_set slow 1.7.5
  run agent_skills_cli_pick 1.7.6
  [ "$output" = "skills@1.7.6" ]
}

@test "agent_skills_cli_pick: registro indisponível cai no spec puro" {
  run agent_skills_cli_pick ""
  [ "$output" = "skills" ]
}

@test "agent_skills_cli_state_set: rejeita valor que não é versão" {
  agent_skills_cli_state_set good 'x; rm -rf'
  run agent_skills_cli_state_get good
  [ -z "$output" ]
}

@test "update_agent_skills: sucesso registra a versão como boa" {
  update_agent_skills >/dev/null
  [ "$(agent_skills_cli_state_get good)" = "1.7.5" ]
  [ "$(cat "$CALLS")" = "skills@1.7.5" ]
}

@test "update_agent_skills: mais nova estoura => marca lenta e repete com a anterior" {
  MOCK_SLOW=1.7.5
  update_agent_skills >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(agent_skills_cli_state_get slow)" = "1.7.5" ]
  [ "$(agent_skills_cli_state_get good)" = "1.7.4" ]
  [ "$(paste -sd' ' "$CALLS")" = "skills@1.7.5 skills@1.7.4" ]
}

@test "update_agent_skills: versão já marcada lenta nem é tentada" {
  agent_skills_cli_state_set good 1.7.4
  agent_skills_cli_state_set slow 1.7.5
  update_agent_skills >/dev/null
  [ "$(cat "$CALLS")" = "skills@1.7.4" ]
}

@test "update_agent_skills: lenta sem nenhuma alternativa vira warn com motivo" {
  MOCK_SLOW="1.7.5 1.7.4"
  update_agent_skills >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"excedeu 60s"* ]]
}
