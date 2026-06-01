#!/usr/bin/env bash
# steps/editor_shell.sh — nvim, zsh/omz, hyprpm
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

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
  nvim --headless "+Lazy! sync" +qa >> "$LOG_FILE" 2>&1
  rc=$?
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
  nvim --headless "+MasonUpdate" +qa >> "$LOG_FILE" 2>&1
  rc=$?
  log "  Mason.nvim: atualização de registros concluída."
  return "$rc"
}


update_omz() {
  local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
  if [[ ! -f "$zsh_dir/tools/upgrade.sh" ]]; then
    log "  oh-my-zsh não encontrado em: ${zsh_dir}"
    return 1
  fi

  local output rc
  output="$(ZSH="$zsh_dir" zsh "$zsh_dir/tools/upgrade.sh" 2>&1)"
  rc=$?
  printf '%s\n' "$output" >> "$LOG_FILE"

  # Filtrar: "Updating Oh My Zsh", ASCII art, links sociais, linhas vazias
  printf '%s\n' "$output" \
    | grep -v -E '^(Updating Oh My Zsh|[[:space:]]*(__|/ __|/ /|\\____|/____)|[[:space:]]*$)' \
    | grep -v -E '(https?://|discord\.gg|commitgoods\.com|follow us|Join our|swag at|x\.com|twitter\.com)' \
    | grep -v '^$' \
    || true
  return "$rc"
}


update_omz_custom_plugins() {
  local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
  local plugins_dir="${zsh_dir}/custom/plugins"

  if [[ ! -d "$plugins_dir" ]]; then
    log "  Diretório de plugins customizados não encontrado: ${plugins_dir}"
    return 0
  fi

  local -a updated=() failed=() skipped=()
  local plugin dir behind

  for dir in "$plugins_dir"/*/; do
    plugin="$(basename "$dir")"
    [[ "$plugin" == "example" ]] && continue
    [[ -d "$dir/.git" ]] || { skipped+=("$plugin"); continue; }

    git -C "$dir" fetch --quiet --depth=1 origin 2>>"$LOG_FILE" || {
      log "  Aviso: fetch falhou para plugin ${plugin}"
      failed+=("$plugin")
      continue
    }

    behind="$(git -C "$dir" rev-list HEAD..origin/HEAD --count 2>/dev/null || echo 0)"
    if (( behind == 0 )); then
      log "  ${plugin}: já atualizado."
      continue
    fi

    log "  ${plugin}: ${behind} commit(s) atrás — atualizando..."
    if git -C "$dir" pull --ff-only --quiet origin 2>>"$LOG_FILE"; then
      updated+=("$plugin")
      log "  ${plugin}: atualizado."
    else
      log "  Aviso: pull falhou para plugin ${plugin} (possível conflito local)."
      failed+=("$plugin")
    fi
  done

  (( ${#updated[@]} > 0 ))  && log "  Plugins atualizados: ${updated[*]}"
  (( ${#skipped[@]} > 0 ))  && log "  Não são repositórios git (ignorados): ${skipped[*]}"
  (( ${#failed[@]} > 0 ))   && { log "  Falha em plugins: ${failed[*]}"; return 1; }
  return 0
}


update_hyprpm() {
  local store_dir="${XDG_DATA_HOME:-$HOME/.local/share}/hyprpm"

  if [[ ! -d "$store_dir" ]]; then
    log "  hyprpm sem repositórios registrados; pulando."
    return 0
  fi

  local -a repos=()
  mapfile -t repos < <(find "$store_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

  if (( ${#repos[@]} == 0 )); then
    log "  hyprpm: sem plugins instalados."
    return 0
  fi

  run_logged hyprpm update
}


