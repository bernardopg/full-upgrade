#!/usr/bin/env bash
# steps.d/dms — DankMaterialShell plugins (custom)
# shellcheck shell=bash

update_dms_plugins() {
  local plugins_dir="${HOME}/.config/DankMaterialShell/plugins"

  if [[ ! -d "$plugins_dir" ]]; then
    log "  DankMaterialShell plugins não encontrado: ${plugins_dir}"
    return 0
  fi

  local -a updated=() failed=() skipped=()
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
    # Estratégia de auto-recuperação:
    #   - working tree limpo  -> reset --hard para o remoto (descarta commits locais órfãos)
    #   - working tree sujo    -> stash -> reset --hard -> stash pop (preserva edições reais)
    local remote_ref dirty=0
    remote_ref="$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || echo "origin/HEAD")"
    remote_ref="${remote_ref#refs/remotes/}"

    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
      dirty=1
    fi

    if (( dirty )); then
      log "  ${plugin}: divergência com working tree sujo — stash + reset + restore..."
      if git -C "$dir" stash push --quiet --include-untracked 2>>"$LOG_FILE" \
        && git -C "$dir" reset --hard --quiet "$remote_ref" 2>>"$LOG_FILE"; then
        if git -C "$dir" stash pop --quiet 2>>"$LOG_FILE"; then
          log "  ${plugin}: reset para ${remote_ref} + mudanças locais restauradas."
          updated+=("$plugin")
        else
          log "  Aviso: ${plugin} resetado mas stash pop teve conflito (ver 'git stash list')."
          failed+=("$plugin")
        fi
      else
        log "  Aviso: pull falhou para DMS plugin ${plugin} (stash/reset falhou)."
        failed+=("$plugin")
      fi
    else
      log "  ${plugin}: divergência sem mudanças locais — reset --hard para ${remote_ref}."
      if git -C "$dir" reset --hard --quiet "$remote_ref" 2>>"$LOG_FILE"; then
        updated+=("$plugin")
      else
        log "  Aviso: pull falhou para DMS plugin ${plugin} (reset falhou)."
        failed+=("$plugin")
      fi
    fi
  done

  if (( ${#updated[@]} > 0 )); then
    log "  DMS plugins atualizados: ${updated[*]}"
  else
    log "  DMS plugins: todos já atualizados."
  fi
  (( ${#skipped[@]} > 0 )) && log "  DMS plugins sem git (ignorados): ${skipped[*]}"
  (( ${#failed[@]} > 0 ))  && { log "  DMS plugins com falha: ${failed[*]}"; return 1; }
  return 0
}


