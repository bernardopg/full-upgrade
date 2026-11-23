#!/usr/bin/env bats
# tests/headroom_memory.bats — step 'Sincronizar memória Headroom' e
# 'Doctor: memória Headroom': resumo da saída do agent-memory-sync, binário
# ausente, ajustes, problemas (todo), rc inesperado (warn) e o --check do
# doctor. O agent-memory-sync é um script falso em HOME descartável.

load test_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/mcp.sh"
  source "${FU_LIB}/steps/doctor/dev.sh"
  QUIET=0 STEP_REASON="" LOG_FILE=/dev/null
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export CLAUDE_ENV_DIR="$BATS_TEST_TMPDIR/claude-env"
  FAKE="$BATS_TEST_TMPDIR/agent-memory-sync"
  export AGENT_MEMORY_SYNC_BIN="$FAKE"
}

# Script falso: imprime $1 (com \n) e sai com $2; grava os argumentos recebidos.
_fake() {
  printf '#!/bin/sh\necho "$*" > "%s.args"\nprintf "%s"\nexit %s\n' "$FAKE" "$1" "${2:-0}" > "$FAKE"
  chmod +x "$FAKE"
}

@test "resumo: conta ajustes e problemas, ignora 'everything already in sync'" {
  run headroom_memory_sync_summary $'updated /x: headroom_memory MCP\nparked Headroom profile init-x\nPROBLEM: port 8791 is held by pid 1\n'
  [ "$output" = $'2\t1' ]
  run headroom_memory_sync_summary "everything already in sync"
  [ "$output" = $'0\t0' ]
  run headroom_memory_sync_summary ""
  [ "$output" = $'0\t0' ]
}

@test "binário: AGENT_MEMORY_SYNC_BIN, ~/.local/bin, claude-env e ausente" {
  run agent_memory_sync_bin
  [ "$status" -eq 1 ]
  _fake ""
  run agent_memory_sync_bin
  [ "$output" = "$FAKE" ]
  AGENT_MEMORY_SYNC_BIN=""
  mkdir -p "$CLAUDE_ENV_DIR/scripts" "$HOME/.local/bin"
  cp "$FAKE" "$CLAUDE_ENV_DIR/scripts/agent-memory-sync"
  run agent_memory_sync_bin
  [ "$output" = "$CLAUDE_ENV_DIR/scripts/agent-memory-sync" ]
  cp "$FAKE" "$HOME/.local/bin/agent-memory-sync"
  run agent_memory_sync_bin
  [ "$output" = "$HOME/.local/bin/agent-memory-sync" ]
}

@test "step: sem agent-memory-sync é ok e não faz nada" {
  autofix_headroom_memory >/dev/null || status=$?
  [ "${status:-0}" -eq 0 ]
}

@test "step: alinhado e com ajustes reaplicados são ok, sem argumentos" {
  _fake "everything already in sync\\n"
  run autofix_headroom_memory
  [ "$status" -eq 0 ]
  [[ "$output" == *"já alinhada"* ]]
  [ "$(cat "$FAKE.args")" = "" ]
  _fake "updated /home/x/.config/opencode/opencode.json: headroom_memory MCP\\n"
  run autofix_headroom_memory
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 ajuste(s)"* ]]
}

@test "step: PROBLEM vira todo; rc != 0 vira warn" {
  _fake "PROBLEM: port 8791 is held by pid 42, not headroom.service\\n"
  autofix_headroom_memory >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "memória Headroom: 1 problema(s) que o agent-memory-sync não corrige" ]
  unset status
  _fake "Traceback\\n" 3
  autofix_headroom_memory >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "agent-memory-sync: rc=3" ]
}

@test "doctor: roda --check; 0 ok, 1 todo com contagem, outro rc warn" {
  _fake "everything already in sync\\n" 0
  run doctor_headroom_memory
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE.args")" = "--check" ]
  _fake "would update /x: headroom_memory MCP\\nPROBLEM: nothing listens on port 8791\\n" 1
  doctor_headroom_memory >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "memória Headroom fora do alinhamento: 1 ajuste(s) pendente(s), 1 problema(s)" ]
  unset status
  _fake "" 2
  doctor_headroom_memory >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "agent-memory-sync --check: rc=2" ]
}

@test "doctor: sem agent-memory-sync é ok" {
  doctor_headroom_memory >/dev/null || status=$?
  [ "${status:-0}" -eq 0 ]
}
