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


# ── Parsers do nvim-treesitter ──────────────────────────────────────────────────
# O Lazy atualiza o plugin nvim-treesitter, mas os parsers compilados (.so)
# ficam na versão antiga: com a ABI nova do plugin, o highlight quebra até
# alguém rodar :TSUpdate. O step roda o update síncrono headless: :TSUpdateSync
# no branch master, require('nvim-treesitter').update():wait() no branch main.
# O require vem primeiro porque o lazy.nvim só cria os comandos ao carregar.
treesitter_installed() {
  [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/nvim-treesitter" ]]
}

update_treesitter_parsers() {
  local lua out rc
  lua="$(mktemp --suffix=.lua)" || return "$RC_WARN"
  cat >"$lua" <<'LUA'
-- Com lazy.nvim o plugin só carrega no require: antes dele, :TSUpdateSync não existe.
local has, ts = pcall(require, 'nvim-treesitter')
if vim.fn.exists(':TSUpdateSync') == 2 then
  if not pcall(vim.cmd, 'TSUpdateSync') then vim.cmd('cquit 1') end
elseif has and type(ts.update) == 'function' then
  local task = ts.update()
  if task and task.wait then task:wait(600000) end
else
  vim.cmd('cquit 3')
end
vim.cmd('qall!')
LUA
  out="$(run_network_cmd timeout 900 nvim --headless -c "luafile ${lua}")"
  rc=$?
  rm -f "$lua"
  printf '%s\n' "$out" | _strip_ansi | grep -iE 'install|updat|up-to-date|error|compil' | tail -n 15 | log_stream
  ((rc == 0)) && return 0
  if ((rc == RC_WARN)); then
    STEP_REASON="nvim-treesitter: rede indisponível"
    return "$RC_WARN"
  fi
  if ((rc == 3)); then
    STEP_REASON="nvim-treesitter sem :TSUpdateSync nem update() (versão desconhecida)"
    return "$RC_TODO"
  fi
  STEP_REASON="atualização dos parsers do nvim-treesitter falhou (rc=${rc})"
  return 1
}
