#!/usr/bin/env bash
# steps.d/adguardvpn — AdGuard VPN CLI (custom)
# shellcheck shell=bash

update_adguardvpn() {
  local cli_bin="${ADGUARD_BIN:-$(command -v adguardvpn-cli 2>/dev/null || true)}"
  if [[ -z "$cli_bin" || ! -x "$cli_bin" ]]; then
    log "  adguardvpn-cli não encontrado (defina ADGUARD_BIN no config)."
    return 0
  fi

  local current
  current="$("$cli_bin" --version 2>/dev/null | awk '{print $NF}' || true)"
  log "  AdGuard VPN CLI atual: ${current}"

  local output rc
  output="$("$cli_bin" update -y 2>&1)"
  rc=$?
  printf '%s\n' "$output" >> "$LOG_FILE"

  # rc=17 = "You are using the latest version" — não é falha
  if (( rc == 17 )) || printf '%s\n' "$output" | grep -q 'latest version'; then
    log "  adguardvpn-cli ${current} já na versão mais recente."
    return 0
  fi

  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
}


