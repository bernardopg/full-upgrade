#!/usr/bin/env bash
# lib/sudo.sh — sudo keepalive + trap de saída
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

start_sudo_keepalive() {
  if ! has sudo; then
    return 1
  fi
  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    if ! sudo -n true >/dev/null 2>&1; then
      log "  sudo indisponível sem prompt interativo; steps que exigem privilégio serão pulados."
      return "$RC_WARN"
    fi
  else
    if ! sudo -v; then
      return 1
    fi
  fi
  (
    while true; do
      sleep 45
      sudo -n true >/dev/null 2>&1 || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
  printf '%s\n' "$SUDO_KEEPALIVE_PID" >"$SUDO_KEEPALIVE_PID_FILE"
  return 0
}

stop_sudo_keepalive() {
  if [[ -z "${SUDO_KEEPALIVE_PID:-}" && -s "${SUDO_KEEPALIVE_PID_FILE:-}" ]]; then
    SUDO_KEEPALIVE_PID="$(<"$SUDO_KEEPALIVE_PID_FILE")"
  fi
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  [[ -n "${SUDO_KEEPALIVE_PID_FILE:-}" ]] && rm -f -- "$SUDO_KEEPALIVE_PID_FILE"
}

on_exit() {
  stop_sudo_keepalive
}

trap on_exit EXIT
