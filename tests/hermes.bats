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
