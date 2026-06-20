#!/usr/bin/env bats
# tests/fail_fast.bats — política --fail-fast no run_step (F5).
#
# NOTA: o bats aborta o teste quando um comando retorna != 0 (errexit-emulation).
# A função de step falha de propósito (`_fail`) dispara isso dentro de run_step,
# no `"$@"`. Sufixar `|| true` coloca a chamada numa lista condicional, o que
# desliga o errexit para toda a cadeia — e, por rodar no mesmo shell, as mutações
# de estado (STEP_RESULTS, RUN_ABORTED) persistem para as asserções.

load test_helper

setup() {
  load_libs
  # json.sh não é carregado pelo test_helper; neutraliza a gravação de eventos.
  write_step_event_json() { :; }
  # Estado de tracking limpo por teste.
  STEP_NAMES=(); STEP_RESULTS=(); STEP_TIMES=(); STEP_CATEGORIES=()
  HAS_FAIL=0; RUN_ABORTED=0; FAIL_FAST=0; DRY_RUN=0
  FULL_UPGRADE_SKIP=""
}

_fail() { return 1; }
_ok()   { return 0; }

@test "fail-fast: 1º fail aborta e marca os restantes como skip" {
  FAIL_FAST=1
  run_step "Passo A (falha)" _fail || true
  run_step "Passo B" _ok
  run_step "Passo C" _ok
  [ "${STEP_RESULTS[0]}" = "fail" ]
  [ "${STEP_RESULTS[1]}" = "skip" ]
  [ "${STEP_RESULTS[2]}" = "skip" ]
  [ "${RUN_ABORTED}" -eq 1 ]
  [ "${HAS_FAIL}" -eq 1 ]
}

@test "fail-fast: motivo do skip é 'abortado por --fail-fast'" {
  FAIL_FAST=1
  local logf
  logf="$(mktemp)"
  LOG_FILE="$logf"; QUIET=1   # log() grava só no arquivo, sem terminal
  run_step "Passo A (falha)" _fail || true
  run_step "Passo B" _ok
  grep -q "abortado por --fail-fast" "$logf"
  rm -f "$logf"
}

@test "default (sem fail-fast): fail não aborta; steps seguintes rodam" {
  FAIL_FAST=0
  run_step "Passo A (falha)" _fail || true
  run_step "Passo B" _ok
  [ "${STEP_RESULTS[0]}" = "fail" ]
  [ "${STEP_RESULTS[1]}" = "ok" ]
  [ "${RUN_ABORTED}" -eq 0 ]
}

@test "continue-on-fail explícito equivale ao default" {
  FAIL_FAST=0
  run_step "Passo A (falha)" _fail || true
  run_step "Passo B (falha)" _fail || true
  run_step "Passo C" _ok
  [ "${STEP_RESULTS[2]}" = "ok" ]
}
