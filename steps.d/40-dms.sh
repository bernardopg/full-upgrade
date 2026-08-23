#!/usr/bin/env bash
# steps.d/dms — integração de plugins do DankMaterialShell. Roda por presença
# (só se o diretório de plugins existir; veja DMS_PLUGINS_DIR).
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Os helpers git compartilhados (git_has_unmerged, git_fetch_full,
# git_pull_ff_only) vivem em lib/core.sh — plugins Zsh, DMS e OBS repetiam o
# mesmo par fetch/pull e por isso carregavam os mesmos dois bugs: repo raso
# quebrando o ff-only, e pull.rebase+autostash deixando conflito com rc=0.
update_dms_plugins() {
  local plugins_dir="${DMS_PLUGINS_DIR:-${HOME}/.config/DankMaterialShell/plugins}"

  if [[ ! -d "$plugins_dir" ]]; then
    log "  DankMaterialShell plugins não encontrado: ${plugins_dir}"
    return 0
  fi

  local -a updated=() failed=() skipped=() stash_conflicts=() repo_managed=() conflicted=() gone=()
  local plugin dir behind fetch_err net_fail=0 track_ref recovery rec_status rec_ref

  for dir in "$plugins_dir"/*/; do
    [[ -d "$dir" ]] || continue
    plugin="$(basename "$dir")"
    [[ "$plugin" == ".repos" ]] && continue
    if [[ ! -d "$dir/.git" ]]; then
      # Plugins instalados pelo registry do DMS são symlinks para subpastas de
      # monorepos clonados em .repos/<hash>/ — atualizados no loop de monorepos
      # abaixo, não aqui. Só é "sem git" de verdade quem não aponta pra lá.
      if [[ -L "${dir%/}" && "$(readlink -f "${dir%/}")" == "$plugins_dir/.repos/"* ]]; then
        repo_managed+=("$plugin")
      else
        skipped+=("$plugin")
      fi
      continue
    fi

    # Repo travado por conflito pendente: git recusa fetch/pull/stash. Reportar a
    # causa real (ação do usuário) em vez de tentar e falhar com mensagem enganosa.
    if git_has_unmerged "$dir"; then
      log "  ${plugin}: conflito pendente de resolução (arquivos unmerged) — update adiado."
      log "  Resolva com: git -C ${dir} status  &&  git -C ${dir} checkout -f HEAD -- ."
      conflicted+=("$plugin")
      continue
    fi

    if ! fetch_err="$(git_fetch_full "$dir")"; then
      log_raw "$fetch_err"
      # Upstream morto (404/privado/credencial revogada) antes de rede: um repo
      # apagado no GitHub nunca volta, então insistir como "falha" quebraria o
      # step em todo run futuro. Vira pendência acionável do usuário.
      if git_remote_gone "$fetch_err"; then
        log "  ${plugin}: upstream inacessível permanentemente ($(git -C "$dir" remote get-url origin 2>/dev/null))"
        gone+=("$plugin")
        continue
      fi
      log "  Aviso: fetch falhou para DMS plugin ${plugin}"
      grep -qiE "$NETWORK_TRANSIENT_RE" <<<"$fetch_err" && net_fail=1
      failed+=("$plugin")
      continue
    fi

    track_ref="$(git_tracking_ref "$dir")"
    behind="$(git -C "$dir" rev-list "HEAD..${track_ref}" --count 2>/dev/null || echo 0)"
    if (( behind == 0 )); then
      continue
    fi

    log "  ${plugin}: ${behind} commit(s) atrás — atualizando..."
    if git_pull_ff_only "$dir"; then
      # Cinto de segurança: nenhum caminho de sucesso pode deixar o repo unmerged.
      if git_has_unmerged "$dir"; then
        log "  ${plugin}: pull retornou sucesso mas deixou conflito — restaurando árvore."
        git -C "$dir" checkout -f HEAD -- . 2>>"$LOG_FILE" || true
        git -C "$dir" reset --quiet HEAD -- . 2>>"$LOG_FILE" || true
        conflicted+=("$plugin")
        continue
      fi
      updated+=("$plugin")
      continue
    fi

    # ff-only falhou: branch local divergiu do remoto (commits locais não-fast-forward,
    # tipicamente porque o HEAD apontava para um branch de PR depois mergeado upstream)
    # ou branch sem upstream configurado (o `git pull origin` recusa sem saber o que
    # mergear). Recuperação centralizada em git_recover_plugin_repo (lib/core.sh):
    # stash incondicional -> reset --hard para o HEAD do origin -> pop.
    if ! recovery="$(git_recover_plugin_repo "$dir" "$plugin")"; then
      log "  Aviso: ${plugin} — recuperação de divergência falhou (stash/reset); pulando para não arriscar mudanças locais."
      failed+=("$plugin")
      continue
    fi
    read -r rec_status rec_ref <<<"$recovery"
    case "$rec_status" in
      clean)
        log "  ${plugin}: divergência sem mudanças locais — reset --hard para ${rec_ref}."
        updated+=("$plugin")
        ;;
      restored)
        log "  ${plugin}: reset para ${rec_ref} + mudanças locais restauradas."
        updated+=("$plugin")
        ;;
      conflict)
        log "  ${plugin}: resetado para ${rec_ref}; o stash pop conflitou."
        log "  Árvore restaurada para o upstream (plugin funcional); suas mudanças seguem intactas no stash."
        log "  Recupere com: git -C ${dir} stash list  &&  git -C ${dir} stash pop"
        stash_conflicts+=("$plugin")
        ;;
    esac
  done

  # Monorepos do registry DMS (.repos/<hash>/): plugins como dankBatteryAlerts,
  # dankKDEConnect, githubHeatmap e grimblast vivem como symlink -> subpasta
  # destes clones. Atualizá-los aqui cobre o que o loop acima não vê.
  local repo_dir repo_name m_recovery m_status m_ref
  for repo_dir in "$plugins_dir"/.repos/*/; do
    [[ -d "$repo_dir/.git" ]] || continue
    repo_name="$(basename "$repo_dir")"

    if git_has_unmerged "$repo_dir"; then
      log "  monorepo ${repo_name}: conflito pendente de resolução (arquivos unmerged) — update adiado."
      log "  Resolva com: git -C ${repo_dir} status"
      conflicted+=(".repos/${repo_name}")
      continue
    fi

    if ! fetch_err="$(git_fetch_full "$repo_dir")"; then
      log_raw "$fetch_err"
      if git_remote_gone "$fetch_err"; then
        log "  monorepo ${repo_name}: upstream inacessível permanentemente ($(git -C "$repo_dir" remote get-url origin 2>/dev/null))"
        gone+=(".repos/${repo_name}")
        continue
      fi
      log "  Aviso: fetch falhou para monorepo DMS ${repo_name}"
      grep -qiE "$NETWORK_TRANSIENT_RE" <<<"$fetch_err" && net_fail=1
      failed+=(".repos/${repo_name}")
      continue
    fi

    track_ref="$(git_tracking_ref "$repo_dir")"
    behind="$(git -C "$repo_dir" rev-list "HEAD..${track_ref}" --count 2>/dev/null || echo 0)"
    (( behind == 0 )) && continue

    log "  monorepo ${repo_name} ($(git -C "$repo_dir" remote get-url origin 2>/dev/null)): ${behind} commit(s) atrás — atualizando..."
    if git_pull_ff_only "$repo_dir"; then
      if git_has_unmerged "$repo_dir"; then
        log "  monorepo ${repo_name}: pull retornou sucesso mas deixou conflito — restaurando árvore."
        git -C "$repo_dir" checkout -f HEAD -- . 2>>"$LOG_FILE" || true
        git -C "$repo_dir" reset --quiet HEAD -- . 2>>"$LOG_FILE" || true
        conflicted+=(".repos/${repo_name}")
        continue
      fi
      updated+=(".repos/${repo_name}")
    else
      # Paridade com o loop de plugins: mesma recuperação centralizada de
      # divergência (branch de PR mergeado upstream, branch sem upstream...).
      # Antes o monorepo só logava "divergência local?" e virava fail duro do
      # step — caso real: .repos/dankmail com HEAD num branch 'local' sem
      # upstream, todo run falhava embora o conteúdo já estivesse mergeado
      # upstream e a recuperação fosse a mesma do loop de plugins.
      if ! m_recovery="$(git_recover_plugin_repo "$repo_dir" ".repos/${repo_name}")"; then
        log "  Aviso: pull falhou para monorepo DMS ${repo_name} (stash/reset falhou)."
        failed+=(".repos/${repo_name}")
        continue
      fi
      read -r m_status m_ref <<<"$m_recovery"
      case "$m_status" in
        clean)
          log "  monorepo ${repo_name}: divergência sem mudanças locais — reset --hard para ${m_ref}."
          updated+=(".repos/${repo_name}")
          ;;
        restored)
          log "  monorepo ${repo_name}: reset para ${m_ref} + mudanças locais restauradas."
          updated+=(".repos/${repo_name}")
          ;;
        conflict)
          log "  monorepo ${repo_name}: resetado para ${m_ref}; o stash pop conflitou."
          log "  Árvore restaurada para o upstream (plugin funcional); suas mudanças seguem intactas no stash."
          log "  Recupere com: git -C ${repo_dir} stash list  &&  git -C ${repo_dir} stash pop"
          stash_conflicts+=(".repos/${repo_name}")
          ;;
      esac
    fi
  done

  if (( ${#updated[@]} > 0 )); then
    log "  DMS plugins atualizados: ${updated[*]}"
  else
    log "  DMS plugins: todos já atualizados."
  fi
  (( ${#repo_managed[@]} > 0 )) && log "  DMS plugins via registry (.repos, atualizados como monorepo): ${repo_managed[*]}"
  (( ${#skipped[@]} > 0 )) && log "  DMS plugins sem git (ignorados): ${skipped[*]}"
  (( ${#conflicted[@]} > 0 )) && log "  DMS plugins travados por conflito pendente: ${conflicted[*]}"
  if (( ${#gone[@]} > 0 )); then
    log "  DMS plugins com upstream removido/inacessível: ${gone[*]}"
    log "  O plugin segue funcional com o código já clonado; só não recebe updates."
    log "  Resolva apontando o remote para o novo endereço (git -C <dir> remote set-url origin <url>)"
    log "  ou removendo o clone órfão — confira antes quais plugins fazem symlink para ele."
  fi
  if (( ${#failed[@]} > 0 )); then
    log "  DMS plugins com falha: ${failed[*]}"
    # GitHub inacessível é transitório: warn (contrato RC), não fail.
    if (( net_fail )); then
      STEP_REASON="rede indisponível ao buscar plugins DMS (${#failed[@]} afetados)"
      return "$RC_WARN"
    fi
    return 1
  fi
  if (( ${#stash_conflicts[@]} > 0 || ${#conflicted[@]} > 0 || ${#gone[@]} > 0 )); then
    # Mudanças preservadas no stash mas exigem merge manual, repo já travado por
    # conflito anterior, ou upstream que deixou de existir: ação do usuário, não
    # falha operacional — todo, não fail. Fail aqui seria permanente e inútil.
    local -a pend=()
    (( ${#stash_conflicts[@]} > 0 )) && pend+=("stash pop com conflito em: ${stash_conflicts[*]}")
    (( ${#conflicted[@]} > 0 )) && pend+=("conflito pendente em: ${conflicted[*]}")
    (( ${#gone[@]} > 0 )) && pend+=("upstream removido/inacessível em: ${gone[*]}")
    STEP_REASON="$(printf '%s; ' "${pend[@]}")"
    STEP_REASON="${STEP_REASON%; }"
    return "$RC_TODO"
  fi
  return 0
}


