#!/usr/bin/env bash
# lib/steps/preflight.sh — pré-flight obrigatório do run: lock de execução,
# espaço livre em disco e archlinux-keyring. Snapshot pré-upgrade mora em
# backup.sh e mirrors em pacman.sh (Série T4).
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# ── Lockfile: impede instâncias concorrentes do próprio script ──────────────────
# Usa flock num descritor dedicado. O lock é liberado no EXIT (trap em sudo.sh chama
# release_run_lock). Evita corrida de pacman db entre dois `full-upgrade` simultâneos.
FU_LOCK_FILE=""
FU_LOCK_FD=""
FU_LOCK_HELD=0

acquire_run_lock() {
  local lock_dir="${XDG_RUNTIME_DIR:-/tmp}"
  FU_LOCK_FILE="${lock_dir}/full-upgrade.lock"
  # Abre FD 9 no lockfile (RW sem truncar: 9> apagaria o pid da instância
  # dona antes mesmo de tentar o flock) e tenta lock não-bloqueante.
  # ATENÇÃO: o FD precisa viver no shell PAI — este step deve ter timeout=0
  # no catálogo, senão run_step roda em subshell e o lock morre com ele.
  exec 9<>"$FU_LOCK_FILE" 2>/dev/null || {
    log "  Não foi possível abrir lockfile (${FU_LOCK_FILE}); seguindo sem lock."
    return 0
  }
  FU_LOCK_FD=9
  if ! flock -n 9; then
    local holder
    holder="$(cat "$FU_LOCK_FILE" 2>/dev/null || true)"
    holder="${holder//[^0-9]/}"
    log "  Outra instância de full-upgrade já está em execução${holder:+ (pid ${holder})}."
    STEP_REASON="outra instância em execução${holder:+ (pid ${holder})}"
    return "$RC_TODO"
  fi
  FU_LOCK_HELD=1
  # Já com o lock: agora sim pode truncar e gravar o próprio pid.
  printf '%s\n' "$$" >"$FU_LOCK_FILE"
  log "  Lock adquirido: ${FU_LOCK_FILE}"
  return 0
}


release_run_lock() {
  [[ -n "$FU_LOCK_FD" ]] || return 0
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  # Só remove o lockfile se ESTA instância segurava o lock; uma instância que
  # falhou em adquirir não pode apagar o arquivo da dona (uma terceira
  # instância recriaria o path com inode novo e conseguiria o flock).
  if (( FU_LOCK_HELD )) && [[ -n "$FU_LOCK_FILE" ]]; then
    rm -f "$FU_LOCK_FILE" 2>/dev/null || true
  fi
  FU_LOCK_FD=""
  FU_LOCK_HELD=0
}


# ── Pré-flight: espaço em disco ────────────────────────────────────────────────
preflight_disk_space() {
  local status=0 min_gib="${MIN_FREE_GIB:-2}"
  # Threshold por mount: / usa MIN_FREE_GIB; /boot (ESP) é pequeno, usa MIN_BOOT_FREE_MIB.
  local min_boot_mib="${MIN_BOOT_FREE_MIB:-200}"
  local mp avail_mib thresh_mib
  for mp in / /boot; do
    [[ -d "$mp" ]] || continue
    findmnt -no TARGET "$mp" >/dev/null 2>&1 || continue
    avail_mib="$(df -BM --output=avail "$mp" 2>/dev/null | awk 'NR==2{gsub(/M/,"");print $1}')"
    [[ -n "$avail_mib" ]] || continue
    if [[ "$mp" == "/boot" ]]; then
      thresh_mib="$min_boot_mib"
    else
      thresh_mib=$(( min_gib * 1024 ))
    fi
    if (( avail_mib < thresh_mib )); then
      log "  ${C_RED}Espaço baixo em ${mp}: $(fmt_mib "$avail_mib") livre (< $(fmt_mib "$thresh_mib")).${C_RESET}"
      status="$RC_WARN"
    else
      log "  ${mp}: $(fmt_mib "$avail_mib") livre (OK)."
    fi
  done

  return "$status"
}


update_archlinux_keyring() {
  if ! has pacman; then
    log "  pacman ausente; archlinux-keyring pulado."
    return 0
  fi
  if (( ! SUDO_READY )); then
    log "  archlinux-keyring: pulado (sudo indisponível)."
    return 0
  fi

  # archlinux-keyring antes do upgrade grande (evita falhas de assinatura).
  log "  Atualizando archlinux-keyring..."
  if run_logged sudo pacman -Sy --needed --noconfirm archlinux-keyring; then
    log "  archlinux-keyring atualizado."
    return 0
  fi

  # Fallback: pacman -Sy é atômico — se um repo terceiro (warpdotdev, etc.)
  # estiver lento/indisponível, o rc≠0 descarta TODO o sync mesmo que core/extra
  # já tenham sido baixados com sucesso. Tentar sem -y reusa o DB local que
  # acabou de ser parcialmente atualizado; --needed pula se já está na versão
  # mais recente. Não atrapalha: o -Syu do step principal sincroniza depois.
  log "  Sync do DB falhou (repo terceiro lento/indisponível?); tentando via DB em cache..."
  if run_logged sudo pacman -S --needed --noconfirm archlinux-keyring; then
    log "  archlinux-keyring OK (via DB em cache)."
    return 0
  fi

  log "  Aviso: falha ao atualizar archlinux-keyring (seguindo)."
  return "$RC_WARN"
}
