#!/usr/bin/env bash
# steps/repair.sh — reparos genéricos (command shadowing)
# Burp/Wireshark (custom) movidos p/ steps.d/50-burp-wireshark.sh
# shellcheck shell=bash

repair_command_shadowing() {
  local name="$1"
  local managed_path="$2"
  local local_path="/usr/local/bin/${name}"

  if [[ ! -e "$local_path" ]]; then
    log "  Sem sombra local para ${name}."
    return 0
  fi

  if [[ ! -e "$managed_path" ]]; then
    log "  Binario gerenciado não encontrado para ${name}: ${managed_path}"
    return 1
  fi

  if pacman -Qo "$local_path" >/dev/null 2>&1; then
    log "  ${local_path} e gerenciado por pacote; nada a reparar."
    return 0
  fi

  if ! pacman -Qo "$managed_path" >/dev/null 2>&1; then
    log "  ${managed_path} não e gerenciado pelo pacman; não vou alterar ${local_path}."
    return 1
  fi

  local backup
  backup="${local_path}.manual.$(date +%Y%m%d-%H%M%S)"
  log "  Movendo binario local que sombreia o pacote: ${local_path} -> ${backup}"
  run_logged sudo mv -- "$local_path" "$backup"
}


repair_known_command_shadowing() {
  repair_command_shadowing wireshark /usr/bin/wireshark
}


