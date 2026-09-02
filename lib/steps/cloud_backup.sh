#!/usr/bin/env bash
# lib/steps/cloud_backup.sh — réplica off-site criptografada de snapshots Timeshift.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module

# Retenção remota. Valores inválidos voltam ao padrão conservador de 3 versões.
timeshift_cloud_keep_count() {
  local keep="${TIMESHIFT_CLOUD_KEEP:-3}"
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || keep=3
  printf '%s' "$keep"
}

# Dado o mount do top-level Btrfs (subvolid=5), retorna o snapshot Timeshift mais
# recente. Os nomes ISO usados pelo Timeshift ordenam cronologicamente.
timeshift_cloud_latest_name() {
  local top="$1" snapshots="${1}/timeshift-btrfs/snapshots"
  [[ -d "$snapshots" ]] || return 1

  local -a names=()
  mapfile -t names < <(find "$snapshots" -mindepth 1 -maxdepth 1 -type d \
    -name '????-??-??_??-??-??' -printf '%f\n' 2>/dev/null | sort)
  (( ${#names[@]} > 0 )) || return 1
  printf '%s' "${names[-1]}"
}

_timeshift_cloud_restic() {
  sudo -n env \
    HOME="$HOME" \
    RCLONE_CONFIG="$TIMESHIFT_CLOUD_RCLONE_CONFIG" \
    RESTIC_PASSWORD_FILE="$TIMESHIFT_CLOUD_PASSWORD_FILE" \
    restic --repo "$TIMESHIFT_CLOUD_REPOSITORY" "$@"
}

backup_timeshift_cloud() {
  if [[ "${TIMESHIFT_CLOUD_BACKUP:-0}" != "1" ]]; then
    log "  Backup Timeshift em nuvem desabilitado (TIMESHIFT_CLOUD_BACKUP=0)."
    return 0
  fi

  local missing=""
  has restic || missing="restic"
  has rclone || missing="${missing:+${missing}, }rclone"
  has timeshift || missing="${missing:+${missing}, }timeshift"
  if [[ -n "$missing" ]]; then
    STEP_REASON="dependências ausentes: ${missing}"
    log "  Backup Timeshift em nuvem requer: ${missing}."
    return "$RC_TODO"
  fi

  if [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" != "btrfs" ]]; then
    STEP_REASON="raiz não usa Btrfs"
    log "  Backup Timeshift em nuvem requer raiz Btrfs."
    return "$RC_TODO"
  fi

  local repository="${TIMESHIFT_CLOUD_REPOSITORY:-}"
  local password_file="${TIMESHIFT_CLOUD_PASSWORD_FILE:-}"
  local rclone_config="${TIMESHIFT_CLOUD_RCLONE_CONFIG:-}"
  if [[ -z "$repository" || -z "$password_file" || -z "$rclone_config" ]]; then
    STEP_REASON="configuração da nuvem incompleta"
    log "  Configure TIMESHIFT_CLOUD_REPOSITORY, TIMESHIFT_CLOUD_PASSWORD_FILE e TIMESHIFT_CLOUD_RCLONE_CONFIG."
    return "$RC_TODO"
  fi
  # O rclone roda sob sudo neste step e reescreve o rclone.conf ao renovar o
  # token do remote, deixando o arquivo root-owned. O chown de volta no fim da
  # execução não bastava: se o run anterior foi interrompido depois da
  # reescrita e antes do chown, a guarda abaixo passava a barrar o step com
  # "credenciais ausentes" ANTES de chegar ao conserto — e como só este step
  # conserta, o backup ficava travado para sempre. Repara aqui, na entrada.
  if [[ -e "$rclone_config" && ! -r "$rclone_config" ]]; then
    log "  ${rclone_config} ilegível pelo usuário; tentando devolver a posse..."
    sudo -n chown "$(id -u):$(id -g)" "$rclone_config" 2>/dev/null || true
  fi

  if [[ ! -s "$password_file" || ! -r "$rclone_config" ]]; then
    STEP_REASON="credenciais Restic/rclone ausentes"
    log "  Password file do Restic ou configuração do rclone ausente/ilegível."
    return "$RC_TODO"
  fi

  local source mount_dir="/run/full-upgrade-timeshift-cloud" mounted=0
  source="$(findmnt -no SOURCE / 2>/dev/null || true)"
  source="${source%%\[*}"
  if [[ -z "$source" || ! -b "$source" ]]; then
    STEP_REASON="dispositivo Btrfs da raiz não identificado"
    log "  Não foi possível identificar o dispositivo Btrfs de /."
    return "$RC_WARN"
  fi

  # O lock global do full-upgrade impede concorrência. Ainda assim, limpa um
  # mount órfão deixado por interrupção abrupta antes de montar novamente.
  if mountpoint -q "$mount_dir" 2>/dev/null; then
    sudo -n umount "$mount_dir" >/dev/null 2>&1 || {
      STEP_REASON="mount temporário anterior ainda está ocupado"
      return "$RC_WARN"
    }
  fi
  sudo -n mkdir -p "$mount_dir" || {
    STEP_REASON="não foi possível criar mount temporário"
    return "$RC_WARN"
  }
  if ! sudo -n mount -o ro,subvolid=5 -- "$source" "$mount_dir"; then
    sudo -n rmdir "$mount_dir" 2>/dev/null || true
    STEP_REASON="falha ao montar top-level Btrfs"
    return "$RC_WARN"
  fi
  mounted=1

  local snapshot snapshot_dir rc=0 keep
  snapshot="$(timeshift_cloud_latest_name "$mount_dir" || true)"
  snapshot_dir="${mount_dir}/timeshift-btrfs/snapshots/${snapshot}"
  if [[ -z "$snapshot" || ! -d "${snapshot_dir}/@" ]]; then
    STEP_REASON="nenhum snapshot Timeshift válido encontrado"
    log "  Nenhum snapshot Timeshift válido foi encontrado para envio."
    rc="$RC_TODO"
  elif [[ ! -d "${snapshot_dir}/@home" ]]; then
    STEP_REASON="snapshot ${snapshot} não inclui @home"
    log "  Snapshot ${snapshot} não contém @home; envio recusado para não produzir backup pessoal incompleto."
    rc="$RC_TODO"
  else
    log "  Enviando snapshot Timeshift ${snapshot} (@ + @home) ao repositório criptografado..."
    local -a backup_args=(
      backup --tag full-upgrade-timeshift --tag "$snapshot"
    )
    if [[ -n "${TIMESHIFT_CLOUD_EXCLUDE_FILE:-}" && -r "$TIMESHIFT_CLOUD_EXCLUDE_FILE" ]]; then
      backup_args+=(--exclude-file "$TIMESHIFT_CLOUD_EXCLUDE_FILE")
      log "  Exclusões de caches/artefatos: ${TIMESHIFT_CLOUD_EXCLUDE_FILE}"
    fi
    backup_args+=("${snapshot_dir}/@" "${snapshot_dir}/@home")
    if _timeshift_cloud_restic "${backup_args[@]}"; then
      log "  Snapshot ${snapshot} armazenado no OneDrive via Restic."
    else
      STEP_REASON="falha no upload Restic do snapshot ${snapshot}"
      rc="$RC_WARN"
    fi
  fi

  if (( mounted )); then
    sudo -n umount "$mount_dir" >/dev/null 2>&1 || {
      log "  Aviso: não foi possível desmontar ${mount_dir}."
      (( rc == 0 )) && rc="$RC_WARN"
    }
  fi
  sudo -n rmdir "$mount_dir" 2>/dev/null || true

  # O rclone roda como root via sudo e reescreve o rclone.conf ao renovar o
  # token do remote (dono vira root). Devolve a posse ao usuário para não
  # quebrar os próximos runs do rclone fora do full-upgrade.
  sudo -n chown "$(id -u):$(id -g)" "$rclone_config" 2>/dev/null || true

  if (( rc == 0 )); then
    keep="$(timeshift_cloud_keep_count)"
    log "  Aplicando retenção remota: manter as ${keep} versões mais recentes."
    if ! _timeshift_cloud_restic forget \
      --tag full-upgrade-timeshift --keep-last "$keep" --prune; then
      STEP_REASON="backup enviado, mas retenção remota falhou"
      rc="$RC_WARN"
    fi
  fi

  return "$rc"
}
