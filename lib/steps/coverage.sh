#!/usr/bin/env bash
# lib/steps/coverage.sh — coberturas extra: lockfile, snapshot, mirrors, pré-flight.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

# ── Lockfile: impede instâncias concorrentes do próprio script ──────────────────
# Usa flock num descritor dedicado. O lock é liberado no EXIT (trap em sudo.sh chama
# release_run_lock). Evita corrida de pacman db entre dois `full-upgrade` simultâneos.
FU_LOCK_FILE=""
FU_LOCK_FD=""

acquire_run_lock() {
  local lock_dir="${XDG_RUNTIME_DIR:-/tmp}"
  FU_LOCK_FILE="${lock_dir}/full-upgrade.lock"
  # Abre FD 9 no lockfile e tenta lock não-bloqueante.
  exec 9>"$FU_LOCK_FILE" 2>/dev/null || {
    log "  Não foi possível abrir lockfile (${FU_LOCK_FILE}); seguindo sem lock."
    return 0
  }
  FU_LOCK_FD=9
  if ! flock -n 9; then
    local holder
    holder="$(cat "$FU_LOCK_FILE" 2>/dev/null || true)"
    log "  Outra instância de full-upgrade já está em execução${holder:+ (pid ${holder})}."
    return "$RC_TODO"
  fi
  printf '%s\n' "$$" >&9
  log "  Lock adquirido: ${FU_LOCK_FILE}"
  return 0
}

release_run_lock() {
  [[ -n "$FU_LOCK_FD" ]] || return 0
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  [[ -n "$FU_LOCK_FILE" ]] && rm -f "$FU_LOCK_FILE" 2>/dev/null || true
  FU_LOCK_FD=""
}

# ── Pré-flight: espaço em disco + keyring ───────────────────────────────────────
preflight_disk_and_keyring() {
  local status=0 min_gib="${MIN_FREE_GIB:-2}"
  local mp avail_gib
  for mp in / /boot; do
    [[ -d "$mp" ]] || continue
    findmnt -no TARGET "$mp" >/dev/null 2>&1 || continue
    avail_gib="$(df -BG --output=avail "$mp" 2>/dev/null | awk 'NR==2{gsub(/G/,"");print $1}')"
    [[ -n "$avail_gib" ]] || continue
    if (( avail_gib < min_gib )); then
      log "  ${C_RED}Espaço baixo em ${mp}: ${avail_gib}GiB livre (< ${min_gib}GiB).${C_RESET}"
      status="$RC_WARN"
    else
      log "  ${mp}: ${avail_gib}GiB livre (OK)."
    fi
  done

  # archlinux-keyring antes do upgrade grande (evita falhas de assinatura).
  if has pacman && (( SUDO_READY )); then
    log "  Atualizando archlinux-keyring..."
    if run_logged sudo pacman -Sy --needed --noconfirm archlinux-keyring; then
      log "  archlinux-keyring atualizado."
    else
      log "  Aviso: falha ao atualizar archlinux-keyring (seguindo)."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  archlinux-keyring: pulado (sem pacman ou sudo)."
  fi
  return "$status"
}

# ── Snapshot pré-upgrade (btrfs via snapper/timeshift) ──────────────────────────
preupgrade_snapshot() {
  local tool="${SNAPSHOT_TOOL:-auto}"
  [[ "$tool" == "none" ]] && { log "  Snapshot desabilitado (SNAPSHOT_TOOL=none)."; return 0; }

  # Só faz sentido em btrfs no /.
  local rootfs
  rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  if [[ "$rootfs" != "btrfs" ]]; then
    log "  Raiz não é btrfs (${rootfs:-?}); snapshot pulado."
    return 0
  fi

  # Auto-detecta ferramenta.
  if [[ "$tool" == "auto" ]]; then
    if has snapper; then tool="snapper"
    elif has timeshift; then tool="timeshift"
    else log "  Nenhuma ferramenta de snapshot (snapper/timeshift) instalada; pulando."; return 0; fi
  fi

  local desc
  desc="full-upgrade pré-upgrade $(date '+%Y-%m-%d %H:%M')"
  case "$tool" in
    snapper)
      has snapper || { log "  snapper não instalado."; return 0; }
      if run_logged sudo snapper -c root create -d "$desc"; then
        log "  Snapshot snapper criado: ${desc}"
      else
        log "  Aviso: falha ao criar snapshot snapper."; return "$RC_WARN"
      fi
      ;;
    timeshift)
      has timeshift || { log "  timeshift não instalado."; return 0; }
      if run_logged sudo timeshift --create --comments "$desc" --scripted; then
        log "  Snapshot timeshift criado: ${desc}"
      else
        log "  Aviso: falha ao criar snapshot timeshift."; return "$RC_WARN"
      fi
      ;;
    *)
      log "  SNAPSHOT_TOOL inválido: ${tool}"; return "$RC_WARN" ;;
  esac
  return 0
}

# ── Mirror refresh (reflector / rate-mirrors) ───────────────────────────────────
refresh_mirrors() {
  local tool="${MIRROR_TOOL:-auto}"
  [[ "$tool" == "none" ]] && { log "  Mirror refresh desabilitado (MIRROR_TOOL=none)."; return 0; }
  has pacman || { log "  pacman ausente; mirror refresh pulado."; return 0; }

  if [[ "$tool" == "auto" ]]; then
    if has reflector; then tool="reflector"
    elif has rate-mirrors; then tool="rate-mirrors"
    else log "  Nenhuma ferramenta de mirror (reflector/rate-mirrors); pulando."; return 0; fi
  fi

  local mirrorlist="/etc/pacman.d/mirrorlist"
  local backup="${mirrorlist}.full-upgrade.bak"

  case "$tool" in
    reflector)
      has reflector || { log "  reflector não instalado."; return 0; }
      run_logged sudo cp -f "$mirrorlist" "$backup" 2>/dev/null || true
      log "  Backup do mirrorlist: ${backup}"
      if run_logged sudo reflector --latest 20 --protocol https --sort rate --save "$mirrorlist"; then
        log "  Mirrors atualizados via reflector (top 20 por rate)."
      else
        log "  Aviso: reflector falhou; restaurando backup."
        run_logged sudo cp -f "$backup" "$mirrorlist" 2>/dev/null || true
        return "$RC_WARN"
      fi
      ;;
    rate-mirrors)
      has rate-mirrors || { log "  rate-mirrors não instalado."; return 0; }
      run_logged sudo cp -f "$mirrorlist" "$backup" 2>/dev/null || true
      log "  Backup do mirrorlist: ${backup}"
      if rate-mirrors --save "$mirrorlist" arch 2>>"$LOG_FILE"; then
        log "  Mirrors atualizados via rate-mirrors."
      else
        log "  Aviso: rate-mirrors falhou; restaurando backup."
        run_logged sudo cp -f "$backup" "$mirrorlist" 2>/dev/null || true
        return "$RC_WARN"
      fi
      ;;
    *)
      log "  MIRROR_TOOL inválido: ${tool}"; return "$RC_WARN" ;;
  esac
  return 0
}
