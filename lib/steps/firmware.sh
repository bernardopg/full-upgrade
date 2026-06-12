#!/usr/bin/env bash
# steps/firmware.sh — fwupd, bootctl
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

update_fwupd() {
  # LC_ALL=C em todo fwupdmgr cuja saída é parseada: as strings de UI mudam
  # com o locale (pt_BR, es, ...) e quebrariam os filtros/contagens abaixo.
  local refresh_output rc_refresh

  refresh_output="$(_retry 2 env LC_ALL=C fwupdmgr refresh --force 2>&1)"
  rc_refresh=$?
  # Filtrar linhas de progresso de download do terminal (gravadas no log integralmente)
  log_raw "$refresh_output"
  printf '%s\n' "$refresh_output" | grep -v '^Downloading\|^Baixando' || true

  if (( rc_refresh != 0 && rc_refresh != RC_WARN )); then
    return "$rc_refresh"
  fi
  if (( rc_refresh == RC_WARN )); then
    log "  fwupdmgr refresh: falha de rede transitória — aviso, não erro."
    return "$RC_WARN"
  fi

  local updates_output rc
  updates_output="$(LC_ALL=C fwupdmgr get-updates 2>&1)"
  rc=$?
  log_raw "$updates_output"

  if (( rc == 2 )); then
    # Contagem de dispositivos via saída estruturada (independente de locale),
    # no lugar do antigo grep na string de UI "N dispositivos são atualizáveis".
    local device_count
    device_count="$(LC_ALL=C fwupdmgr get-devices --json 2>/dev/null | grep -c '"DeviceId"' || true)"
    if [[ "$device_count" =~ ^[0-9]+$ ]] && (( device_count > 0 )); then
      log "  Nenhuma atualização de firmware disponível (${device_count} dispositivos verificados)."
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
    | grep -v '^\s*•.*no available firmware updates\|^Devices with no\|^No updates available' \
    || true

  local update_output rc_update
  update_output="$(LC_ALL=C fwupdmgr update -y 2>&1)"
  rc_update=$?
  log_raw "$update_output"
  printf '%s\n' "$update_output" | grep -v '^Downloading\|^Baixando' || true
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


