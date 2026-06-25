#!/usr/bin/env bash
# steps.d/hermes — integração Hermes Agent. Roda por presença (só se `hermes`
# estiver no PATH); inofensivo em máquinas sem a ferramenta.
# shellcheck shell=bash

# Verdadeiro (rc 0) se a saída de `hermes update --check` indica que já está
# atualizado. Puro/testável. Qualquer outra coisa => há update (não pula).
hermes_is_current() {
  printf '%s' "$1" | grep -qiE 'already up.to.date|up to date|no updates? available|nenhuma atualiza'
}

update_hermes() {
  local hermes_bin
  hermes_bin="$(command -v hermes || true)"

  if [[ -z "$hermes_bin" ]]; then
    log "  Hermes não encontrado no PATH."
    return 0
  fi

  log "  Hermes em: ${hermes_bin}"

  # Otimização: o `hermes update` completo (git pull + deps Node + sync de skills)
  # leva ~20s mesmo sem novidade. Antes, `hermes update --check` (rápido: só
  # fetch + compara) decide se há update; se não houver, pula o update pesado.
  local check_out
  check_out="$(CI=1 NO_COLOR=1 TERM=dumb hermes update --check 2>&1 | sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')"
  if hermes_is_current "$check_out"; then
    log "  Hermes já está na versão mais recente (check); pulando update."
    return 0
  fi

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


