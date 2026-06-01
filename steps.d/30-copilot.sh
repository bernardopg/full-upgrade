#!/usr/bin/env bash
# steps.d/copilot — GitHub Copilot CLI (custom)
# shellcheck shell=bash

update_copilot_cli() {
  local copilot_bin="${HOME}/.local/bin/copilot"
  if [[ ! -x "$copilot_bin" ]]; then
    log "  GitHub Copilot CLI não encontrado em ~/.local/bin/copilot."
    return 0
  fi
  local output rc
  output="$("$copilot_bin" update 2>&1)"
  rc=$?
  printf '%s\n' "$output" >> "$LOG_FILE"
  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
}


