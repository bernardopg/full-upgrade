#!/usr/bin/env bash
# lib/steps/doctor/storage.sh — auditorias de armazenamento: disco, SMART/NVMe, btrfs e TRIM.
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)


# Classifica o resultado de saúde SMART (campo de "overall-health").
# "PASSED"/"OK" => "ok"; vazio => "unknown"; qualquer outro => "todo".
smart_health_class() {
  case "$1" in
    PASSED|OK) printf "ok" ;;
    "")        printf "unknown" ;;
    *)         printf "todo" ;;
  esac
}


# Severidade de um contador SMART (setores realocados / não corrigíveis).
# Inteiro > 0 => "warn"; 0/vazio/não-numérico => "ok".
smart_counter_severity() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf "ok"; return 0; }
  (( n > 0 )) && printf "warn" || printf "ok"
}


doctor_disk_health() {
  if ! has df; then
    log "  df não encontrado."
    return 0
  fi

  local -a paths=()
  local -A seen_mounts=()
  local path mount_for_path
  for path in / /home /boot /boot/efi /efi; do
    [[ -d "$path" ]] || continue
    mount_for_path="$(df -P -- "$path" 2>/dev/null | awk 'NR==2 {print $6}' || true)"
    [[ -n "$mount_for_path" ]] || continue
    if [[ -z "${seen_mounts[$mount_for_path]+x}" ]]; then
      seen_mounts[$mount_for_path]=1
      paths+=("$mount_for_path")
    fi
  done

  if (( ${#paths[@]} == 0 )); then
    log "  Nenhum mount essencial encontrado para checar."
    return 0
  fi

  local status=0
  local line mount used_pct inode_pct
  log "  Uso de espaço:"
  df -Ph -- "${paths[@]}" | log_stream
  log "  Uso de inodes:"
  df -Pih -- "${paths[@]}" | log_stream

  while IFS= read -r line; do
    mount="$(awk '{print $6}' <<<"$line")"
    used_pct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$line")"
    [[ "$used_pct" =~ ^[0-9]+$ ]] || continue
    case "$(usage_pct_severity "$used_pct")" in
      todo)
        log "  Ação necessária: ${mount} está com ${used_pct}% de uso."
        status=$RC_TODO ;;
      warn)
        if (( status != RC_TODO )); then
          log "  Aviso: ${mount} está com ${used_pct}% de uso."
          status=$RC_WARN
        fi ;;
    esac
  done < <(df -P -- "${paths[@]}" | tail -n +2)

  while IFS= read -r line; do
    mount="$(awk '{print $6}' <<<"$line")"
    inode_pct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$line")"
    [[ "$inode_pct" =~ ^[0-9]+$ ]] || continue
    case "$(usage_pct_severity "$inode_pct")" in
      todo)
        log "  Ação necessária: ${mount} está com ${inode_pct}% de inodes usados."
        status=$RC_TODO ;;
      warn)
        if (( status != RC_TODO )); then
          log "  Aviso: ${mount} está com ${inode_pct}% de inodes usados."
          status=$RC_WARN
        fi ;;
    esac
  done < <(df -Pi -- "${paths[@]}" | tail -n +2)

  if (( status == 0 )); then
    log "  Espaço e inodes em níveis aceitáveis nos mounts checados."
  fi
  return "$status"
}



doctor_smart_health() {
  local status=0 found=0

  if ! _doctor_sudo_ok; then
    log "  smartctl/nvme requerem sudo sem prompt; checagem SMART pulada."
    return 0
  fi

  if has smartctl; then
    found=1
    local drives
    drives="$(smartctl --scan 2>/dev/null | awk '{print $1}' || true)"
    if [[ $drives != *[![:space:]]* ]]; then
      log "  smartctl --scan: nenhum disco encontrado."
    else
      local drive health
      while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        health="$(sudo -n smartctl -H "$drive" 2>/dev/null | awk '/overall-health|SMART overall/{print $NF}' | head -1 || true)"
        local reallocated uncorrectable
        reallocated="$(sudo -n smartctl -A "$drive" 2>/dev/null | awk '/Reallocated_Sector_Ct/{print $10}' | head -1 || true)"
        uncorrectable="$(sudo -n smartctl -A "$drive" 2>/dev/null | awk '/Offline_Uncorrectable/{print $10}' | head -1 || true)"
        case "$(smart_health_class "$health")" in
          ok)   log "  ${drive}: saúde SMART OK (${health})" ;;
          todo) log "  ${drive}: saúde SMART ${health} — verificar imediatamente."
                status="$RC_TODO" ;;
        esac
        if [[ "$(smart_counter_severity "$reallocated")" == "warn" ]]; then
          log "  ${drive}: setores realocados = ${reallocated} — disco com defeitos físicos."
          (( status == 0 )) && status="$RC_WARN"
        fi
        if [[ "$(smart_counter_severity "$uncorrectable")" == "warn" ]]; then
          log "  ${drive}: erros não corrigíveis = ${uncorrectable} — risco de perda de dados."
          (( status == 0 )) && status="$RC_WARN"
        fi
      done <<< "$drives"
    fi
  fi

  if has nvme; then
    found=1
    local nvme_devs
    nvme_devs="$(nvme list 2>/dev/null | awk 'NR>2 && /^\/dev/{print $1}' || true)"
    if [[ $nvme_devs == *[![:space:]]* ]]; then
      local dev nvme_out crit_warn
      while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        nvme_out="$(sudo -n nvme smart-log "$dev" 2>/dev/null || true)"
        crit_warn="$(printf '%s\n' "$nvme_out" | awk -F: '/critical_warning/{gsub(/[[:space:]]/,"",$2); print $2}' | head -1 || true)"
        local avail_spare
        avail_spare="$(printf '%s\n' "$nvme_out" | awk -F: '/avail_spare[^_]/{gsub(/[[:space:]%]/,"",$2); print $2}' | head -1 || true)"
        if [[ -n "$crit_warn" && "$crit_warn" != "0x0" && "$crit_warn" != "0" ]]; then
          log "  ${dev}: NVMe critical_warning=${crit_warn} — verificar."
          (( status == 0 )) && status="$RC_WARN"
        else
          log "  ${dev}: NVMe sem avisos críticos${avail_spare:+ (spare=${avail_spare}%)}"
        fi
      done <<< "$nvme_devs"
    fi
  fi

  if (( found == 0 )); then
    log "  smartctl e nvme não encontrados; instale smartmontools ou nvme-cli para monitorar discos."
  fi

  return "$status"
}



# F3 — saúde do btrfs: erros de I/O acumulados por device + idade do último
# scrub. Em raiz não-btrfs, pula limpo. RC_TODO se scrub vencido (>
# BTRFS_SCRUB_MAX_DAYS) ou se houver erros de device > 0.
doctor_btrfs_health() {
  if ! has btrfs; then
    log "  btrfs-progs não instalado; pulando."
    return 0
  fi

  local rootfs
  rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  if [[ "$rootfs" != "btrfs" ]]; then
    log "  Raiz não é btrfs (${rootfs:-?}); nada a verificar."
    return 0
  fi

  if ! _doctor_sudo_ok; then
    log "  btrfs device stats/scrub requerem sudo sem prompt; checagem pulada."
    return 0
  fi

  local status=0

  # 1) Erros de device acumulados (write/read/flush/corruption/generation).
  local stats errs
  stats="$(sudo -n btrfs device stats / 2>/dev/null || true)"
  if [[ $stats == *[![:space:]]* ]]; then
    errs="$(printf '%s\n' "$stats" | sum_btrfs_dev_errors)"
    if [[ "$errs" =~ ^[0-9]+$ ]] && (( errs > 0 )); then
      log "  ${C_YELLOW}btrfs: ${errs} erro(s) de device acumulado(s) em / — possível defeito físico.${C_RESET}"
      printf '%s\n' "$stats" | grep -E '_errs' | grep -vE '_errs[[:space:]]+0$' | log_stream
      log "  Remediação: investigue o disco (smartctl) e zere após resolver: sudo btrfs device stats -z /"
      status="$RC_TODO"
    else
      log "  btrfs: sem erros de device em / (contadores zerados)."
    fi
  fi

  # 2) Idade do último scrub.
  local scrub max_days last_epoch now_epoch age_days
  max_days="${BTRFS_SCRUB_MAX_DAYS:-30}"
  scrub="$(LC_ALL=C sudo -n btrfs scrub status / 2>/dev/null || true)"
  if grep -qiE 'no stats available|never' <<<"$scrub"; then
    log "  ${C_YELLOW}btrfs: nenhum scrub registrado em / — recomendado rodar periodicamente.${C_RESET}"
    log "  Remediação: sudo btrfs scrub start /"
    (( status == 0 )) && status="$RC_TODO"
  else
    # Extrai a data do início do último scrub (linhas variam por versão).
    local started
    started="$(printf '%s\n' "$scrub" | sed -nE 's/.*(started at|Scrub started:)[[:space:]]*//Ip' | head -1)"
    if [[ -n "$started" ]]; then
      last_epoch="$(LC_ALL=C date -d "$started" +%s 2>/dev/null || true)"
      now_epoch="$(date +%s 2>/dev/null || true)"
      if [[ "$last_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]]; then
        age_days=$(( (now_epoch - last_epoch) / 86400 ))
        if (( age_days > max_days )); then
          log "  ${C_YELLOW}btrfs: último scrub há ${age_days} dia(s) (> ${max_days}).${C_RESET}"
          log "  Remediação: sudo btrfs scrub start /"
          (( status == 0 )) && status="$RC_TODO"
        else
          log "  btrfs: último scrub há ${age_days} dia(s) (limite ${max_days}) — OK."
        fi
      fi
    fi
  fi

  if (( status == RC_TODO )); then
    STEP_REASON="btrfs: erros de device e/ou scrub vencido em /"
  fi
  return "$status"
}



# G1 — helper puro: classifica o estado do scrub a partir do texto de
# `btrfs scrub status <mp>` e do limite em dias. Emite (stdout) um de:
#   never        — nunca houve scrub registrado
#   due:<dias>   — último scrub há <dias> > max_days (vencido)
#   ok:<dias>    — último scrub há <dias> <= max_days
#   unknown      — não foi possível extrair a data (formato inesperado)
# Sem efeitos colaterais; testável com fixtures.
btrfs_scrub_state() {
  local txt="$1" max_days="${2:-30}"
  if grep -qiE 'no stats available|never' <<<"$txt"; then
    printf 'never'; return 0
  fi
  local started last_epoch now_epoch age_days
  started="$(printf '%s\n' "$txt" | sed -nE 's/.*(started at|Scrub started:)[[:space:]]*//Ip' | head -1)"
  [[ -n "$started" ]] || { printf 'unknown'; return 0; }
  # LC_ALL=C: a data vem de `btrfs scrub status` sob LC_ALL=C (inglês); parsear
  # no mesmo locale evita falha quando o ambiente está em pt_BR ("qui jun ...").
  last_epoch="$(LC_ALL=C date -d "$started" +%s 2>/dev/null || true)"
  now_epoch="$(date +%s 2>/dev/null || true)"
  [[ "$last_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
  age_days=$(( (now_epoch - last_epoch) / 86400 ))
  if (( age_days > max_days )); then
    printf 'due:%s' "$age_days"
  else
    printf 'ok:%s' "$age_days"
  fi
  return 0
}


# G1 — auto-remediação opcional de scrub btrfs vencido/ausente em /.
# O gate de config (AUTO_BTRFS_SCRUB) é aplicado em main.sh; aqui também é
# defensivo. Inicia `btrfs scrub start /` de forma NÃO-bloqueante (o scrub roda
# em background; bloquear estouraria o timeout do step). Sob confirmação/--yes.
# RC: 0 nada a fazer / scrub iniciado; RC_TODO sem sudo ou recusa/não interativo;
# RC_WARN se o comando de start falhar.
# J3 — avalia TODOS os filesystems btrfs montados (não só /), evitando scrubs
# redundantes quando vários subvolumes do mesmo dispositivo estão montados.
unique_btrfs_mountpoints() {
  awk '
    NF < 2 { next }
    {
      target=$1; src=$2
      sub(/\[.*$/, "", src)
      if (src=="" || seen[src]++) next
      print target
    }
  '
}


# J3 — enumera mountpoints btrfs distintos (um por dispositivo). Wrapper impuro
# sobre `findmnt -t btrfs` + unique_btrfs_mountpoints (puro, testável).
list_btrfs_mountpoints() {
  findmnt -rn -t btrfs -o TARGET,SOURCE 2>/dev/null | unique_btrfs_mountpoints
}


autofix_btrfs_scrub() {
  if (( ${AUTO_BTRFS_SCRUB:-0} == 0 )); then
    log "  AUTO_BTRFS_SCRUB desligado; nada a remediar."
    return 0
  fi
  if ! has btrfs; then
    log "  btrfs-progs não instalado; pulando."
    return 0
  fi

  local mounts
  mounts="$(list_btrfs_mountpoints)"
  if [[ $mounts != *[![:space:]]* ]]; then
    log "  Nenhum filesystem btrfs montado; nada a remediar."
    return 0
  fi

  if ! _doctor_sudo_ok; then
    log "  btrfs scrub requer sudo sem prompt; remediação pulada."
    STEP_REASON="requer sudo sem prompt"
    return "$RC_TODO"
  fi

  local max_days scrub state
  max_days="${BTRFS_SCRUB_MAX_DAYS:-30}"

  # 1) Avalia cada mountpoint e coleta os que precisam de scrub.
  local -a todo=()
  local mp
  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    scrub="$(LC_ALL=C sudo -n btrfs scrub status "$mp" 2>/dev/null || true)"
    state="$(btrfs_scrub_state "$scrub" "$max_days")"
    case "$state" in
      ok:*)
        log "  btrfs: scrub recente em ${mp} (${state#ok:} dia(s), limite ${max_days})."
        ;;
      unknown)
        log "  btrfs: não foi possível determinar a idade do scrub em ${mp}; pulando."
        ;;
      never)
        log "  btrfs: nenhum scrub registrado em ${mp}."
        todo+=("$mp")
        ;;
      due:*)
        log "  btrfs: último scrub há ${state#due:} dia(s) em ${mp} (> ${max_days})."
        todo+=("$mp")
        ;;
    esac
  done <<< "$mounts"

  if (( ${#todo[@]} == 0 )); then
    log "  btrfs: todos os scrub estão em dia; nada a fazer."
    return 0
  fi

  # 2) Gate: aplicar mutação exige confirmação (única para todos) ou --yes.
  if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
      printf '%b' "${C_YELLOW}  Iniciar 'btrfs scrub start' em ${#todo[@]} mountpoint(s)? [s/N] ${C_RESET}"
      local ans
      read -r ans
      case "$ans" in
        [sS][iI][mM]|[sS]) ;;
        *) log "  Scrub cancelado pelo usuário."; STEP_REASON="cancelado pelo usuário"; return "$RC_TODO" ;;
      esac
    else
      log "  Execução não interativa sem --yes; pulando scrub."
      STEP_REASON="requer --yes ou confirmação interativa"
      return "$RC_TODO"
    fi
  fi

  # 3) Inicia o scrub (background, não-bloqueante) em cada mountpoint pendente.
  local rc=0 started=0 failed=0
  for mp in "${todo[@]}"; do
    log "  Iniciando scrub em ${mp} (background)..."
    if run_logged sudo -n btrfs scrub start "$mp"; then
      started=$((started + 1))
    else
      failed=$((failed + 1))
      rc="$RC_WARN"
    fi
  done

  if (( failed == 0 )); then
    log "  ${C_GREEN}Scrub iniciado em ${started} mountpoint(s); acompanhe com 'sudo btrfs scrub status <mp>'.${C_RESET}"
    return 0
  fi
  log "  ${C_YELLOW}Scrub iniciado em ${started}, falhou em ${failed} mountpoint(s).${C_RESET}"
  STEP_REASON="falha ao iniciar scrub em ${failed} mountpoint(s)"
  return "$rc"
}


# Lista os mountpoints cujas opções trazem o token `discard` (`discard` ou
# `discard=async`). Entrada: `findmnt -lno TARGET,OPTIONS`. Compara token a
# token, então `nodiscard` não conta como TRIM ativo. Puro/testável.
mounts_with_discard() {
  awk '{
    n = split($2, opts, ",")
    for (i = 1; i <= n; i++) {
      if (opts[i] == "discard" || opts[i] ~ /^discard=/) { print $1; break }
    }
  }' | sort -u
}


# Doctor: verifica se há mecanismo de TRIM ativo para SSDs/NVMe.
# Dois mecanismos aceitáveis: fstrim.timer (periódico) ou discard= nas opções
# de mount (contínuo). Se nenhum dos dois está ativo e há SSD, alerta — sem
# TRIM, SSDs perdem performance e longevity ao acumular páginas marcadas como
# livres que nunca são devolvidas ao garbage collector do controlador.
doctor_trim_health() {
  # Detecta SSD/NVMe: queue/rotational == 0 em dispositivo de bloco real.
  # FU_SYSBLOCK_DIR existe só para o teste apontar para um sysfs falso; em
  # produção é sempre /sys/block.
  local has_ssd=0
  local dev name
  for dev in "${FU_SYSBLOCK_DIR:-/sys/block}"/*; do
    [[ -f "${dev}/queue/rotational" ]] || continue
    name="${dev##*/}"
    [[ "$name" =~ ^(loop|ram|dm-|md) ]] && continue
    if [[ "$(cat "${dev}/queue/rotational" 2>/dev/null || echo 1)" == "0" ]]; then
      has_ssd=1; break
    fi
  done
  (( has_ssd )) || {
    log "  Nenhum SSD/NVMe detectado; TRIM não aplicável."
    return 0
  }

  # Mecanismo 1: fstrim.timer ativo (TRIM periódico semanal).
  if has systemctl && systemctl is-active --quiet fstrim.timer 2>/dev/null; then
    log "  TRIM periódico ativo (fstrim.timer em execução)."
    return 0
  fi

  # Mecanismo 2: discard= nas opções de mount de qualquer filesystem (contínuo).
  # Btrfs com discard=async é a abordagem preferida em NVMe — mais eficiente que
  # o fstrim.timer porque devolve páginas ao GC do SSD imediatamente, sem scan.
  local discard_fs
  discard_fs="$(findmnt -lno TARGET,OPTIONS 2>/dev/null | mounts_with_discard | tr '\n' ' ' | sed 's/ *$//')"
  if [[ $discard_fs == *[![:space:]]* ]]; then
    log "  TRIM contínuo ativo via discard mount option em: ${discard_fs}."
    return 0
  fi

  # Nem periódico nem contínuo — SSD sem TRIM.
  log "  ${C_YELLOW}SSD/NVMe detectado sem mecanismo de TRIM ativo.${C_RESET}"
  log "  Sem TRIM, blocos livres acumulam e degradam write amplification e performance do SSD."
  remediation "sudo systemctl enable --now fstrim.timer (periódico, simples)"
  log "              OU adicione 'discard=async' às opções de mount no /etc/fstab (contínuo, preferido em NVMe)."
  STEP_REASON="SSD sem TRIM (nem fstrim.timer nem discard mount option)"
  return "$RC_TODO"
}
