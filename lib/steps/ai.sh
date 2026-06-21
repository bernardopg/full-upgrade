#!/usr/bin/env bash
# steps/ai.sh — CLIs de IA genéricos (claude code)
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module (STEP_REASON etc.)

# H1 — atualiza o opencode, instalado fora do npm (~/.opencode/bin) via seu
# subcomando próprio `opencode upgrade`. Falha de rede → RC_WARN; outra falha do
# upgrade também → RC_WARN (não-fatal, não derruba o run). Loga versão antes/depois.
update_opencode() {
  if ! has opencode; then
    log "  opencode não encontrado no PATH."
    return 0
  fi
  local before after out rc
  before="$(opencode --version 2>/dev/null | head -1)"
  log "  opencode atual: ${before:-?}"
  out="$(run_network_cmd opencode upgrade)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^$' || true
  if (( rc == RC_WARN )); then
    log "  opencode: falha de rede ao atualizar."
    STEP_REASON="rede indisponível para opencode upgrade"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  opencode: falha ao atualizar (rc=${rc})."
    STEP_REASON="opencode upgrade falhou"
    return "$RC_WARN"
  fi
  after="$(opencode --version 2>/dev/null | head -1)"
  log "  opencode agora: ${after:-?}"
  return 0
}

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
  log_raw "$output"
  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
}


