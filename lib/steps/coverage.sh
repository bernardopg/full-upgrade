#!/usr/bin/env bash
# lib/steps/coverage.sh — coberturas extra: lockfile, snapshot, mirrors, pré-flight.
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
      log "  ${C_RED}Espaço baixo em ${mp}: $(( avail_mib / 1024 ))GiB (${avail_mib}MiB) livre (< $(( thresh_mib / 1024 ))GiB).${C_RESET}"
      status="$RC_WARN"
    else
      log "  ${mp}: $(( avail_mib / 1024 ))GiB (${avail_mib}MiB) livre (OK)."
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

  log "  Aviso: falha ao atualizar archlinux-keyring (seguindo)."
  return "$RC_WARN"
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

  # Pré-flight de espaço: um snapshot CoW começa barato, mas a divergência
  # subsequente pode encher o subvolume. Se o livre estiver abaixo do limiar,
  # avisa e NÃO cria (snapshot que estoura o disco é pior que não ter). 0 = off.
  local min_free="${SNAPSHOT_MIN_FREE_GIB:-2}"
  if [[ "$min_free" =~ ^[0-9]+$ ]] && (( min_free > 0 )); then
    local avail_kib
    avail_kib="$(avail_kib_for_path /)"
    if [[ -n "$avail_kib" ]] && ! space_is_sufficient "$avail_kib" "$min_free"; then
      local avail_gib=$(( avail_kib / 1048576 ))
      log "  ${C_YELLOW}Espaço livre em / (${avail_gib} GiB) abaixo do mínimo p/ snapshot (${min_free} GiB).${C_RESET}"
      log "  Pulando snapshot para não arriscar encher o subvolume."
      log "  Remediação: libere espaço (paccache -r, limpe snapshots antigos) ou ajuste SNAPSHOT_MIN_FREE_GIB."
      STEP_REASON="espaço livre (${avail_gib} GiB) < mínimo p/ snapshot (${min_free} GiB)"
      return "$RC_WARN"
    fi
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
      local timeshift_output timeshift_rc timeshift_result
      log "  Criando snapshot Timeshift (a saída detalhada ficará no log)..."
      timeshift_output="$(sudo timeshift --create --comments "$desc" --scripted 2>&1)"
      timeshift_rc=$?
      log_raw "$timeshift_output"
      if (( timeshift_rc == 0 )); then
        timeshift_result="$(printf '%s\n' "$timeshift_output" | tr '\r' '\n' | grep -E 'Snapshot saved successfully' | tail -1 || true)"
        [[ -n "$timeshift_result" ]] && log "  ${timeshift_result}"
        log "  Snapshot timeshift criado: ${desc}"
      else
        printf '%s\n' "$timeshift_output" | tr '\r' '\n' | tail -20
        log "  Aviso: falha ao criar snapshot timeshift."; return "$RC_WARN"
      fi
      ;;
    *)
      log "  SNAPSHOT_TOOL inválido: ${tool}"; return "$RC_WARN" ;;
  esac
  return 0
}

# Mirrorlist válido precisa ter ao menos uma linha Server ativa. Comentários não contam.
mirrorlist_has_server() {
  local file="$1"
  [[ -r "$file" ]] || return 1
  grep -Eq '^[[:space:]]*Server[[:space:]]*=' "$file"
}

_restore_mirror_backup() {
  local backup="$1" mirrorlist="$2"
  if mirrorlist_has_server "$backup"; then
    run_logged sudo cp -f "$backup" "$mirrorlist" 2>/dev/null || true
  else
    log "  Aviso: backup do mirrorlist inválido/vazio; não restaurado: ${backup}"
    log "  Remediação: revise ${mirrorlist} ou regenere mirrors manualmente."
  fi
}

# ── Mirror refresh (reflector / rate-mirrors) ───────────────────────────────────
# Verdadeiro se o mirrorlist é "fresco" (atualizado há menos de max_days dias).
# Puro/testável. Uso: mirror_is_fresh <mtime_epoch> <now_epoch> <max_days>.
mirror_is_fresh() {
  local mtime="$1" now="$2" max_days="$3"
  [[ "$mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$max_days" =~ ^[0-9]+$ ]] || return 1
  (( mtime > 0 && max_days > 0 )) || return 1
  (( now - mtime < max_days * 86400 ))
}

refresh_mirrors() {
  local tool="${MIRROR_TOOL:-auto}"
  [[ "$tool" == "none" ]] && { log "  Mirror refresh desabilitado (MIRROR_TOOL=none)."; return 0; }
  has pacman || { log "  pacman ausente; mirror refresh pulado."; return 0; }

  local mirrorlist="/etc/pacman.d/mirrorlist"
  local backup="${mirrorlist}.full-upgrade.bak"

  # Freshness gate: rate-test de mirrors é caro (reflector baixa a .db de cada
  # candidato). Mirrors mudam devagar, então pulamos o refresh quando o
  # mirrorlist já foi atualizado há menos de MIRROR_MAX_AGE_DAYS dias — a maioria
  # dos runs nem toca nesta etapa. MIRROR_MAX_AGE_DAYS=0 força sempre rotear.
  local max_age="${MIRROR_MAX_AGE_DAYS:-7}"
  if [[ "$max_age" =~ ^[0-9]+$ ]] && (( max_age > 0 )) && [[ -r "$mirrorlist" ]]; then
    local mtime now
    mtime="$(stat -c %Y "$mirrorlist" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if mirror_is_fresh "$mtime" "$now" "$max_age"; then
      log "  Mirrorlist atualizado há $(( (now - mtime) / 86400 ))d (< ${max_age}d) — pulando refresh (MIRROR_MAX_AGE_DAYS=${max_age})."
      return 0
    fi
  fi

  if [[ "$tool" == "auto" ]]; then
    if has rate-mirrors; then tool="rate-mirrors"   # mais rápido (Rust, paralelo)
    elif has reflector; then tool="reflector"
    else log "  Nenhuma ferramenta de mirror (reflector/rate-mirrors); pulando."; return 0; fi
  fi

  case "$tool" in
    reflector)
      has reflector || { log "  reflector não instalado."; return 0; }
      run_logged sudo cp -f "$mirrorlist" "$backup" 2>/dev/null || true
      log "  Backup do mirrorlist: ${backup}"
      # Flags rápidas: --age 24 descarta mirrors não-sincronizados há >24h (menos
      # candidatos mortos), timeouts curtos (3s) cortam a penalidade de mirror
      # lento (default é 5s), e --number 10 devolve só os 10 mais rápidos.
      if run_logged sudo reflector --protocol https --age 24 --latest 20 --sort rate \
           --connection-timeout 3 --download-timeout 3 --number 10 --save "$mirrorlist"; then
        log "  Mirrors atualizados via reflector (top 10 por rate)."
      else
        log "  Aviso: reflector falhou; restaurando backup válido se possível."
        _restore_mirror_backup "$backup" "$mirrorlist"
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
        log "  Aviso: rate-mirrors falhou; restaurando backup válido se possível."
        _restore_mirror_backup "$backup" "$mirrorlist"
        return "$RC_WARN"
      fi
      ;;
    *)
      log "  MIRROR_TOOL inválido: ${tool}"; return "$RC_WARN" ;;
  esac
  return 0
}
