#!/usr/bin/env bash
# steps/cleanup.sh — symlinks, journal, verificação final
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

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


# Remove artefatos por-run antigos de ~/.cache/system-upgrade (logs, jsonl,
# relatórios .md, snapshots pkgs-before/after, pid de sudo-keepalive) além do
# limite MAX_LOGS por extensão. rotate_logs (lib/json.sh) já faz isso a cada
# start via setup_logging — este step existe pra dar visibilidade no resumo/
# relatório e servir de rede de segurança caso algo escape à rotação automática
# (ex.: LOG_DIR trocado em runtime, extensão nova esquecida na lista).
cleanup_old_reports() {
  [[ -d "$LOG_DIR" ]] || { log "  ${LOG_DIR} não existe; nada a limpar."; return 0; }

  local before after removed=0 ext old
  before="$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')"

  for ext in log jsonl md pkgs-before pkgs-after sudo-keepalive.pid; do
    while IFS= read -r old; do
      [[ -n "$old" ]] || continue
      rm -f -- "$old" && ((removed++))
    done < <(
      find "$LOG_DIR" -maxdepth 1 -name "full-upgrade-*.${ext}" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2- | tail -n +"$(( MAX_LOGS + 1 ))"
    )
  done

  if (( removed == 0 )); then
    log "  ${LOG_DIR}: dentro do limite de ${MAX_LOGS} arquivo(s) por tipo; nada a remover."
    return 0
  fi

  after="$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')"
  if [[ -n "$before" && -n "$after" ]]; then
    log "  Removidos ${removed} arquivo(s) além do limite de ${MAX_LOGS} (mantendo os mais recentes): ${before}MB → ${after}MB."
  else
    log "  Removidos ${removed} arquivo(s) além do limite de ${MAX_LOGS} (mantendo os mais recentes)."
  fi
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


# Limpa o cache de BUILD do AUR (clones + artefatos de makepkg), que paru/yay
# acumulam sem limite — facilmente dezenas de GB. Remove pacotes construídos,
# fontes baixadas e os diretórios src/ e pkg/ do makepkg; preserva o git clone
# (PKGBUILD/.SRCINFO/.git) para o helper reaproveitar em vez de re-clonar tudo.
# Espelha a lista de artefatos de _purge_aur_partial_sources (pacman.sh). Opera
# em ~/.cache do usuário — não precisa de sudo.
cleanup_aur_cache() {
  local -a dirs=(
    "${PARU_CLONE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/paru/clone}"
    "${XDG_CACHE_HOME:-$HOME/.cache}/yay"
  )
  local dir before after found=0
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    found=1
    before="$(du -sm "$dir" 2>/dev/null | awk '{print $1}')"

    # Diretórios src/ e pkg/ do makepkg (depth 2: <cache>/<pacote>/src).
    find "$dir" -mindepth 2 -maxdepth 2 -type d \( -name src -o -name pkg \) \
      -prune -exec rm -rf {} + 2>/dev/null || true

    # Pacotes construídos e fontes baixadas (preserva PKGBUILD/.SRCINFO/.git/.sh).
    find "$dir" -type f \( \
         -name '*.pkg.tar.*' \
      -o -name '*.tar.gz' -o -name '*.tar.xz' -o -name '*.tar.zst' -o -name '*.tar.bz2' \
      -o -name '*.tgz' -o -name '*.zip' -o -name '*.deb' -o -name '*.rpm' \
      -o -name '*.AppImage' -o -name '*.appimage' -o -name '*.jar' -o -name '*.iso' \
      -o -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' \
      \) -delete 2>/dev/null || true

    after="$(du -sm "$dir" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$before" && -n "$after" ]]; then
      log "  Cache AUR ${dir}: ${before}MB → ${after}MB (liberado $(( before - after ))MB)."
    else
      log "  Cache AUR ${dir}: limpo."
    fi
  done
  (( found )) || log "  Sem cache de build do AUR para limpar."
  return 0
}


snapshot_keep_count() {
  local keep="${SNAPSHOT_KEEP:-5}"
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || keep=5
  printf '%s' "$keep"
}


snapper_full_upgrade_ids_to_delete() {
  local keep="$1"
  awk -F'|' -v keep="$keep" '
    /full-upgrade pré-upgrade/ && $1 ~ /^[0-9]+$/ { ids[++n] = $1 }
    END {
      limit = n - keep
      for (i = 1; i <= limit; i++) print ids[i]
    }
  '
}


timeshift_full_upgrade_names_to_delete() {
  local keep="$1"
  awk -v keep="$keep" '
    /full-upgrade pré-upgrade/ { names[++n] = $1 }
    END {
      limit = n - keep
      for (i = 1; i <= limit; i++) print names[i]
    }
  '
}


cleanup_old_snapshots() {
  local tool="${SNAPSHOT_TOOL:-auto}" keep
  keep="$(snapshot_keep_count)"
  [[ "$tool" == "none" ]] && { log "  Limpeza de snapshots desabilitada (SNAPSHOT_TOOL=none)."; return 0; }

  if [[ "$tool" == "auto" ]]; then
    if has snapper; then tool="snapper"
    elif has timeshift; then tool="timeshift"
    else log "  Nenhuma ferramenta de snapshot (snapper/timeshift) instalada; pulando limpeza."; return 0; fi
  fi

  local -a victims=()
  case "$tool" in
    snapper)
      has snapper || { log "  snapper não instalado; limpeza de snapshots pulada."; return 0; }
      mapfile -t victims < <(
        snapper -c root list --csvout 2>/dev/null \
          | awk -F, 'NR > 1 { gsub(/"/, "", $1); gsub(/"/, "", $6); print $1 "|" $6 }' \
          | snapper_full_upgrade_ids_to_delete "$keep"
      )
      if (( ${#victims[@]} == 0 )); then
        log "  Nenhum snapshot snapper full-upgrade antigo para remover (mantendo ${keep})."
        return 0
      fi
      log "  Snapshots snapper full-upgrade antigos a remover: ${victims[*]} (mantendo ${keep})."
      if (( ASSUME_YES == 0 )); then
        if [[ -t 0 ]]; then
          printf '%b' "${C_YELLOW}  Remover estes snapshots snapper? [s/N] ${C_RESET}"
          local answer
          read -r answer
          case "$answer" in [sS][iI][mM]|[sS]) ;; *) log "  Limpeza de snapshots cancelada pelo usuário."; return 0 ;; esac
        else
          log "  Execução não interativa sem --yes; pulando limpeza de snapshots."
          remediation "full-upgrade --yes --only cleanup"
          return 0
        fi
      fi
      local id
      for id in "${victims[@]}"; do
        run_logged sudo snapper -c root delete "$id" || return $?
      done
      ;;
    timeshift)
      has timeshift || { log "  timeshift não instalado; limpeza de snapshots pulada."; return 0; }
      mapfile -t victims < <(timeshift --list 2>/dev/null | timeshift_full_upgrade_names_to_delete "$keep")
      if (( ${#victims[@]} == 0 )); then
        log "  Nenhum snapshot timeshift full-upgrade antigo para remover (mantendo ${keep})."
        return 0
      fi
      log "  Snapshots timeshift full-upgrade antigos a remover: ${victims[*]} (mantendo ${keep})."
      if (( ASSUME_YES == 0 )); then
        if [[ -t 0 ]]; then
          printf '%b' "${C_YELLOW}  Remover estes snapshots timeshift? [s/N] ${C_RESET}"
          local answer
          read -r answer
          case "$answer" in [sS][iI][mM]|[sS]) ;; *) log "  Limpeza de snapshots cancelada pelo usuário."; return 0 ;; esac
        else
          log "  Execução não interativa sem --yes; pulando limpeza de snapshots."
          remediation "full-upgrade --yes --only cleanup"
          return 0
        fi
      fi
      local snap
      for snap in "${victims[@]}"; do
        run_logged sudo timeshift --delete --snapshot "$snap" || return $?
      done
      ;;
    *)
      log "  SNAPSHOT_TOOL inválido para limpeza: ${tool}"
      remediation "ajuste SNAPSHOT_TOOL=auto|snapper|timeshift|none em ${FU_CONFIG_FILE}"
      return "$RC_WARN"
      ;;
  esac
}


# K2 — clusters de rebuild upstream que o pacman SEGURA (evita partial upgrade)
# até o cluster inteiro ser publicado nos mirrors. Reaparecem como pendência
# "oficial" em todo run sem serem acionáveis: rodar `pacman -Syu` de novo não os
# sobe enquanto o rebuild não fecha. Hoje: toolchain Haskell/GHC (rebuild
# periódico em massa, o caso recorrente nos runs reais).
pending_is_held_cluster() {
  local name="$1"
  [[ "$name" =~ ^(haskell-|ghc(-|$)|cabal-install$|stack$|hlint$|stylish-haskell$|happy$|alex$) ]]
}


final_pending_reason() {
  local official="$1" aur="$2"
  if (( official > 0 )); then
    printf '%s pacote(s) oficial(is) pendente(s) após sincronização da base; rode sudo pacman -Syu' "$official"
  elif (( aur > 0 )); then
    printf '%s pacote(s) AUR pendente(s); rode paru -Syu' "$aur"
  else
    printf 'nenhuma atualização pendente'
  fi
}


final_check_pending() {
  local pending=0
  local out
  local filtered
  local official_count=0 aur_count=0

  local -a held_official=() actionable_official=()
  if has checkupdates; then
    out="$(checkupdates 2>/dev/null || true)"
    if [[ -n "${out//[[:space:]]/}" ]]; then
      local _ln _nm
      while IFS= read -r _ln; do
        [[ -n "${_ln//[[:space:]]/}" ]] || continue
        _nm="${_ln%%[[:space:]]*}"
        if pending_is_held_cluster "$_nm"; then
          held_official+=("$_ln")
        else
          actionable_official+=("$_ln")
        fi
      done <<< "$out"

      if (( ${#held_official[@]} > 0 )); then
        log "  ${#held_official[@]} pacote(s) oficiais segurados por rebuild upstream (cluster Haskell/GHC); o pacman evita o partial upgrade até o cluster publicar — não acionável agora:"
        printf '%s\n' "${held_official[@]}" | tee >(_strip_ansi >> "$LOG_FILE")
      fi

      if (( ${#actionable_official[@]} > 0 )); then
        pending=1
        official_count="${#actionable_official[@]}"
        log "  Pendencias acionáveis em repositorios oficiais:"
        printf '%s\n' "${actionable_official[@]}" | tee >(_strip_ansi >> "$LOG_FILE")
        remediation "sudo pacman -Syu"
      fi
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
      aur_count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
      log "  Pendencias no AUR:"
      printf '%s\n' "$filtered" | tee >(_strip_ansi >> "$LOG_FILE")
      if has paru; then
        remediation "paru -Syu"
      elif has yay; then
        remediation "yay -Syu"
      fi
    elif [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]]; then
      log "  Pendencias restantes apenas em pacotes AUR ignorados: ${FULL_UPGRADE_AUR_IGNORE}"
    fi
  fi

  local _aur_ood_file=""
  if [[ -n "${RUN_ID:-}" ]]; then
    _aur_ood_file="${LOG_DIR}/full-upgrade-${RUN_ID}.aur-out-of-date"
  fi
  if [[ -n "$_aur_ood_file" && -s "$_aur_ood_file" ]]; then
    local _aur_ood_count
    _aur_ood_count="$(grep -c '[^[:space:]]' "$_aur_ood_file" 2>/dev/null || true)"
    if (( _aur_ood_count > 0 )); then
      log "  ${_aur_ood_count} pacote(s) AUR marcados como out-of-date pelo mantenedor (informativo; não implica update aplicável):"
      sort -u "$_aur_ood_file" | tee >(_strip_ansi >> "$LOG_FILE")
    fi
  fi

  if (( pending == 0 )); then
    if (( ${#held_official[@]} > 0 )); then
      log "  Sem pendências acionáveis: só restam pacotes segurados por rebuild upstream (aguarde o cluster publicar)."
    else
      log "  Nenhuma atualização pendente em pacman/AUR."
    fi
    return 0
  fi

  if (( official_count > 0 )); then
    log "  Motivo provável: a base de pacotes foi sincronizada depois do upgrade principal."
  fi
  STEP_REASON="$(final_pending_reason "$official_count" "$aur_count")"
  return "$RC_TODO"
}


# Auto-remediação das pendências detectadas por final_check_pending: aplica
# `pacman -Syu` para pendências oficiais acionáveis (e um retry de `paru -Syu`
# para AUR, se houver). Step separado com efeito=mutating para preservar a
# garantia read-only do --mode doctor — final_check_pending continua read.
autofix_final_pending() {
  if (( ${AUTO_FIX_FINAL_PENDING:-0} == 0 )); then
    log "  AUTO_FIX_FINAL_PENDING desligado; nada a remediar."
    return 0
  fi

  local out
  local -a actionable=()
  if has checkupdates; then
    out="$(checkupdates 2>/dev/null || true)"
    local _ln _nm
    while IFS= read -r _ln; do
      [[ -n "${_ln//[[:space:]]/}" ]] || continue
      _nm="${_ln%%[[:space:]]*}"
      pending_is_held_cluster "$_nm" || actionable+=("$_ln")
    done <<< "$out"
  fi

  local aur_pending=""
  if has paru; then
    aur_pending="$(paru -Qua 2>/dev/null || true)"
  elif has yay; then
    aur_pending="$(yay -Qua 2>/dev/null || true)"
  fi

  if (( ${#actionable[@]} == 0 )) && [[ -z "${aur_pending//[[:space:]]/}" ]]; then
    log "  Nenhuma pendência acionável para remediar."
    return 0
  fi

  if (( ${#actionable[@]} > 0 )); then
    log "  Remediando ${#actionable[@]} pendência(s) oficial(is): $(printf '%s\n' "${actionable[@]}" | awk '{print $1}' | paste -sd' ' -)"
    if ! run_logged sudo pacman -Syu --noconfirm; then
      STEP_REASON="pacman -Syu de remediação falhou"
      return 1
    fi
  fi

  if [[ -n "${aur_pending//[[:space:]]/}" ]]; then
    local -a ignore_args=() aur_cmd=()
    mapfile -t ignore_args < <(aur_ignore_args)
    case "${AUR_HELPER:-}" in
      paru) has paru && aur_cmd=(paru -Sua --skipreview --noconfirm) ;;
      yay)  has yay  && aur_cmd=(yay -Sua --noconfirm --answerclean None --answerdiff None --answeredit None --answerupgrade None) ;;
    esac
    if (( ${#aur_cmd[@]} > 0 )); then
      log "  Retry de pendências AUR via ${aur_cmd[0]}..."
      if ! run_logged "${aur_cmd[@]}" "${ignore_args[@]}"; then
        log "  Retry AUR falhou; fica para o próximo run."
        STEP_REASON="pendências AUR persistem após retry"
        return "$RC_WARN"
      fi
    fi
  fi

  log "  Pendências remediadas."
  return 0
}

