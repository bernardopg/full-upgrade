#!/usr/bin/env bats
# tests/hermes.bats — helper puro do gate de update do Hermes (steps.d).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/10-hermes.sh"
}

@test "hermes_is_current: 'Already up to date' => atual (rc 0)" {
  run hermes_is_current $'→ Fetching from upstream...\n✓ Already up to date.'
  [ "$status" -eq 0 ]
}

@test "hermes_is_current: 'up to date' minúsculo => atual" {
  run hermes_is_current "everything up to date"
  [ "$status" -eq 0 ]
}

@test "hermes_is_current: update disponível => não-atual (rc != 0)" {
  run hermes_is_current $'→ Fetching...\n→ 2 commit(s) behind, run update'
  [ "$status" -ne 0 ]
}

@test "hermes_is_current: saída vazia => não-atual (não pula)" {
  run hermes_is_current ""
  [ "$status" -ne 0 ]
}

@test "catálogo dá ao Hermes tempo para probe, update e drain do gateway" {
  local row timeout_s
  row="$(step_catalog | grep '^Atualizar Hermes|')"
  timeout_s="$(cut -d'|' -f5 <<<"$row")"
  [ "$timeout_s" -eq 300 ]
}

@test "update_hermes: timeout do probe cai para o update completo" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="test"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  hermes() { printf '✓ Update complete!\n'; }

  run update_hermes
  [ "$status" -eq 0 ]
  [ -s "${LOG_DIR}/hermes-update-${RUN_ID}.log" ]
  grep -q 'Update complete' "${LOG_DIR}/hermes-update-${RUN_ID}.log"
}

@test "update_hermes: falha de rede no update vira warn com log no motivo" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="network"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  hermes() {
    printf 'fatal: unable to access repository: Could not resolve host\n'
    return 1
  }

  local rc
  set +e
  update_hermes >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"rede indisponível"* ]]
  [[ "$STEP_REASON" == *"hermes-update-network.log"* ]]
}
