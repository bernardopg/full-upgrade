#!/usr/bin/env bash
# steps.d/copilot — GitHub Copilot CLI (custom)
# shellcheck shell=bash

update_copilot_cli() {
  local copilot_bin="${COPILOT_BIN:-$(command -v copilot 2>/dev/null || true)}"
  if [[ -z "$copilot_bin" || ! -x "$copilot_bin" ]]; then
    log "  GitHub Copilot CLI não encontrado (defina COPILOT_BIN no config)."
    return 0
  fi
  local output rc
  output="$("$copilot_bin" update 2>&1)"
  rc=$?
  printf '%s\n' "$output" >> "$LOG_FILE"
  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
}


