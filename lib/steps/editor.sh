#!/usr/bin/env bash
# lib/steps/editor.sh — plugins e LSPs do Neovim (Lazy/Mason).
# Dividido de editor_shell.sh (Série T3).
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
  # MasonInstall espera os installers em headless e retorna erro se algum falhar.
  # A comparação usa o registro atualizado, igual à lista de outdated do Mason.
  nvim --headless "+lua local ok,err=pcall(function() local r=require('mason-registry'); assert(r.refresh(), 'registry refresh failed'); local names={}; for _,p in ipairs(r.get_installed_packages()) do if p:get_installed_version()~=p:get_latest_version() then names[#names+1]=p.name end end; if #names>0 then vim.cmd('MasonInstall '..table.concat(names,' ')) end end); if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 1') end" +qa 2>&1 | _strip_ansi >> "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  if (( rc == 0 )); then
    log "  Mason.nvim: registros e ferramentas instaladas atualizados."
  else
    STEP_REASON="Mason: falha ao atualizar registros ou ferramentas; veja o log"
  fi
  return "$rc"
}
