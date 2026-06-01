#!/usr/bin/env bash
# steps.d/adguardvpn — AdGuard VPN CLI (custom)
# shellcheck shell=bash

update_adguardvpn() {
  local cli_bin="/usr/local/bin/adguardvpn-cli"
  if [[ ! -x "$cli_bin" ]]; then
    log "  adguardvpn-cli não encontrado em /usr/local/bin."
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


