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


update_omz() {
  local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
  if [[ ! -f "$zsh_dir/tools/upgrade.sh" ]]; then
    log "  oh-my-zsh não encontrado em: ${zsh_dir}"
    return 1
  fi

  local output rc
  output="$(ZSH="$zsh_dir" zsh "$zsh_dir/tools/upgrade.sh" 2>&1)"
  rc=$?
  log_raw "$output"

  # Filtrar: "Updating Oh My Zsh", ASCII art, links sociais, linhas vazias
  printf '%s\n' "$output" \
    | grep -v -E '^(Updating Oh My Zsh|[[:space:]]*(__|/ __|/ /|\\____|/____)|[[:space:]]*$)' \
    | grep -v -E '(https?://|discord\.gg|commitgoods\.com|follow us|Join our|swag at|x\.com|twitter\.com)' \
    | grep -v '^$' \
    || true

  # Rede fora (GitHub inacessível) é transitório — warn, não fail (contrato RC).
  if (( rc != 0 )) && printf '%s\n' "$output" | grep -qiE "$NETWORK_TRANSIENT_RE"; then
    log "  Falha de rede ao atualizar Oh My Zsh — aviso, não erro."
    STEP_REASON="rede indisponível durante omz update"
    return "$RC_WARN"
  fi
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
  local plugin dir behind fetch_err net_fail=0

  for dir in "$plugins_dir"/*/; do
    plugin="$(basename "$dir")"
    [[ "$plugin" == "example" ]] && continue
    [[ -d "$dir/.git" ]] || { skipped+=("$plugin"); continue; }

    if ! fetch_err="$(git -C "$dir" fetch --quiet --depth=1 origin 2>&1)"; then
      log_raw "$fetch_err"
      log "  Aviso: fetch falhou para plugin ${plugin}"
      printf '%s\n' "$fetch_err" | grep -qiE "$NETWORK_TRANSIENT_RE" && net_fail=1
      failed+=("$plugin")
      continue
    fi

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
  if (( ${#failed[@]} > 0 )); then
    log "  Falha em plugins: ${failed[*]}"
    # Se houve falha de rede (GitHub fora), é transitório: warn, não fail.
    if (( net_fail )); then
      STEP_REASON="rede indisponível ao buscar plugins (${#failed[@]} afetados)"
      return "$RC_WARN"
    fi
    return 1
  fi
  return 0
}


update_yazi_plugins() {
  local pkg_toml="${XDG_CONFIG_HOME:-$HOME/.config}/yazi/package.toml"

  if [[ ! -f "$pkg_toml" ]]; then
    log "  Sem plugins gerenciados (${pkg_toml} ausente)."
    return 0
  fi

  local count
  count="$(grep -c '^use = ' "$pkg_toml" 2>/dev/null || echo 0)"
  log "  Atualizando ${count} plugin(s) Yazi via ya pkg upgrade..."

  local output rc
  output="$(ya pkg upgrade 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc != 0 )); then
    if printf '%s\n' "$output" | grep -q 'modified the contents'; then
      log "  Plugin(s) com modificações locais — rode 'ya pkg upgrade --discard' manualmente."
      STEP_REASON="plugin(s) Yazi com modificações locais (--discard para sobrescrever)"
      return "$RC_TODO"
    fi
    log "  Aviso: ya pkg upgrade retornou ${rc}."
    return "$RC_WARN"
  fi

  log "  Plugins Yazi: upgrade concluído."
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


