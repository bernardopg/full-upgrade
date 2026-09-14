#!/usr/bin/env bash
# lib/steps/editor.sh — plugins e LSPs do Neovim (Lazy/Mason).
# Dividido de editor_shell.sh (Série T3).
# shellcheck shell=bash

#!/usr/bin/env bash
# steps/editor_shell.sh — nvim, zsh/omz, hyprpm
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

update_nvim_lazy() {
  if ! nvim --version >/dev/null 2>&1; then
    log "  nvim não encontrado."
    return 1
  fi

  local lazy_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
  if [[ ! -d "$lazy_dir" ]]; then
    log "  Lazy.nvim não instalado (${lazy_dir} ausente)."
    return 0
  fi

  log "  Atualizando plugins Lazy.nvim..."
  local count rc
  count="$(find "$lazy_dir" -maxdepth 1 -mindepth 1 -type d | wc -l)"
  nvim --headless "+Lazy! sync" +qa 2>&1 | _strip_ansi >> "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  log "  Lazy.nvim: ${count} plugins presentes, sincronização concluída."
  return "$rc"
}



update_nvim_mason() {
  if ! nvim --version >/dev/null 2>&1; then
    log "  nvim não encontrado."
    return 1
  fi

  local mason_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason"
  if [[ ! -d "$mason_dir" ]]; then
    log "  Mason.nvim não instalado (${mason_dir} ausente)."
    return 0
  fi

  log "  Atualizando LSPs/tools do Mason.nvim..."
  local rc
  nvim --headless "+MasonUpdate" +qa 2>&1 | _strip_ansi >> "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  log "  Mason.nvim: atualização de registros concluída."
  return "$rc"
}
