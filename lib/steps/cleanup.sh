#!/usr/bin/env bash
# steps/cleanup.sh — symlinks, journal, verificação final
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

cleanup_broken_symlinks_local_bin() {
  local dir="${HOME}/.local/bin"
  local -a broken=()
  local link
  local removed=0

  [[ -d "$dir" ]] || return 0

  mapfile -t broken < <(find "$dir" -maxdepth 1 -type l ! -e -print 2>/dev/null)

  if (( ${#broken[@]} == 0 )); then
    log "  Sem symlinks quebrados em ${dir}."
    return 0
  fi

  for link in "${broken[@]}"; do
    log "  Removendo symlink quebrado: ${link} -> $(readlink "$link" 2>/dev/null || echo '<sem-target>')"
    rm -f -- "$link" && ((removed++))
  done

  log "  Symlinks quebrados removidos de ~/.local/bin: ${removed}"
  return 0
}


cleanup_journal() {
  if ! has journalctl; then
    log "  journalctl não encontrado."
    return 0
  fi
  log "  Vacuumizando journal (mantendo 2 semanas / 500MB)..."
  run_logged sudo journalctl --vacuum-time=2weeks --vacuum-size=500M
}


final_check_pending() {
  local pending=0
  local out
  local filtered

  if has checkupdates; then
    out="$(checkupdates 2>/dev/null || true)"
    if [[ -n "${out//[[:space:]]/}" ]]; then
      pending=1
      log "  Pendencias em repositorios oficiais:"
      printf '%s\n' "$out" | tee -a "$LOG_FILE"
    fi
  fi

  if has yay; then
    out="$(yay -Qua 2>/dev/null || true)"
  elif has paru; then
    out="$(paru -Qua 2>/dev/null || true)"
  fi

  if [[ -n "${out//[[:space:]]/}" ]]; then
    filtered="$(
      printf '%s\n' "$out" | awk -v ignored="$FULL_UPGRADE_AUR_IGNORE" '
        BEGIN {
          split(ignored, names, /[[:space:]]+/)
          for (i in names) if (names[i] != "") skip[names[i]] = 1
        }
        {
          name = $1
          if (!(name in skip)) print
        }
      '
    )"

    if [[ -n "${filtered//[[:space:]]/}" ]]; then
      pending=1
      log "  Pendencias no AUR:"
      printf '%s\n' "$filtered" | tee -a "$LOG_FILE"
    elif [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]]; then
      log "  Pendencias restantes apenas em pacotes AUR ignorados: ${FULL_UPGRADE_AUR_IGNORE}"
    fi
  fi

  if (( pending == 0 )); then
    log "  Nenhuma atualização pendente em pacman/AUR."
    return 0
  fi

  return "$RC_TODO"
}


