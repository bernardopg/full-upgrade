#!/usr/bin/env bash
# lib/steps/shell.sh — shell e tools de terminal: Oh My Zsh, plugins Zsh, Yazi e Hyprland (hyprpm).
# Dividido de editor_shell.sh (Série T3).
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)



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
    | log_out || true

  # Rede fora (GitHub inacessível) é transitório — warn, não fail (contrato RC).
  if (( rc != 0 )) && grep -qiE "$NETWORK_TRANSIENT_RE" <<<"$output"; then
    log "  Falha de rede ao atualizar Oh My Zsh — aviso, não erro."
    STEP_REASON="rede indisponível durante omz update"
    return "$RC_WARN"
  fi
  return "$rc"
}




# Um `pull --ff-only` falha por dois motivos bem diferentes: o upstream
# reescreveu o histórico (force-push, comum em plugins de um mantenedor só) ou
# há trabalho local no clone. Só o segundo exige decisão do usuário. Com a
# árvore limpa, o clone é descartável: guarda o HEAD antigo numa ref de resgate
# e realinha em origin/HEAD.
plugin_realign_to_upstream() {
  local dir="$1" plugin="$2" old_head rescue

  [[ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] || return 1

  old_head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
  rescue="refs/full-upgrade/pre-realign/$(date +%Y%m%d-%H%M%S)"
  git -C "$dir" update-ref "$rescue" "$old_head" 2>>"$LOG_FILE" || return 1

  # origin/HEAD já veio do fetch feito pelo chamador.
  git -C "$dir" reset --hard --quiet origin/HEAD 2>>"$LOG_FILE" || return 1

  log "  ${plugin}: histórico reescrito pelo upstream — realinhado em origin/HEAD (HEAD anterior ${old_head:0:7} salvo em ${rescue})."
  return 0
}




update_omz_custom_plugins() {
  local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
  local plugins_dir="${zsh_dir}/custom/plugins"

  if [[ ! -d "$plugins_dir" ]]; then
    log "  Diretório de plugins customizados não encontrado: ${plugins_dir}"
    return 0
  fi

  local -a dirs=()
  local dir
  for dir in "$plugins_dir"/*/; do
    [[ "$(basename "$dir")" == "example" ]] && continue
    dirs+=("$dir")
  done
  zsh_git_plugins_update "${dirs[@]}"
}

# Atualiza os clones git de plugins Zsh passados como argumento (diretórios).
# Compartilhado pelos plugins customizados do Oh My Zsh e pelos clones avulsos.
# rc: 0 · RC_WARN rede · RC_TODO modificações locais/conflito · 1 fetch falhou
# por motivo que não é rede.
zsh_git_plugins_update() {
  local -a updated=() failed=() skipped=() dirty=()
  local plugin dir behind fetch_err net_fail=0

  for dir in "$@"; do
    plugin="$(basename "$dir")"
    [[ -d "$dir/.git" ]] || { skipped+=("$plugin"); continue; }

    # Repo travado por conflito anterior: git recusa fetch/pull/stash, então
    # reportar a causa real em vez de falhar com mensagem enganosa a cada run.
    if git_has_unmerged "$dir"; then
      log "  ${plugin}: conflito pendente de resolução (arquivos unmerged) — update adiado."
      log "  Resolva com: git -C ${dir} status"
      dirty+=("$plugin")
      continue
    fi

    if ! fetch_err="$(git_fetch_full "$dir")"; then
      log_raw "$fetch_err"
      log "  Aviso: fetch falhou para plugin ${plugin}"
      grep -qiE "$NETWORK_TRANSIENT_RE" <<<"$fetch_err" && net_fail=1
      failed+=("$plugin")
      continue
    fi

    behind="$(git -C "$dir" rev-list HEAD..origin/HEAD --count 2>/dev/null || echo 0)"
    if (( behind == 0 )); then
      log "  ${plugin}: já atualizado."
      continue
    fi

    log "  ${plugin}: ${behind} commit(s) atrás — atualizando..."
    if git_pull_ff_only "$dir" && ! git_has_unmerged "$dir"; then
      updated+=("$plugin")
      log "  ${plugin}: atualizado."
    elif git_has_unmerged "$dir"; then
      # pull "bem-sucedido" que deixou conflito (pull.rebase+autostash): restaura
      # a árvore para o plugin seguir carregável e reporta como sujo.
      log "  ${plugin}: pull deixou conflito — restaurando árvore."
      git -C "$dir" checkout -f HEAD -- . 2>>"$LOG_FILE" || true
      git -C "$dir" reset --quiet HEAD -- . 2>>"$LOG_FILE" || true
      dirty+=("$plugin")
    elif plugin_realign_to_upstream "$dir" "$plugin"; then
      updated+=("$plugin")
    else
      log "  Aviso: pull falhou para plugin ${plugin} (modificações locais)."
      dirty+=("$plugin")
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
  # Modificações locais não são erro do run: exigem decisão de quem editou.
  if (( ${#dirty[@]} > 0 )); then
    log "  Plugins com modificações locais (resolva manualmente): ${dirty[*]}"
    STEP_REASON="plugin(s) com modificações locais: ${dirty[*]}"
    return "$RC_TODO"
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
    if grep -q 'modified the contents' <<<"$output"; then
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


# Atualiza o cache local do Tealdeer (`tldr`). A operação baixa apenas páginas
# de referência configuradas pelo próprio usuário; não atualiza o pacote nem
# altera arquivos do sistema. Falhas da rede ou do cliente são não bloqueantes,
# pois um cache anterior continua utilizável offline.
update_tldr_cache() {
  has tldr || { log "  tldr não encontrado."; return 0; }

  log "  Atualizando cache local do tldr…"
  local out rc
  out="$(run_network_cmd tldr --update 2>&1)"
  rc=$?
  [[ -n "$out" ]] && log "  ${out//$'\n'/ }"

  if (( rc == 0 )); then
    log "  Cache local do tldr atualizado."
    return 0
  fi

  # O portão de conectividade já classifica DNS/conectividade como RC_WARN.
  # Erros locais do cliente também não podem derrubar todo o upgrade: o cache
  # existente segue disponível e a correção não é automaticamente segura.
  log "  Não foi possível atualizar o cache do tldr; o cache atual foi preservado."
  return "$RC_WARN"
}


# ── Plugins Zsh avulsos (clones git fora do Oh My Zsh) ─────────────────────────
# Plugins instalados com `git clone` e carregados por `source` direto no .zshrc
# (ex.: ~/.local/share/zsh-defer, como manda o README do romkatv) não pertencem
# a nenhum gerenciador: nem o Oh My Zsh nem o pacman os conhecem, e o clone fica
# no commit do dia da instalação. Mesma política dos plugins customizados do
# OMZ (fast-forward, realinhamento só com árvore limpa, conflito vira todo).
# ZSH_STANDALONE_PLUGIN_DIRS (espaço ou vírgula; globs e ~ aceitos) substitui a
# detecção padrão.
zsh_standalone_plugin_dirs() {
  local -a pats=()
  local p d omz
  if [[ -n "${ZSH_STANDALONE_PLUGIN_DIRS:-}" ]]; then
    read -ra pats <<<"${ZSH_STANDALONE_PLUGIN_DIRS//,/ }"
  else
    pats+=("${XDG_DATA_HOME:-$HOME/.local/share}/zsh-*")
    pats+=("$HOME/.zsh/plugins/*")
    pats+=("${ZDOTDIR:-$HOME}/plugins/*")
    pats+=("${XDG_CONFIG_HOME:-$HOME/.config}/zsh/plugins/*")
  fi
  omz="$(readlink -f "${ZSH:-$HOME/.oh-my-zsh}" 2>/dev/null || true)"
  for p in "${pats[@]}"; do
    p="${p/#\~/$HOME}"
    # shellcheck disable=SC2086  # expansão de glob intencional
    for d in $p; do
      [[ -d "$d/.git" ]] || continue
      # O Oh My Zsh e os customs dele têm step próprio.
      [[ -n "$omz" && "$(readlink -f "$d")" == "$omz"* ]] && continue
      printf '%s\n' "$d"
    done
  done | awk '!seen[$0]++'
}

update_zsh_standalone_plugins() {
  local -a dirs=()
  mapfile -t dirs < <(zsh_standalone_plugin_dirs)
  if ((${#dirs[@]} == 0)); then
    log "  Nenhum clone git de plugin Zsh fora do Oh My Zsh."
    return 0
  fi
  zsh_git_plugins_update "${dirs[@]}"
}


# ── Plugins do tmux (tpm) ───────────────────────────────────────────────────────
# O tpm clona os plugins do .tmux.conf e só os atualiza com prefix+U dentro do
# tmux. `bin/update_plugins all` faz o mesmo de fora (o tpm se atualiza junto,
# como plugin). Sem tpm, nenhum plugin tem dono.
tpm_dir() {
  local d
  local -a cands=()
  [[ -n "${TMUX_PLUGIN_MANAGER_PATH:-}" ]] && cands+=("${TMUX_PLUGIN_MANAGER_PATH%/}/tpm")
  cands+=("$HOME/.tmux/plugins/tpm" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tpm")
  for d in "${cands[@]}"; do
    [[ -x "${d}/bin/update_plugins" ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 0
}

update_tmux_plugins() {
  local tpm
  tpm="$(tpm_dir)"
  [[ -n "$tpm" ]] || { log "  tpm não encontrado."; return 0; }
  _native_update "tpm update_plugins" "${tpm}/bin/update_plugins" all
}


# ── Plugins do fish (fisher) ────────────────────────────────────────────────────
# O fisher instala plugins a partir de ~/.config/fish/fish_plugins e só os
# atualiza com `fisher update` (que também atualiza o próprio fisher).
fisher_installed() { has fish && fish -c 'type -q fisher' 2>/dev/null; }

update_fisher_plugins() { _native_update "fisher update" fish -c 'fisher update'; }


# ── Gerenciadores de plugin Zsh (zinit, antidote, sheldon) ──────────────────────
# Cada um clona os plugins que gerencia e só os atualiza a pedido, numa sessão
# interativa. O step chama o comando de update de cada gerenciador presente,
# carregando-o num zsh não interativo (os dois primeiros são funções de shell).
zinit_home() {
  local d
  for d in "${ZINIT_HOME:-}" "${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git" "$HOME/.zinit/bin" "$HOME/.local/share/zinit/bin"; do
    [[ -n "$d" && -f "${d}/zinit.zsh" ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 0
}

antidote_home() {
  local d
  for d in "${ANTIDOTE_HOME:-}" "${ZDOTDIR:-$HOME}/.antidote" "$HOME/.antidote" /usr/share/zsh-antidote; do
    [[ -n "$d" && -f "${d}/antidote.zsh" ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 0
}

zsh_plugin_managers() {
  [[ -n "$(zinit_home)" ]] && printf 'zinit\n'
  [[ -n "$(antidote_home)" ]] && printf 'antidote\n'
  has sheldon && printf 'sheldon\n'
  return 0
}

update_zsh_plugin_managers() {
  local m rc worst=0 home
  local -a mgrs=()
  mapfile -t mgrs <<<"$(zsh_plugin_managers)"
  [[ -n "${mgrs[0]:-}" ]] || { log "  Nenhum gerenciador de plugin Zsh (zinit, antidote, sheldon)."; return 0; }
  for m in "${mgrs[@]}"; do
    log "  ${m}:"
    case "$m" in
      zinit)
        home="$(zinit_home)"
        _native_update "zinit update" zsh -c "source '${home}/zinit.zsh' && zinit self-update && zinit update --all --quiet"
        ;;
      antidote)
        home="$(antidote_home)"
        _native_update "antidote update" zsh -c "source '${home}/antidote.zsh' && antidote update"
        ;;
      sheldon) _native_update "sheldon lock --update" sheldon lock --update ;;
    esac
    rc=$?
    ((rc == 1 || (worst != 1 && rc > worst))) && worst=$rc
  done
  return "$worst"
}
