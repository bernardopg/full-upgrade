#!/usr/bin/env bash
# lib/steps/manual_apps.sh — steps para programas instalados FORA de qualquer
# gerenciador de pacotes (sem pacman/AUR/flatpak/snap por trás). Cada programa
# tem seu próprio step, descobre sua versão e usa o mecanismo de atualização
# nativo (subcomando self-update) ou, quando não há, reporta via RC_TODO.
# Todos rodam por presença do binário (cmd_deps do catálogo + checagem interna)
# e convertem falha de rede em RC_WARN — nunca derrubam o run por flutuação de
# rede ou por uma ferramenta de terceiros.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module

# ── Factory droid ───────────────────────────────────────────────────────────────
# CLI de IA da Factory, instalada via instalador próprio em ~/.local/bin (sem
# pacote). Possui self-update nativo: `droid update` (e `--check` só verifica).
update_droid() {
  has droid || { log "  droid não encontrado."; return 0; }

  local current
  current="$(droid --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  droid versão atual: ${current:-desconhecida}"

  # `droid update --check` é read-only: evita o download/instalação quando já
  # está atualizado (e poupa rede). rc 0 + saída sem "update" => já atual.
  local check
  check="$(run_network_cmd droid update --check 2>&1)"
  local check_rc=$?
  printf '%s\n' "$check" >>"$LOG_FILE"
  if (( check_rc != 0 )); then
    log "  Não foi possível verificar atualização do droid (rede/Factory indisponível)."
    return "$RC_WARN"
  fi
  if printf '%s' "$check" | grep -qiE 'up[- ]?to[- ]?date|already|latest|nenhuma atualiza'; then
    log "  droid já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando droid…"
  if ! run_network_cmd droid update; then
    log "  Falha ao atualizar o droid."
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  local newver
  newver="$(droid --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  droid atualizado para ${newver:-?}."
  return 0
}
