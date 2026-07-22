#!/usr/bin/env bash
# steps.d/tokensave — atualização do TokenSave pelo self-updater oficial.
# shellcheck shell=bash
# shellcheck disable=SC2034 # STEP_REASON é consumido pelo framework em core.sh

update_tokensave() {
  local tokensave_bin before after output rc
  tokensave_bin="${TOKENSAVE_BIN:-$(command -v tokensave 2>/dev/null || true)}"

  if [[ -z "$tokensave_bin" || ! -x "$tokensave_bin" ]]; then
    log "  TokenSave não encontrado no PATH (defina TOKENSAVE_BIN no config se necessário)."
    return 0
  fi

  before="$("$tokensave_bin" --version 2>/dev/null | head -1 || true)"
  log "  TokenSave em: ${tokensave_bin} (versão atual: ${before:-desconhecida})"

  output="$(run_network_cmd "$tokensave_bin" upgrade 2>&1)"
  rc=$?
  [[ -n "${output//[[:space:]]/}" ]] && printf '%s\n' "$output" | _strip_ansi | tee -a "$LOG_FILE"

  if (( rc == RC_WARN )); then
    STEP_REASON="rede indisponível para tokensave upgrade"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  TokenSave: self-update falhou (rc=${rc}); instalação atual foi preservada."
    STEP_REASON="tokensave upgrade falhou"
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  after="$("$tokensave_bin" --version 2>/dev/null | head -1 || true)"
  log "  TokenSave após upgrade: ${after:-versão não detectada}."
  return 0
}
