#!/usr/bin/env bash
# steps.d/85-obs — OBS Studio: atualização de plugins user-scope + doctor.
# Roda por presença (só se o OBS estiver instalado). Sourced por full-upgrade.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Diretório de config do OBS. Nativo: ~/.config/obs-studio; Flatpak:
# ~/.var/app/com.obsproject.Studio/config/obs-studio. OBS_CONFIG_DIR no config
# do usuário tem precedência; sem override, resolve pelo tipo de instalação.
_obs_config_dir() {
  if [[ -n "${OBS_CONFIG_DIR:-}" ]]; then
    printf '%s' "$OBS_CONFIG_DIR"
    return 0
  fi
  local native="${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio"
  local flatpak_dir="$HOME/.var/app/com.obsproject.Studio/config/obs-studio"
  if pacman -Q obs-studio >/dev/null 2>&1 || [[ -d "$native" ]]; then
    printf '%s' "$native"
  elif [[ -d "$flatpak_dir" ]]; then
    printf '%s' "$flatpak_dir"
  else
    printf '%s' "$native"
  fi
}

# Detecta a instalação do OBS: pacote oficial/AUR (binário obs) ou Flatpak.
# Emite "pacman <ver>" | "flatpak <ver>" | nada (rc 1).
_obs_install_kind() {
  local ver
  if ver="$(pacman -Q obs-studio 2>/dev/null)"; then
    printf 'pacman %s' "${ver#obs-studio }"
    return 0
  fi
  if has flatpak && ver="$(flatpak info com.obsproject.Studio 2>/dev/null | sed -n 's/^[[:space:]]*Version:[[:space:]]*//p')"; then
    printf 'flatpak %s' "$ver"
    return 0
  fi
  return 1
}

# Atualizar OBS (plugins e extensões).
# O binário e os plugins empacotados (obs-*, ffmpeg-obs, do repo/AUR) já são
# cobertos pelo step de pacman/AUR; Flatpak, pelo step de Flatpak. O que NADA
# cobria: plugins instalados na mão em ~/.config/obs-studio/plugins. Aqui,
# os que forem clone git recebem fetch+pull ff-only; os demais são inventariados
# com aviso de atualização manual.
update_obs_plugins() {
  local kind
  if ! kind="$(_obs_install_kind)"; then
    log "  OBS Studio não instalado."
    return 0
  fi
  log "  OBS Studio: ${kind}"

  # Pacotes de plugin gerenciados (informativo; atualizam no step pacman/AUR).
  local pkg_plugins
  pkg_plugins="$(pacman -Qq 2>/dev/null | grep -E '^(obs-|ffmpeg-obs)' | grep -v '^obs-studio$' | paste -sd' ' -)"
  [[ -n "$pkg_plugins" ]] && log "  Plugins via pacman/AUR (cobertos pelo update do sistema): ${pkg_plugins}"

  local plugins_dir
  plugins_dir="$(_obs_config_dir)/plugins"
  if [[ ! -d "$plugins_dir" ]]; then
    log "  Sem plugins user-scope em ${plugins_dir}."
    return 0
  fi

  local -a updated=() manual=() failed=()
  local dir plugin behind fetch_err net_fail=0
  for dir in "$plugins_dir"/*/; do
    [[ -d "$dir" ]] || continue
    plugin="$(basename "$dir")"
    # Restos de builds/fontes desabilitados não são plugins ativos.
    [[ "$plugin" == *.disabled* || "$plugin" == *.bak ]] && continue

    if [[ ! -d "$dir/.git" ]]; then
      manual+=("$plugin")
      continue
    fi

    if ! fetch_err="$(git -C "$dir" fetch --quiet --depth=1 origin 2>&1)"; then
      log_raw "$fetch_err"
      log "  Aviso: fetch falhou para plugin OBS ${plugin}"
      printf '%s\n' "$fetch_err" | grep -qiE "$NETWORK_TRANSIENT_RE" && net_fail=1
      failed+=("$plugin")
      continue
    fi

    behind="$(git -C "$dir" rev-list HEAD..origin/HEAD --count 2>/dev/null || echo 0)"
    (( behind == 0 )) && continue

    log "  ${plugin}: ${behind} commit(s) atrás — atualizando..."
    if git -C "$dir" pull --ff-only --quiet origin 2>>"$LOG_FILE"; then
      updated+=("$plugin")
    else
      log "  Aviso: pull falhou para plugin OBS ${plugin} (divergência local?)."
      failed+=("$plugin")
    fi
  done

  (( ${#updated[@]} > 0 )) && log "  Plugins OBS atualizados: ${updated[*]}"
  if (( ${#manual[@]} > 0 )); then
    log "  Plugins OBS instalados na mão (sem git; atualize pelo site do autor/obsproject.com): ${manual[*]}"
  fi
  if (( ${#updated[@]} == 0 && ${#manual[@]} == 0 && ${#failed[@]} == 0 )); then
    log "  Plugins OBS user-scope: nada a atualizar."
  fi

  if (( ${#failed[@]} > 0 )); then
    if (( net_fail )); then
      STEP_REASON="rede indisponível ao buscar plugins OBS (${#failed[@]} afetados)"
      return "$RC_WARN"
    fi
    STEP_REASON="falha ao atualizar plugin(s) OBS: ${failed[*]}"
    return 1
  fi
  return 0
}

# Doctor: saúde dos módulos do OBS.
# Após upgrades (do OBS ou de libs), plugin com ABI antiga falha o load em
# silêncio — só aparece no log da última sessão. Este check lê o log mais
# recente e aponta módulos quebrados antes de você descobrir ao vivo na live.
doctor_obs_modules() {
  local kind
  if ! kind="$(_obs_install_kind)"; then
    log "  OBS Studio não instalado."
    return 0
  fi

  local logs_dir
  logs_dir="$(_obs_config_dir)/logs"
  if [[ ! -d "$logs_dir" ]]; then
    log "  Sem logs do OBS em ${logs_dir} (OBS nunca rodou?)."
    return 0
  fi

  local latest
  latest="$(find "$logs_dir" -maxdepth 1 -name '*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [[ -z "$latest" ]]; then
    log "  Nenhum log de sessão do OBS encontrado."
    return 0
  fi
  log "  Log de sessão analisado: $(basename "$latest")"

  local -a broken=()
  mapfile -t broken < <(
    grep -iE "Failed to load module file|Module '.*' not loaded|os_dlopen.*failed" "$latest" 2>/dev/null \
      | sed -E "s/.*(Failed to load module file|Module ')//i; s/['\"].*//; s/^[[:space:]]+//" \
      | sort -u
  )

  if (( ${#broken[@]} > 0 )); then
    log "  ${C_YELLOW}Módulo(s) OBS falhando o load na última sessão:${C_RESET}"
    local m
    for m in "${broken[@]}"; do
      log "    ${m}"
    done
    remediation "reinstale o plugin (paru -S <pacote>) ou remova o módulo órfão; verifique compatibilidade com o OBS ${kind#* }"
    STEP_REASON="${#broken[@]} módulo(s) OBS falhando o load"
    return "$RC_TODO"
  fi

  # Crashes recentes também merecem atenção (últimos 7 dias).
  local crashes_dir recent_crash=""
  crashes_dir="$(_obs_config_dir)/crashes"
  if [[ -d "$crashes_dir" ]]; then
    recent_crash="$(find "$crashes_dir" -maxdepth 1 -type f -mtime -7 2>/dev/null | head -1)"
  fi
  if [[ -n "$recent_crash" ]]; then
    log "  ${C_YELLOW}Crash do OBS nos últimos 7 dias: $(basename "$recent_crash")${C_RESET}"
    STEP_REASON="crash recente do OBS registrado"
    return "$RC_WARN"
  fi

  log "  Módulos do OBS carregando limpos; sem crash recente."
  return 0
}
