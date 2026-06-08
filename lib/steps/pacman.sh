#!/usr/bin/env bash
# steps/pacman.sh — sistema, AUR, lock, gnupg, cache, órfãos, pacnew
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

ensure_pacman_lock_is_clean() {
  local lock="/var/lib/pacman/db.lck"
  if [[ ! -e "${lock}" ]]; then
    log "  Sem lock do pacman."
    return 0
  fi

  if command -v fuser >/dev/null 2>&1 && fuser "${lock}" >/dev/null 2>&1; then
    log "  Lock do pacman em uso por outro processo: ${lock}"
    return 1
  fi

  if pgrep -x pacman >/dev/null 2>&1 || pgrep -x yay >/dev/null 2>&1 || pgrep -x paru >/dev/null 2>&1; then
    log "  Lock encontrado e ha gerenciador de pacotes em execucao: ${lock}"
    return 1
  fi

  log "  Lock stale detectado, removendo: ${lock}"
  run_logged sudo rm -f -- "${lock}"
}


repair_gnupg_runtime() {
  local gnupg_dir="${GNUPGHOME:-$HOME/.gnupg}"
  local crls_dir="${gnupg_dir}/crls.d"

  if [[ ! -e "$gnupg_dir" ]]; then
    log "  GNUPG home não encontrado: ${gnupg_dir}"
    return 0
  fi

  run_logged chmod 700 "$gnupg_dir"

  if [[ -d "$crls_dir" ]]; then
    run_logged chmod 700 "$crls_dir"
  fi

  if has systemctl; then
    systemctl --user reset-failed dirmngr.service dirmngr.socket >/dev/null 2>&1 || true
  fi

  if has gpgconf; then
    gpgconf --kill dirmngr >/dev/null 2>&1 || true
  fi
}


repair_known_pacman_conflicts_before_update() {
  local fixed=0

  # vlc-plugin-luajit is an AUR rebuild that provides vlc-plugin-lua. When the
  # repo VLC split package moves ahead first, pacman cannot answer the conflict
  # prompt under --noconfirm, so replace the stale AUR plugin with the official
  # package before the full upgrade transaction.
  if pacman -Qq vlc-plugin-luajit >/dev/null 2>&1 && pacman -Si vlc-plugin-lua >/dev/null 2>&1; then
    local pending_vlc=""
    if has checkupdates; then
      pending_vlc="$(checkupdates 2>/dev/null | awk '$1 ~ /^vlc($|-)|^libvlc$/ { print; found=1 } END { exit found ? 0 : 1 }' || true)"
    fi

    if [[ -n "${pending_vlc//[[:space:]]/}" ]]; then
      log "  Conflito conhecido: vlc-plugin-luajit (AUR) bloqueia vlc-plugin-lua oficial."
      log "  Trocando para o plugin oficial antes do update não interativo."
      run_logged sudo pacman -Rdd --noconfirm vlc-plugin-luajit || return 1
      run_logged sudo pacman -Syu --needed --noconfirm vlc-plugin-lua || return 1
      fixed=1
    fi
  fi

  if (( fixed == 0 )); then
    log "  Sem conflitos pacman conhecidos para reparar antes do update."
  fi

  return 0
}


refresh_pacman_keys() {
  log "  Atualizando chaves do pacman..."
  run_logged sudo pacman-key --refresh-keys 2>/dev/null || {
    log "  Falha ao atualizar chaves (rede ou keyserver indisponível); continuando."
    return 0
  }
  run_logged sudo pacman-key --populate archlinux 2>/dev/null || true
}


update_system_aur() {
  local -a ignore_args=()
  mapfile -t ignore_args < <(aur_ignore_args)

  if (( ${#ignore_args[@]} > 0 )); then
    log "  Ignorando no update automático: ${FULL_UPGRADE_AUR_IGNORE}"
  fi

  repair_known_pacman_conflicts_before_update || return 1

  if has paru; then
    local -a cmd=(paru -Syu --skipreview --noconfirm --combinedupgrade "${ignore_args[@]}")
    (( DEVEL_UPDATE )) && cmd+=(--devel)
    local _paru_out _paru_rc
    local _paru_attempt
    for _paru_attempt in 1 2; do
      (( _paru_attempt > 1 )) && {
        log "  paru: tentativa ${_paru_attempt}/2 — limpando tarballs AUR em cache antes de retry..."
        find "${XDG_CACHE_HOME:-$HOME/.cache}/paru/clone" -maxdepth 2 -name "*.tar.*" -delete 2>/dev/null || true
        sleep 5
      }
      _paru_out="$("${cmd[@]}" 2>&1)"
      _paru_rc=$?
      printf '%s\n' "$_paru_out" | tee >(_strip_ansi >> "$LOG_FILE")
      (( _paru_rc == 0 )) && break
    done
    if (( _paru_rc != 0 )); then
      if printf '%s\n' "$_paru_out" | grep -qiE 'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'; then
        log "  paru: falha de rede transitória após 2 tentativas — aviso, não erro."
        _paru_rc="$RC_WARN"
      fi
    fi
    (( _paru_rc == RC_WARN )) && return "$RC_WARN"
    # Avisar pacotes AUR ainda desatualizados após update (PKGBUILD travado ou out-of-date)
    local -a still_outdated=()
    mapfile -t still_outdated < <(paru -Qu --aur 2>/dev/null | awk '{print $1}' || true)
    if (( ${#still_outdated[@]} > 0 )); then
      log "  ${C_YELLOW}Aviso: ${#still_outdated[@]} pacote(s) AUR ainda desatualizados (PKGBUILD travado?): ${still_outdated[*]}${C_RESET}"
      log "  Verifique: paru -Si <pacote>  ou  https://aur.archlinux.org/packages/<pacote>"
    fi
    return $_paru_rc
  fi

  if has yay; then
    local -a cmd=(yay -Syu --noconfirm --answerclean None --answerdiff None --answeredit None --answerupgrade None "${ignore_args[@]}")
    run_logged "${cmd[@]}"
    return $?
  fi

  if has pacman; then
    local -a cmd=(sudo pacman -Syu --noconfirm "${ignore_args[@]}")
    run_logged "${cmd[@]}"
    return $?
  fi

  log "  Nenhum gerenciador de pacotes Arch encontrado."
  return 1
}


aur_ignore_args() {
  local item
  [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]] || return 0

  for item in $FULL_UPGRADE_AUR_IGNORE; do
    [[ -n "$item" ]] || continue
    printf '%s\n' "--ignore=${item}"
  done
}


cleanup_paccache() {
  run_logged sudo paccache -r -k 2
}


cleanup_orphans() {
  local -a orphans=()
  mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)

  if (( ${#orphans[@]} == 0 )); then
    log "  Nenhum pacote orfao encontrado."
    return 0
  fi

  log "  Pacotes orfaos encontrados (${#orphans[@]}): ${orphans[*]}"

  if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
      printf '%b' "${C_YELLOW}  Remover pacotes orfãos? [s/N] ${C_RESET}"
      local answer
      read -r answer
      case "$answer" in
        [sS][iI][mM]|[sS]) ;;
        *) log "  Remoção de orfãos cancelada pelo usuário."; return 0 ;;
      esac
    else
      log "  Execução não interativa sem --yes; pulando remoção de órfãos."
      return 0
    fi
  fi

  run_logged sudo pacman -Rns --noconfirm -- "${orphans[@]}"
}


check_pacnew_files() {
  if ! has pacdiff; then
    log "  pacdiff não encontrado (instale pacman-contrib)."
    return 0
  fi

  local -a pacnew=()
  mapfile -t pacnew < <(sudo pacdiff --output 2>/dev/null)

  if (( ${#pacnew[@]} == 0 )); then
    log "  Nenhum arquivo .pacnew/.pacsave pendente."
    return 0
  fi

  log "  ${C_YELLOW}Aviso: ${#pacnew[@]} arquivo(s) .pacnew/.pacsave requerem atenção manual:${C_RESET}"
  local f
  for f in "${pacnew[@]}"; do
    log "    ${f}"
  done
  log "  Execute: sudo pacdiff  (ou use DIFFPROG=meld pacdiff)"
  STEP_REASON="${#pacnew[@]} arquivo(s) .pacnew/.pacsave pendente(s) de merge"
  return "$RC_TODO"
}


