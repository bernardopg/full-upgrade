#!/usr/bin/env bash
# steps.d/openclaw — integração OpenClaw. Roda por presença (só se `openclaw`
# no PATH ou OPENCLAW_BIN definido).
# shellcheck shell=bash

# Lê o JSON de `openclaw update --dry-run --json` e diz se há update de CORE
# disponível (currentVersion != targetVersion). Puro/testável. rc 0 = update
# disponível (ou indeterminado → não pular, roda o update normal); rc 1 = já na
# última versão.
openclaw_update_available() {
  local json="$1" fallback_target="${2:-}" cur tgt
  cur="$(printf '%s' "$json" | grep -oE '"currentVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  tgt="$(printf '%s' "$json" | grep -oE '"targetVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  [[ -n "$tgt" ]] || tgt="$fallback_target"
  [[ -n "$cur" && -n "$tgt" ]] || return 0   # indeterminado: não pula
  [[ "$cur" != "$tgt" ]]
}

openclaw_registry_version() {
  grep -oE '"?v?[0-9]+(\.[0-9]+){1,3}"?' | head -1 | tr -d '"v'
}

openclaw_update_has_partial_failure() {
  grep -qiE 'Failed to update|after plugin update failure|Update Result:[[:space:]]*(FAILED|ERROR)'
}

# A CLI pode estar atualizada enquanto o gateway systemd --user não reiniciou.
# Reportamos a condição, mas não alteramos estado/configuração sem decisão explícita.
openclaw_verify_gateway() {
  has systemctl || return 0
  local state
  state="$(systemctl --user is-failed openclaw-gateway.service 2>/dev/null || true)"
  [[ "$state" == "failed" ]] || return 0
  log "  Gateway OpenClaw está em estado failed após a checagem."
  remediation "openclaw doctor --fix && openclaw gateway restart"
  STEP_REASON="openclaw-gateway.service falhada; rode openclaw doctor --fix"
  return "$RC_WARN"
}

update_openclaw() {
  local openclaw_bin="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null || true)}"

  if [[ -z "$openclaw_bin" || ! -x "$openclaw_bin" ]]; then
    log "  OpenClaw não encontrado (defina OPENCLAW_BIN no config)."
    openclaw_verify_gateway
    return $?
  fi

  log "  OpenClaw em: ${openclaw_bin}"

  # Tentar obter versão atual para relatório
  local current_ver
  current_ver="$("$openclaw_bin" --version 2>/dev/null | head -1 || true)"
  [[ -n "$current_ver" ]] && log "  Versão atual: ${current_ver}"

  # Otimização: o `openclaw update` real é caro (~50s — npm refresh + plugin sync
  # + restart do gateway) mesmo quando já está atualizado. Antes, checa via
  # dry-run (rápido) se há update de core; se não houver, pula o update real.
  local dry latest=""
  dry="$("$openclaw_bin" update --dry-run --json 2>/dev/null || true)"
  # OpenClaw 2026.6.11 passou a emitir targetVersion:null para instalações npm.
  # Consulta o registry como fallback barato antes de reinstalar o mesmo pacote
  # e reiniciar o gateway sem necessidade.
  if [[ "$dry" == *'"targetVersion": null'* ]] && has npm; then
    latest="$(run_network_cmd npm view openclaw@latest version --json 2>/dev/null | openclaw_registry_version || true)"
  fi
  if [[ -n "$dry" ]] && ! openclaw_update_available "$dry" "$latest"; then
    local current_core
    current_core="$(printf '%s' "$dry" | sed -nE 's/.*"currentVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
    log "  OpenClaw ${current_core:-${current_ver:-}} já na versão mais recente; pulando reinstalação e restart do gateway."
    openclaw_verify_gateway
    return $?
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
      openclaw_verify_gateway
      return $?
    fi
    if printf '%s\n' "$output" | openclaw_update_has_partial_failure; then
      log "  OpenClaw core processado, mas um ou mais plugins falharam durante o update."
      # shellcheck disable=SC2034 # consumida pelo orquestrador após retorno do step
      STEP_REASON="OpenClaw: falha parcial ao atualizar plugins"
      rc="$RC_WARN"
    else
      log "  OpenClaw atualizado com sucesso."
    fi
  fi

  # Mostrar saída relevante no terminal (sem linhas vazias, sem ANSI)
  printf '%s\n' "$output" \
    | sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' \
    | grep -v '^$' \
    | head -30 \
    || true

  if (( rc == 0 )); then
    openclaw_verify_gateway
    return $?
  fi
  return "$rc"
}
