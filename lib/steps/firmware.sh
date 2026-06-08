#!/usr/bin/env bash
# steps/firmware.sh — fwupd, bootctl
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

update_fwupd() {
  local refresh_output rc_refresh

  refresh_output="$(_retry 2 fwupdmgr refresh --force 2>&1)"
  rc_refresh=$?
  # Filtrar linhas de progresso de download do terminal (gravadas no log integralmente)
  log_raw "$refresh_output"
  printf '%s\n' "$refresh_output" | grep -v '^Baixando\|^Downloading' || true

  if (( rc_refresh != 0 && rc_refresh != RC_WARN )); then
    return "$rc_refresh"
  fi
  if (( rc_refresh == RC_WARN )); then
    log "  fwupdmgr refresh: falha de rede transitória — aviso, não erro."
    return "$RC_WARN"
  fi

  local updates_output rc
  updates_output="$(fwupdmgr get-updates 2>&1)"
  rc=$?
  log_raw "$updates_output"

  if (( rc == 2 )); then
    # Extrair contagem de dispositivos sem update do refresh output
    local no_update_count
    no_update_count="$(printf '%s\n' "$refresh_output" | grep -oP '\d+(?= dispositivos são atualizáveis)' || true)"
    if [[ -n "$no_update_count" ]]; then
      log "  Nenhuma atualização de firmware disponível (${no_update_count} dispositivos verificados)."
    else
      log "  Nenhuma atualização de firmware disponível."
    fi
    return 0
  fi
  if (( rc != 0 )); then
    return "$rc"
  fi

  # Tem atualizações — mostrar quais dispositivos serão atualizados
  printf '%s\n' "$updates_output" \
    | grep -v '^\s*•.*sem atualizações\|^Dispositivos sem\|^Nenhuma atualização disponível' \
    || true

  local update_output rc_update
  update_output="$(fwupdmgr update -y 2>&1)"
  rc_update=$?
  log_raw "$update_output"
  printf '%s\n' "$update_output" | grep -v '^Baixando\|^Downloading' || true
  return "$rc_update"
}


update_bootctl() {
  if ! has bootctl; then
    log "  bootctl não encontrado."
    return 0
  fi

  if ! sudo bootctl is-installed >/dev/null 2>&1; then
    log "  systemd-boot não instalado no ESP; pulando."
    return 0
  fi

  local output rc
  output="$(sudo bootctl update 2>&1)"
  rc=$?
  printf '%s\n' "$output" | tee >(_strip_ansi >> "$LOG_FILE")
  # rc=1 quando já atualizado ("same boot loader version in place already") — tratar como ok
  if (( rc == 1 )) && printf '%s\n' "$output" | grep -q 'same boot loader version'; then
    log "  systemd-boot: já atualizado."
    return 0
  fi
  return "$rc"
}


