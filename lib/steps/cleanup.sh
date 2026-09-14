#!/usr/bin/env bash
# lib/steps/cleanup.sh — limpeza: caches, snapshots, órfãos, journal, coredumps e relatórios.
# Série T3: verificações finais migraram para final_checks.sh; limpezas do pacman
# (paccache/órfãos) vieram de pacman.sh.
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



# Tamanho (MiB) só dos arquivos que a rotação gerencia — os do primeiro nível
# de LOG_DIR. Um `du -sm "$LOG_DIR"` somaria backups/ e burpsuite/, que a
# rotação não toca: com ~2GB de backups o relatório saía "1996MB → 1996MB"
# depois de remover arquivos de verdade.
_logdir_files_mib() {
  find "$LOG_DIR" -maxdepth 1 -type f -printf '%s\n' 2>/dev/null \
    | awk '{ s += $1 } END { printf "%.1f", s / 1048576 }'
}


# Remove de ~/.cache/system-upgrade os artefatos dos runs além dos MAX_LOGS mais
# recentes. rotate_logs (lib/json.sh) já faz isso a cada start via
# setup_logging — este step existe pra dar visibilidade no resumo/relatório e
# servir de rede de segurança caso algo escape à rotação automática (ex.:
# LOG_DIR trocado em runtime).
cleanup_old_reports() {
  [[ -d "$LOG_DIR" ]] || { log "  ${LOG_DIR} não existe; nada a limpar."; return 0; }

  local before after removed=0 antes_de depois_de
  before="$(_logdir_files_mib)"
  antes_de="$(find "$LOG_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)"

  # Mesma regra do rotate_logs (lib/json.sh): agrupa por RUN_ID em vez de por
  # extensão, para não repetir aqui a lista que já vazou duas vezes lá.
  rotate_logs

  depois_de="$(find "$LOG_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  removed=$(( antes_de - depois_de ))
  (( removed < 0 )) && removed=0

  if (( removed == 0 )); then
    log "  ${LOG_DIR}: artefatos dentro do limite de ${MAX_LOGS} run(s); nada a remover."
    return 0
  fi

  after="$(_logdir_files_mib)"
  log "  Removidos ${removed} arquivo(s) de run(s) além dos ${MAX_LOGS} mais recentes: ${before}MB → ${after}MB."
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



# Lista arquivos de coredump mais antigos que N dias (um por linha). Pura: só
# enumera, não remove — a remoção com sudo vive em cleanup_old_coredumps.
# Uso: coredump_files_to_delete <dir> <keep_days>
coredump_files_to_delete() {
  local dir="$1" keep="$2"
  [[ -d "$dir" ]] || return 0
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || keep=7
  find "$dir" -maxdepth 1 -type f -mtime "+$keep" -print 2>/dev/null
}



# Remove dumps de crash em /var/lib/systemd/coredump mais antigos que
# COREDUMP_KEEP_DAYS (default 7). Crashes transitórios acumulam GB sem limite e
# o Doctor de recorrência lê o journal (não os arquivos), então limpar o disco
# nunca apaga a auditoria: os metadados seguem em `coredumpctl list` até o
# vacuum do journal. Sem dumps velhos retorna ok; falha operacional real
# (remoção) vira warn, nunca todo/fail — dump transitório não é erro do run.
cleanup_old_coredumps() {
  if ! has coredumpctl; then
    log "  coredumpctl não encontrado; nada a limpar."
    return 0
  fi
  local dir="${COREDUMP_DIR:-/var/lib/systemd/coredump}"
  local keep="${COREDUMP_KEEP_DAYS:-7}"
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || keep=7
  if [[ ! -d "$dir" ]]; then
    log "  Diretório de coredumps ${dir} não existe; nada a limpar."
    return 0
  fi
  local before
  before="$(du -sb "$dir" 2>/dev/null | awk '{print $1}')"
  local -a victims=()
  mapfile -t victims < <(coredump_files_to_delete "$dir" "$keep")
  if (( ${#victims[@]} == 0 )); then
    log "  Nenhum coredump com mais de ${keep} dias em ${dir}."
    return 0
  fi
  log "  Removendo ${#victims[@]} coredump(s) com mais de ${keep} dias em ${dir}..."
  if ! run_logged sudo rm -f -- "${victims[@]}"; then
    STEP_REASON="falha ao remover coredumps antigos em ${dir}"
    return "$RC_WARN"
  fi
  local after freed_mib
  after="$(du -sb "$dir" 2>/dev/null | awk '{print $1}')"
  if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
    freed_mib="$(awk -v b="$before" -v a="$after" 'BEGIN { printf "%.1f", (b - a) / 1048576 }')"
    log "  Coredumps antigos removidos: ${#victims[@]} arquivo(s), liberado ${freed_mib}MiB."
  else
    log "  Coredumps antigos removidos: ${#victims[@]} arquivo(s)."
  fi
  return 0
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
  local -a names=()
  local line name
  while IFS= read -r line; do
    [[ "$line" == *"full-upgrade pré-upgrade"* ]] || continue
    if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}) ]]; then
      name="${BASH_REMATCH[1]}"
      names+=("$name")
    fi
  done
  local limit=$(( ${#names[@]} - keep ))
  (( limit > 0 )) || return 0
  printf '%s\n' "${names[@]:0:limit}"
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
      local timeshift_list timeshift_list_rc
      timeshift_list="$(sudo timeshift --list 2>&1)"
      timeshift_list_rc=$?
      log_raw "$timeshift_list"
      if (( timeshift_list_rc != 0 )); then
        log "  Não foi possível listar snapshots Timeshift (rc=${timeshift_list_rc}); a rotação não foi executada."
        return "$RC_WARN"
      fi
      mapfile -t victims < <(printf '%s\n' "$timeshift_list" | timeshift_full_upgrade_names_to_delete "$keep")
      if (( ${#victims[@]} == 0 )); then
        log "  Nenhum snapshot timeshift full-upgrade antigo para remover (mantendo ${keep})."
        return 0
      fi
      log "  Snapshots Timeshift antigos a remover: ${#victims[@]} (mantendo ${keep}; de ${victims[0]} até ${victims[-1]})."
      log_raw "timeshift-victims: ${victims[*]}"
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
      log "  Rotação Timeshift concluída: ${#victims[@]} removido(s), ${keep} snapshot(s) full-upgrade mantido(s)."
      ;;
    *)
      log "  SNAPSHOT_TOOL inválido para limpeza: ${tool}"
      remediation "ajuste SNAPSHOT_TOOL=auto|snapper|timeshift|none em ${FU_CONFIG_FILE}"
      return "$RC_WARN"
      ;;
  esac
}



# NOTA: aur_ignore_args() vive em lib/core.sh (sourced antes deste arquivo).
# Mantida lá para reuso; não redefinir aqui para evitar divergência.

cleanup_paccache() {
  run_logged sudo paccache -r -k 2
}



cleanup_orphans() {
  local max_rounds="${ORPHAN_CLEANUP_MAX_ROUNDS:-5}"
  [[ "$max_rounds" =~ ^[0-9]+$ ]] && (( max_rounds > 0 )) || max_rounds=5

  local round=1 removed_any=0
  local -a orphans=()

  while (( round <= max_rounds )); do
    mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)

    if (( ${#orphans[@]} == 0 )); then
      if (( removed_any == 0 )); then
        log "  Nenhum pacote órfão encontrado."
      else
        log "  Limpeza de órfãos concluída; nenhuma dependência órfã remanescente."
      fi
      return 0
    fi

    log "  Pacotes órfãos encontrados (rodada ${round}/${max_rounds}, ${#orphans[@]}): ${orphans[*]}"

    if (( ASSUME_YES == 0 )); then
      if [[ -t 0 ]]; then
        printf '%b' "${C_YELLOW}  Remover pacotes órfãos? [s/N] ${C_RESET}"
        local answer
        read -r answer
        case "$answer" in
          [sS][iI][mM]|[sS]) ;;
          *) log "  Remoção de órfãos cancelada pelo usuário."; return 0 ;;
        esac
      else
        log "  Execução não interativa sem --yes; pulando remoção de órfãos."
        return 0
      fi
    fi

    run_logged sudo pacman -Rns --noconfirm -- "${orphans[@]}" || return $?
    removed_any=1
    (( round++ ))
  done

  mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)
  if (( ${#orphans[@]} > 0 )); then
    log "  Aviso: ainda há órfãos após ${max_rounds} rodada(s): ${orphans[*]}"
    log "  Remediação: rode novamente ou revise manualmente com pacman -Qdtq"
    STEP_REASON="órfãos remanescentes após ${max_rounds} rodada(s)"
    return "$RC_TODO"
  fi
  return 0
}
