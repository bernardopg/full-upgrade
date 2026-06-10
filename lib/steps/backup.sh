#!/usr/bin/env bash
# lib/steps/backup.sh — backup de configs críticas antes das mutações (F1).
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Diretório de backups (paralelo aos logs, no cache do usuário).
backup_dir() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/system-upgrade/backups"
}

# Rotação pura: dado um diretório e quantos manter, emite (stdout) os caminhos
# de tarballs full-upgrade EXCEDENTES (mais antigos) que devem ser removidos.
# Ordena por nome (timestamp no nome garante ordem cronológica). Sem I/O de
# remoção aqui — testável. Vazio = nada a remover.
backup_rotation_victims() {
  local dir="$1" keep="$2"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  [[ -d "$dir" ]] || return 0
  local -a all=()
  mapfile -t all < <(find "$dir" -maxdepth 1 -type f -name 'configs-*.tar.*' 2>/dev/null | sort)
  local n="${#all[@]}"
  (( n > keep )) || return 0
  local cut=$(( n - keep ))
  printf '%s\n' "${all[@]:0:cut}"
}

# Seleciona, da lista de paths candidatos, apenas os que existem no disco.
# Lê paths separados por espaço de $1; emite um por linha os existentes.
backup_existing_paths() {
  local p
  for p in $1; do
    [[ -n "$p" ]] || continue
    [[ -e "$p" ]] && printf '%s\n' "$p"
  done
}

backup_critical_configs() {
  if [[ "${BACKUP_CONFIGS:-1}" != "1" ]]; then
    log "  Backup de configs desabilitado (BACKUP_CONFIGS=0)."
    return 0
  fi

  if ! has tar; then
    log "  tar não encontrado; backup de configs pulado."
    return 0
  fi

  # Resolve quais paths configurados existem de fato.
  local -a paths=()
  mapfile -t paths < <(backup_existing_paths "${BACKUP_PATHS:-}")
  if (( ${#paths[@]} == 0 )); then
    log "  Nenhum dos paths de backup existe; nada a arquivar."
    return 0
  fi

  local dir; dir="$(backup_dir)"
  # Escolhe compressor disponível (zstd preferido; gzip como fallback portável).
  local ext comp
  if has zstd; then ext="tar.zst"; comp="--zstd"
  else ext="tar.gz"; comp="--gzip"; fi

  local stamp archive
  stamp="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
  archive="${dir}/configs-${stamp}.${ext}"

  if (( DRY_RUN )); then
    log "  [dry-run] arquivaria ${#paths[@]} path(s) em ${archive}:"
    local p
    for p in "${paths[@]}"; do log "    ${p}"; done
    return 0
  fi

  mkdir -p "$dir" 2>/dev/null || {
    log "  Aviso: não foi possível criar ${dir}; backup pulado."
    return "$RC_WARN"
  }

  log "  Arquivando ${#paths[@]} path(s) de config em ${archive}..."
  # sudo: muitos paths em /etc/systemd/system etc. são lidos por root sem
  # problema, mas arquivos com modo restrito exigem privilégio. Usa sudo se
  # pronto; senão tenta sem (paths de /etc costumam ser legíveis por todos).
  local -a tar_cmd=(tar "$comp" -cpf "$archive" --ignore-failed-read --warning=no-file-changed)
  local rc
  if (( SUDO_READY )) && has sudo; then
    run_logged sudo "${tar_cmd[@]}" -- "${paths[@]}"
    rc=$?
    # Backup criado como root: devolve a posse ao usuário p/ leitura/restauração.
    [[ -f "$archive" ]] && run_logged sudo chown "$(id -u):$(id -g)" "$archive" 2>/dev/null || true
  else
    run_logged "${tar_cmd[@]}" -- "${paths[@]}"
    rc=$?
  fi

  # tar com --ignore-failed-read retorna 0 mesmo pulando arquivo ilegível; rc≠0
  # aqui é falha real (disco cheio, path inválido). Não fatal: vira aviso.
  if (( rc != 0 )) || [[ ! -s "$archive" ]]; then
    log "  ${C_YELLOW}Aviso: backup de configs incompleto ou vazio (rc=${rc}).${C_RESET}"
    return "$RC_WARN"
  fi

  local size
  size="$(du -h "$archive" 2>/dev/null | awk '{print $1}')"
  log "  Backup de configs criado: ${archive} (${size:-?})"

  # Rotação: mantém só os BACKUP_KEEP mais recentes.
  local -a victims=()
  mapfile -t victims < <(backup_rotation_victims "$dir" "${BACKUP_KEEP:-5}")
  if (( ${#victims[@]} > 0 )); then
    log "  Rotação: removendo ${#victims[@]} backup(s) antigo(s) (mantendo ${BACKUP_KEEP:-5})."
    local v
    for v in "${victims[@]}"; do
      rm -f -- "$v" 2>/dev/null || true
    done
  fi

  return 0
}
