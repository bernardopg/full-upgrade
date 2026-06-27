#!/usr/bin/env bash
# steps.d/openclaw — integração OpenClaw. Roda por presença (só se `openclaw`
# no PATH ou OPENCLAW_BIN definido).
# shellcheck shell=bash

# Lê o JSON de `openclaw update --dry-run --json` e diz se há update de CORE
# disponível (currentVersion != targetVersion). Puro/testável. rc 0 = update
# disponível (ou indeterminado → não pular, roda o update normal); rc 1 = já na
# última versão.
openclaw_update_available() {
  local json="$1" cur tgt
  cur="$(printf '%s' "$json" | grep -oE '"currentVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  tgt="$(printf '%s' "$json" | grep -oE '"targetVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  [[ -n "$cur" && -n "$tgt" ]] || return 0   # indeterminado: não pula
  [[ "$cur" != "$tgt" ]]
}

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

  # Otimização: o `openclaw update` real é caro (~50s — npm refresh + plugin sync
  # + restart do gateway) mesmo quando já está atualizado. Antes, checa via
  # dry-run (rápido) se há update de core; se não houver, pula o update real.
  local dry
  dry="$("$openclaw_bin" update --dry-run --json 2>/dev/null || true)"
  if [[ -n "$dry" ]] && ! openclaw_update_available "$dry"; then
    log "  OpenClaw ${current_ver:-} já na versão mais recente (dry-run); pulando update."
    return 0
  fi

  local output rc
  output="$("$openclaw_bin" update 2>&1)"
  rc=$?

  # Log completo no arquivo de log
  log_raw "
===== openclaw update ($(date -Is)) =====
$output"

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