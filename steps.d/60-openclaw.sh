#!/usr/bin/env bash
# steps.d/openclaw — integração OpenClaw. Roda por presença (só se `openclaw`
# no PATH ou OPENCLAW_BIN definido).
# shellcheck shell=bash

update_openclaw() {
  local openclaw_bin="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null || true)}"

  if [[ -z "$openclaw_bin" || ! -x "$openclaw_bin" ]]; then
    log "  OpenClaw não encontrado (defina OPENCLAW_BIN no config)."
    return 0
  fi

  log "  OpenClaw em: ${openclaw_bin}"

  # Tentar obter versão atual para relatório
  local current_ver
  current_ver="$("$openclaw_bin" --version 2>/dev/null | head -1 || true)"
  [[ -n "$current_ver" ]] && log "  Versão atual: ${current_ver}"

  local output rc
  output="$("$openclaw_bin" update 2>&1)"
  rc=$?

  # Log completo no arquivo de log
  {
    printf '\n===== openclaw update (%s) =====\n' "$(date -Is)"
    printf '%s\n' "$output"
  } >> "$LOG_FILE"

  # Tratar "já atualizado" — OpenClaw pode retornar 0 com mensagem específica
  if (( rc == 0 )); then
    if printf '%s\n' "$output" | grep -qiE 'already up.to.date|already at latest|já est[áa] atualizado|latest version|up to date|nothing to do|no updates? available'; then
      log "  OpenClaw ${current_ver:-} já na versão mais recente."
      return 0
    fi
    log "  OpenClaw atualizado com sucesso."
  fi

  # Mostrar saída relevante no terminal (sem linhas vazias, sem ANSI)
  printf '%s\n' "$output" \
    | sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' \
    | grep -v '^$' \
    | head -30 \
    || true

  return "$rc"
}