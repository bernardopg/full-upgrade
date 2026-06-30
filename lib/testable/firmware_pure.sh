#!/usr/bin/env bash
# lib/testable/firmware_pure.sh — funções puras extraídas de lib/steps/firmware.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# fwupdmgr_get_device_count — conta dispositivos via JSON (locale-independente)
fwupdmgr_get_device_count() {
  local json_output="$1"
  printf '%s\n' "$json_output" | grep -c '"DeviceId"' || true
}

# fwupdmgr_has_updates — verifica se há updates (rc=2 = nenhum)
fwupdmgr_has_updates() {
  local rc="$1"
  (( rc == 2 ))
}

# fwupdmgr_is_network_error — detecta erro de rede transitório no output
fwupdmgr_is_network_error() {
  local output="$1"
  printf '%s\n' "$output" | grep -qiE 'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'
}

# bootctl_is_installed — verifica se systemd-boot está instalado no ESP
# Para teste: sobrescreva bootctl
bootctl_is_installed() {
  bootctl is-installed >/dev/null 2>&1
}

# bootctl_update_already_applied — detecta "já atualizado" no output
bootctl_update_already_applied() {
  local output="$1"
  printf '%s\n' "$output" | grep -q 'same boot loader version in place already'
}