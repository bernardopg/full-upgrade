#!/usr/bin/env bash
# steps.d/dms — DankMaterialShell plugins (custom)
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

update_dms_plugins() {
  local plugins_dir="${DMS_PLUGINS_DIR:-${HOME}/.config/DankMaterialShell/plugins}"

  if [[ ! -d "$plugins_dir" ]]; then
    log "  DankMaterialShell plugins não encontrado: ${plugins_dir}"
    return 0
  fi

  local -a updated=() failed=() skipped=() stash_conflicts=()
  local plugin dir behind

  for dir in "$plugins_dir"/*/; do
    [[ -d "$dir" ]] || continue
    plugin="$(basename "$dir")"
    [[ -d "$dir/.git" ]] || { skipped+=("$plugin"); continue; }

    git -C "$dir" fetch --quiet --depth=1 origin 2>>"$LOG_FILE" || {
      log "  Aviso: fetch falhou para DMS plugin ${plugin}"
      failed+=("$plugin")
      continue
    }

    behind="$(git -C "$dir" rev-list HEAD..origin/HEAD --count 2>/dev/null || echo 0)"
    if (( behind == 0 )); then
      continue
    fi

    log "  ${plugin}: ${behind} commit(s) atrás — atualizando..."
    if git -C "$dir" pull --ff-only --quiet origin 2>>"$LOG_FILE"; then
      updated+=("$plugin")
      continue
    fi

    # ff-only falhou: branch local divergiu do remoto (commits locais não-fast-forward,
    # tipicamente porque o HEAD apontava para um branch de PR depois mergeado upstream).
    # Auto-recuperação: stash INCONDICIONAL (no-op em tree limpo) -> reset --hard
    # -> pop se algo foi guardado. O stash incondicional elimina a janela TOCTOU
    # entre "checar se há mudanças" e "agir": o que existir no momento do stash
    # é exatamente o que será restaurado.
    local remote_ref stash_before stash_after
    remote_ref="$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || echo "origin/HEAD")"
    remote_ref="${remote_ref#refs/remotes/}"

    stash_before="$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)"
    if ! git -C "$dir" stash push --quiet --include-untracked \
         -m "full-upgrade: auto-stash ${plugin}" 2>>"$LOG_FILE"; then
      log "  Aviso: ${plugin} — stash falhou; pulando para não arriscar mudanças locais."
      failed+=("$plugin")
      continue
    fi
    stash_after="$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)"

    if ! git -C "$dir" reset --hard --quiet "$remote_ref" 2>>"$LOG_FILE"; then
      log "  Aviso: pull falhou para DMS plugin ${plugin} (reset falhou)."
      [[ "$stash_after" != "$stash_before" ]] && git -C "$dir" stash pop --quiet 2>>"$LOG_FILE"
      failed+=("$plugin")
      continue
    fi

    if [[ "$stash_after" == "$stash_before" ]]; then
      log "  ${plugin}: divergência sem mudanças locais — reset --hard para ${remote_ref}."
      updated+=("$plugin")
    elif git -C "$dir" stash pop --quiet 2>>"$LOG_FILE"; then
      log "  ${plugin}: reset para ${remote_ref} + mudanças locais restauradas."
      updated+=("$plugin")
    else
      log "  ${plugin}: resetado, mas o stash pop conflitou — suas mudanças continuam seguras no stash."
      log "  Recupere com: git -C ${dir} stash list  &&  git -C ${dir} stash pop"
      stash_conflicts+=("$plugin")
    fi
  done

  if (( ${#updated[@]} > 0 )); then
    log "  DMS plugins atualizados: ${updated[*]}"
  else
    log "  DMS plugins: todos já atualizados."
  fi
  (( ${#skipped[@]} > 0 )) && log "  DMS plugins sem git (ignorados): ${skipped[*]}"
  (( ${#failed[@]} > 0 ))  && { log "  DMS plugins com falha: ${failed[*]}"; return 1; }
  if (( ${#stash_conflicts[@]} > 0 )); then
    # Mudanças preservadas no stash mas exigem merge manual: ação do usuário,
    # não falha operacional — todo, não fail.
    STEP_REASON="stash pop com conflito em: ${stash_conflicts[*]}"
    return "$RC_TODO"
  fi
  return 0
}


