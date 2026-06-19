#!/usr/bin/env bash
# steps.d/hermes — integração Hermes Agent. Roda por presença (só se `hermes`
# estiver no PATH); inofensivo em máquinas sem a ferramenta.
# shellcheck shell=bash

update_hermes() {
  local hermes_bin
  hermes_bin="$(command -v hermes || true)"

  if [[ -z "$hermes_bin" ]]; then
    log "  Hermes não encontrado no PATH."
    return 0
  fi

  log "  Hermes em: ${hermes_bin}"
  local output_file rc
  output_file="${LOG_DIR}/hermes-update-${RUN_ID}.log"

  # Hermes can emit TTY animations from nested Node postinstall/demo tooling.
  # Keep the full output in its own log and show only actionable lines here.
  CI=1 NO_COLOR=1 TERM=dumb HERMES_ACCEPT_HOOKS=1 hermes update --yes >"$output_file" 2>&1
  rc=$?
  {
    printf '\n===== hermes update (%s) =====\n' "$(date -Is)"
    sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' "$output_file"
  } >> "$LOG_FILE"

  grep -E '^(✓|⚠|✗|→|  ✓|  ⚠|  →|Tip:|Up to date|Already|No update|error:|Error:|warning:|Warning:|fatal:|Traceback)' "$output_file" \
    | sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' \
    | tail -40 || true
  log "  Log Hermes: ${output_file}"
  return "$rc"
}


