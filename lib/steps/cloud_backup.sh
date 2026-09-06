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

# ── Progresso do upload ───────────────────────────────────────────────────────
# O upload leva ~95 min num repositório OneDrive de ~100 GiB. Sem feedback, o
# step parece travado: o único sinal era o cursor parado por uma hora e meia.
# `restic backup --json` emite um fluxo de linhas `status` (uma a cada ~60 ms) e
# uma `summary` final; as funções abaixo o convertem em heartbeats legíveis,
# limitados a um a cada TIMESHIFT_CLOUD_PROGRESS_INTERVAL segundos.

# Intervalo entre heartbeats. Valores inválidos voltam a 60s: um a cada minuto
# dá ~95 linhas num upload completo — informativo sem virar ruído no log.
timeshift_cloud_progress_interval() {
  local secs="${TIMESHIFT_CLOUD_PROGRESS_INTERVAL:-60}"
  [[ "$secs" =~ ^[0-9]+$ ]] && (( secs > 0 )) || secs=60
  printf '%s' "$secs"
}

# Extrai um campo escalar (número ou string) de uma linha JSON plana do restic.
# O fluxo `--json` do restic é plano por linha, então uma regex resolve sem
# arrastar jq/python para dentro de um step que roda como root.
timeshift_cloud_json_field() {
  local json="$1" key="$2"
  if [[ "$json" =~ \"$key\":[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$json" =~ \"$key\":[[:space:]]*(-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Bytes → unidade legível com uma casa decimal (aritmética inteira: o step roda
# em contextos sem bc e `printf %.1f` não aceita divisão em Bash).
timeshift_cloud_human_bytes() {
  local bytes="${1:-0}"
  bytes="${bytes%%.*}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  local -a units=(B KiB MiB GiB TiB)
  local idx=0 value="$bytes" frac=0
  while (( value >= 1024 && idx < 4 )); do
    frac=$(( (value % 1024) * 10 / 1024 ))
    value=$(( value / 1024 ))
    (( idx++ ))
  done
  if (( idx == 0 )); then
    printf '%dB' "$value"
  else
    printf '%d.%d%s' "$value" "$frac" "${units[idx]}"
  fi
}

# Segundos → "1h05m" / "32m10s" / "45s".
timeshift_cloud_human_secs() {
  local secs="${1:-0}"
  secs="${secs%%.*}"
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
  if (( secs >= 3600 )); then
    printf '%dh%02dm' $(( secs / 3600 )) $(( (secs % 3600) / 60 ))
  elif (( secs >= 60 )); then
    printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 ))
  else
    printf '%ds' "$secs"
  fi
}

# Formata uma linha `status` do restic. Antes de o scan terminar, total_bytes é
# 0 e uma porcentagem seria mentira — nessa fase reportamos o que existe de
# verdade (arquivos e bytes já lidos) em vez de um "0%" imóvel.
# $2/$3 (opcionais): bytes e instante da amostra anterior, para velocidade real
# da janela em vez da média desde o início, que esconde uma rede que caiu.
timeshift_cloud_progress_line() {
  local json="$1" prev_bytes="${2:-}" prev_elapsed="${3:-}"
  local total_bytes bytes_done total_files files_done elapsed remaining pct
  total_bytes="$(timeshift_cloud_json_field "$json" total_bytes || printf '0')"
  bytes_done="$(timeshift_cloud_json_field "$json" bytes_done || printf '0')"
  total_files="$(timeshift_cloud_json_field "$json" total_files || printf '0')"
  files_done="$(timeshift_cloud_json_field "$json" files_done || printf '0')"
  elapsed="$(timeshift_cloud_json_field "$json" seconds_elapsed || printf '0')"
  remaining="$(timeshift_cloud_json_field "$json" seconds_remaining || printf '')"
  total_bytes="${total_bytes%%.*}"; bytes_done="${bytes_done%%.*}"
  total_files="${total_files%%.*}"; files_done="${files_done%%.*}"
  elapsed="${elapsed%%.*}"
  [[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0
  [[ "$bytes_done" =~ ^[0-9]+$ ]] || bytes_done=0
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0

  # Velocidade da janela quando há amostra anterior; média desde o início senão.
  local speed_secs="$elapsed" speed_bytes="$bytes_done"
  if [[ "$prev_bytes" =~ ^[0-9]+$ && "$prev_elapsed" =~ ^[0-9]+$ ]] \
    && (( elapsed > prev_elapsed && bytes_done >= prev_bytes )); then
    speed_secs=$(( elapsed - prev_elapsed ))
    speed_bytes=$(( bytes_done - prev_bytes ))
  fi
  local speed="—"
  (( speed_secs > 0 )) && speed="$(timeshift_cloud_human_bytes $(( speed_bytes / speed_secs )))/s"

  local out
  if (( total_bytes <= 0 )); then
    out="escaneando… ${files_done} arq · $(timeshift_cloud_human_bytes "$bytes_done") lidos"
    out+=" · ${speed} · $(timeshift_cloud_human_secs "$elapsed") decorrido"
    printf '%s' "$out"
    return 0
  fi

  # A porcentagem do restic mede LEITURA, não envio: ao chegar a 100% ele ainda
  # está subindo packs por minutos (ou dezenas deles, nesta rede). Anunciar
  # "100% · 0B/s" ali seria pior que silêncio — parece travado justamente na
  # fase mais longa. Nomeia a fase em vez de fingir que acabou.
  if (( bytes_done >= total_bytes )); then
    out="enviando pacotes ao remoto… $(timeshift_cloud_human_bytes "$total_bytes") lidos"
    out+=" · ${files_done}/${total_files} arq"
    out+=" · $(timeshift_cloud_human_secs "$elapsed") decorrido"
    printf '%s' "$out"
    return 0
  fi

  pct=$(( bytes_done * 100 / total_bytes ))
  (( pct > 100 )) && pct=100
  out="$(printf '%3d%%' "$pct")"
  out+=" · $(timeshift_cloud_human_bytes "$bytes_done")/$(timeshift_cloud_human_bytes "$total_bytes")"
  out+=" · ${files_done}/${total_files} arq"
  out+=" · ${speed}"
  out+=" · $(timeshift_cloud_human_secs "$elapsed") decorrido"
  remaining="${remaining%%.*}"
  if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining > 0 )); then
    out+=" · ETA $(timeshift_cloud_human_secs "$remaining")"
  fi
  printf '%s' "$out"
}

# Formata a linha `summary` final: o que efetivamente subiu (data_added é o que
# custou rede; total_bytes_processed inclui o que a deduplicação já tinha).
timeshift_cloud_summary_line() {
  local json="$1"
  local added processed files_new files_changed duration snap
  added="$(timeshift_cloud_json_field "$json" data_added_packed \
    || timeshift_cloud_json_field "$json" data_added || printf '0')"
  processed="$(timeshift_cloud_json_field "$json" total_bytes_processed || printf '0')"
  files_new="$(timeshift_cloud_json_field "$json" files_new || printf '0')"
  files_changed="$(timeshift_cloud_json_field "$json" files_changed || printf '0')"
  duration="$(timeshift_cloud_json_field "$json" total_duration || printf '0')"
  snap="$(timeshift_cloud_json_field "$json" snapshot_id || printf '')"

  local out="Concluído: ${files_new} novo(s), ${files_changed} alterado(s)"
  out+=" · $(timeshift_cloud_human_bytes "$added") enviados"
  out+=" · $(timeshift_cloud_human_bytes "$processed") processados"
  out+=" · em $(timeshift_cloud_human_secs "$duration")"
  [[ -n "$snap" ]] && out+=" · snapshot ${snap:0:8}"
  printf '%s' "$out"
}

# Consome o fluxo `--json` do restic e emite heartbeats. Linhas que não são JSON
# (erros de rclone, avisos de lock) são ecoadas: era exatamente esse texto que
# sumia do log — o step chamava restic sem passar por `log`, então a causa de
# uma falha só existia no terminal de quem estava olhando na hora.
timeshift_cloud_consume_progress() {
  local interval last line elapsed
  local prev_bytes="" prev_elapsed=""
  interval="$(timeshift_cloud_progress_interval)"
  # Primeiro status sai na hora: o valor de um heartbeat é dizer "comecei e
  # estou vivo", e esperar um intervalo inteiro para isso recria em menor
  # escala justamente o silêncio que este bloco existe para eliminar.
  last=$(( SECONDS - interval ))
  while IFS= read -r line; do
    case "$line" in
      *'"message_type":"status"'*)
        # Heartbeat com janela fixa: o restic emite ~16 status/s e imprimir
        # todos transformaria o log de um run em centenas de milhares de linhas.
        (( SECONDS - last < interval )) && continue
        last="$SECONDS"
        log "  ${C_DIM}↑${C_RESET} $(timeshift_cloud_progress_line "$line" "$prev_bytes" "$prev_elapsed")"
        prev_bytes="$(timeshift_cloud_json_field "$line" bytes_done || printf '')"
        prev_bytes="${prev_bytes%%.*}"
        elapsed="$(timeshift_cloud_json_field "$line" seconds_elapsed || printf '')"
        prev_elapsed="${elapsed%%.*}"
        ;;
      *'"message_type":"summary"'*)
        log "  $(timeshift_cloud_summary_line "$line")"
        ;;
      *'"message_type":"error"'*)
        log "  ${C_YELLOW}restic:${C_RESET} $(timeshift_cloud_json_field "$line" message \
          || timeshift_cloud_json_field "$line" error || printf '%s' "$line")"
        ;;
      '') ;;
      '{'*) ;;   # verbose_status e afins: ruído por arquivo, sem valor agregado
      *)
        # Texto cru do restic/rclone (lock, rede, token): a causa raiz das
        # falhas deste step mora aqui.
        log "  ${line}"
        ;;
    esac
  done
  return 0
}

# Roda `restic backup --json` com stderr fundido ao stdout e alimenta o
# consumidor de progresso. Retorna o rc do restic, não o do pipeline.
_timeshift_cloud_restic_progress() {
  _timeshift_cloud_restic "$@" 2>&1 | timeshift_cloud_consume_progress
  return "${PIPESTATUS[0]}"
}

# `restic unlock` remove apenas locks stale (processo morto ou fora do host);
# um run concorrente e vivo continua protegido. Falha aqui nunca derruba o
# step: se o lock era legítimo, o próprio restic reclama logo depois.
timeshift_cloud_clear_stale_locks() {
  run_logged _timeshift_cloud_restic unlock || true
  return 0
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
    log "  Progresso a cada $(timeshift_cloud_progress_interval)s (TIMESHIFT_CLOUD_PROGRESS_INTERVAL)."
    timeshift_cloud_clear_stale_locks
    local -a backup_args=(
      backup --json --tag full-upgrade-timeshift --tag "$snapshot"
    )
    if [[ -n "${TIMESHIFT_CLOUD_EXCLUDE_FILE:-}" && -r "$TIMESHIFT_CLOUD_EXCLUDE_FILE" ]]; then
      backup_args+=(--exclude-file "$TIMESHIFT_CLOUD_EXCLUDE_FILE")
      log "  Exclusões de caches/artefatos: ${TIMESHIFT_CLOUD_EXCLUDE_FILE}"
    fi
    backup_args+=("${snapshot_dir}/@" "${snapshot_dir}/@home")
    if _timeshift_cloud_restic_progress "${backup_args[@]}"; then
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

  # Mesma armadilha, outro caminho: o restic sob sudo popula ~/.cache/restic com
  # subdiretórios root-owned, e depois um `restic snapshots` do usuário morre em
  # "permission denied" ao gravar o cache — o repositório parece quebrado quando
  # só a posse do cache está errada.
  local restic_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/restic"
  [[ -d "$restic_cache" ]] &&
    sudo -n chown -R "$(id -u):$(id -g)" "$restic_cache" 2>/dev/null || true

  if (( rc == 0 )); then
    keep="$(timeshift_cloud_keep_count)"
    log "  Aplicando retenção remota: manter as ${keep} versões mais recentes."
    # `forget --prune` exige lock EXCLUSIVO, ao contrário do backup, que se
    # contenta com um compartilhado. Por isso um lock stale de um run
    # interrompido deixava o backup passar e só a retenção falhar — foi esse o
    # warn de 2026-09-03, com um lock de 31h de um PID que não existia mais.
    timeshift_cloud_clear_stale_locks
    # --group-by '' é obrigatório aqui: por padrão o restic agrupa por
    # host+paths, e os paths carregam o nome do snapshot Timeshift, que muda a
    # cada run. Sem isso cada backup vira um grupo de um elemento, "keep-last 3"
    # nunca descarta nada e o repositório remoto cresce para sempre — a
    # retenção parecia configurada e nunca tinha apagado uma única versão.
    if ! run_logged _timeshift_cloud_restic forget \
      --tag full-upgrade-timeshift --group-by '' --keep-last "$keep" --prune; then
      STEP_REASON="backup enviado, mas retenção remota falhou"
      rc="$RC_WARN"
    fi
  fi

  return "$rc"
}
