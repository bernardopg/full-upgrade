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


# ── Snapshot pré-upgrade (btrfs via snapper/timeshift) ──────────────────────────
# Timeshift pode avisar sobre rotação mesmo depois de criar o snapshot com sucesso.
# A saída crua fica no log; este filtro só reduz ruído no terminal.
timeshift_terminal_output() {
  sed '/^Maximum backups exceeded for backup level /d'
}


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
      # \r → \n: progresso do timeshift ("12%... 32%... 43%...") acumula numa linha
      # só no log; convertendo dá uma linha por atualização (legível em auditoria).
      log_raw "$(printf '%s' "$timeshift_output" | tr '\r' '\n')"
      if (( timeshift_rc == 0 )); then
        timeshift_result="$(printf '%s\n' "$timeshift_output" | tr '\r' '\n' | grep -E 'Snapshot saved successfully' | tail -1 || true)"
        [[ -n "$timeshift_result" ]] && log "  ${timeshift_result}"
        log "  Snapshot timeshift criado: ${desc}"
      else
        printf '%s\n' "$timeshift_output" | tr '\r' '\n' | timeshift_terminal_output | tail -20 | log_out
        log "  Aviso: falha ao criar snapshot timeshift."; return "$RC_WARN"
      fi
      ;;
    *)
      log "  SNAPSHOT_TOOL inválido: ${tool}"; return "$RC_WARN" ;;
  esac
  return 0
}
