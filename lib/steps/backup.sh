#!/usr/bin/env bash
# lib/steps/backup.sh — backup de configs críticas antes das mutações (F1).
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Diretório de backups (paralelo aos logs, no cache do usuário).
backup_dir() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/system-upgrade/backups"
}

# Normaliza a retenção. BACKUP_CONFIGS=0 é a forma explícita de desligar o
# backup; quando ele está ativo, manter ao menos um arquivo evita criar e apagar
# imediatamente o único backup por causa de BACKUP_KEEP=0/valor inválido.
backup_keep_count() {
  local keep="${1:-}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  (( keep < 1 )) && keep=1
  printf '%s' "$keep"
}

# Rotação pura: dado um diretório e quantos manter, emite (stdout) os caminhos
# de tarballs full-upgrade EXCEDENTES (mais antigos) que devem ser removidos.
# Ordena por nome (timestamp no nome garante ordem cronológica). Sem I/O de
# remoção aqui — testável. Vazio = nada a remover.
backup_rotation_victims() {
  local dir="$1" keep="$2"
  keep=$(backup_keep_count "$keep")
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

  local dir keep
  dir="$(backup_dir)"
  keep=$(backup_keep_count "${BACKUP_KEEP:-5}")
  # Escolhe compressor disponível (zstd preferido; gzip como fallback portável).
  local ext comp
  if has zstd; then ext="tar.zst"; comp="--zstd"
  else ext="tar.gz"; comp="--gzip"; fi

  local stamp archive partial
  stamp="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
  archive="${dir}/configs-${stamp}.${ext}"
  partial="${dir}/.configs-${stamp}.${ext}.partial.$$"

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
  chmod 700 "$dir" 2>/dev/null || true
  # Corrige permissões de versões antigas: os tarballs podem conter configs e
  # segredos que não devem ficar legíveis por outros usuários locais.
  find "$dir" -maxdepth 1 -type f -name 'configs-*.tar.*' -exec chmod 600 {} + 2>/dev/null || true

  # Se uma versão antiga já deixou o diretório acima da retenção, saneia antes
  # do novo tar. Assim uma falha posterior de tar não perpetua crescimento.
  local -a victims=()
  mapfile -t victims < <(backup_rotation_victims "$dir" "$keep")
  local v rotation_failed=0
  for v in "${victims[@]}"; do
    rm -f -- "$v" 2>/dev/null || rotation_failed=1
  done

  log "  Arquivando ${#paths[@]} path(s) de config em ${archive}..."
  # sudo: muitos paths em /etc/systemd/system etc. são lidos por root sem
  # problema, mas arquivos com modo restrito exigem privilégio. Usa sudo se
  # pronto; senão tenta sem (paths de /etc costumam ser legíveis por todos).
  # --warning=no-file-ignored silencia avisos de sockets/FIFOs que o tar não
  # arquiva por natureza (ex.: /etc/pacman.d/gnupg/S.* do gpg-agent/dirmngr);
  # não muda o que é arquivado, só remove ruído inofensivo do log.
  local -a relative_paths=()
  local p
  for p in "${paths[@]}"; do relative_paths+=("${p#/}"); done
  local -a tar_cmd=(tar "$comp" -C / -cpf "$partial" --ignore-failed-read --warning=no-file-changed --warning=no-file-ignored)
  local rc
  if (( SUDO_READY )) && has sudo; then
    run_logged sudo "${tar_cmd[@]}" -- "${relative_paths[@]}"
    rc=$?
    # Arquivo temporário criado como root: devolve a posse antes de validar e
    # publicar atomicamente com rename no mesmo filesystem.
    [[ -f "$partial" ]] && run_logged sudo chown "$(id -u):$(id -g)" "$partial" 2>/dev/null || true
  else
    run_logged "${tar_cmd[@]}" -- "${relative_paths[@]}"
    rc=$?
  fi

  # tar com --ignore-failed-read retorna 0 mesmo pulando arquivo ilegível; rc≠0
  # aqui é falha real (disco cheio, path inválido). Não fatal: vira aviso.
  if (( rc != 0 )) || [[ ! -s "$partial" ]] || ! tar "$comp" -tf "$partial" >/dev/null 2>&1; then
    rm -f -- "$partial" 2>/dev/null || true
    log "  ${C_YELLOW}Aviso: backup de configs incompleto ou vazio (rc=${rc}).${C_RESET}"
    return "$RC_WARN"
  fi

  chmod 600 "$partial" 2>/dev/null || true
  if ! mv -f -- "$partial" "$archive"; then
    rm -f -- "$partial" 2>/dev/null || true
    log "  ${C_YELLOW}Aviso: não foi possível publicar o backup ${archive}.${C_RESET}"
    return "$RC_WARN"
  fi

  local size
  size="$(du -h "$archive" 2>/dev/null | awk '{print $1}')"
  log "  Backup de configs criado: ${archive} (${size:-?})"

  # Rotação pós-publicação: o novo arquivo entra na contagem e os N mais
  # recentes permanecem. Falha de remoção é visível em vez de ser silenciada.
  victims=()
  mapfile -t victims < <(backup_rotation_victims "$dir" "$keep")
  if (( ${#victims[@]} > 0 )); then
    log "  Rotação: removendo ${#victims[@]} backup(s) antigo(s) (mantendo ${keep})."
    for v in "${victims[@]}"; do
      if ! rm -f -- "$v" 2>/dev/null; then
        rotation_failed=1
        log "  Aviso: não foi possível remover backup antigo: ${v}"
      fi
    done
  fi

  (( rotation_failed == 0 )) || return "$RC_WARN"
  return 0
}
