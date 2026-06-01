#!/usr/bin/env bash
# steps/ai.sh — CLIs de IA genéricos (claude code)
# shellcheck shell=bash

update_claude_code() {
  local claude_bin
  claude_bin="$(command -v claude || true)"
  if [[ -z "$claude_bin" ]]; then
    log "  claude não encontrado no PATH."
    return 0
  fi
  local output rc
  output="$(claude update 2>&1)"
  rc=$?
  printf '%s\n' "$output" >> "$LOG_FILE"
  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
}


