#!/usr/bin/env bash
# lib/testable/doctor_pure.sh — funções puras extraídas de lib/steps/doctor.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# arch_audit_affected_count — conta pacotes afetados na saída do arch-audit
# Formatos: "pkg is affected by ..." ou "Package pkg is affected by ..."
arch_audit_affected_count() {
  local count=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^(Package[[:space:]]+)?[^[:space:]]+[[:space:]]+is[[:space:]]+affected[[:space:]]+by ]]; then
      ((count++))
    fi
  done
  printf '%d\n' "$count"
}

# _ai_cli_first_version — extrai primeira linha com versão do output de --version de CLIs
_ai_cli_first_version() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ [0-9] ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done
  return 1
}

# unique_btrfs_mountpoints — dedup de mountpoints Btrfs do mesmo device (findmnt CSV)
unique_btrfs_mountpoints() {
  local -A seen=()
  local target source header=1
  while IFS=',' read -r target source; do
    if (( header )); then header=0; continue; fi
    source="${source//\"/}"
    target="${target//\"/}"
    [[ -z "$source" ]] && continue
    [[ "${seen[$source]+x}" ]] && continue
    seen["$source"]=1
    printf '%s\n' "$target"
  done
}

# btrfs_scrub_state — parser puro de 'btrfs scrub status' para mountpoint
# Retorna: "running|finished|error|none" via stdout
btrfs_scrub_state() {
  local output="$1" line state=""
  while IFS= read -r line; do
    if [[ "$line" == *"Status:"* ]]; then
      state="${line#*Status:}"
      state="${state# }"
      state="${state%% *}"
      break
    fi
  done <<< "$output"
  case "$state" in
    running|started) printf 'running\n' ;;
    finished|done)   printf 'finished\n' ;;
    error*)          printf 'error\n' ;;
    *)               printf 'none\n' ;;
  esac
}

# fwupdmgr_get_device_count — conta DeviceId no JSON de 'fwupdmgr get-devices --json'
fwupdmgr_get_device_count() {
  local json="$1"
  printf '%s\n' "$json" | grep -o '"DeviceId"' | wc -l | tr -d ' '
}

# fwupdmgr_has_updates — retorna 0 quando rc=2 (get-updates: nenhuma atualização disponível)
fwupdmgr_has_updates() {
  [[ "$1" == "2" ]]
}

# fwupdmgr_is_network_error — retorna 0 se mensagem indica falha de rede transitória
fwupdmgr_is_network_error() {
  local re='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'
  [[ "$1" =~ $re ]]
}

# bootctl_update_already_applied — retorna 0 se output indica boot loader já atualizado
bootctl_update_already_applied() {
  [[ "$1" == *"same boot loader version"* ]]
}

# days_since_epoch — dias desde epoch (para comparar datas de snapshot)
days_since_epoch() {
  local date_str="$1"
  # Input esperado: YYYY-MM-DD ou similar
  date -d "$date_str" +%s 2>/dev/null | awk '{ print int($1 / 86400) }'
}