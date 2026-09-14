#!/usr/bin/env bash
# lib/steps/manual_apps.sh — helpers compartilhados pelos steps de programas
# instalados FORA de qualquer gerenciador de pacotes (sem pacman/AUR/flatpak/
# snap por trás). Os steps em si vivem no arquivo do seu domínio: CLIs de IA em
# ai.sh, segurança em security.sh, utilitários em tools.sh, e o inventário
# read-only em doctor/packages.sh (Série T4).
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

_manual_write_prefix() {
  local target="$1" dir
  dir="$(dirname "$target")"
  if [[ -w "$target" && -w "$dir" ]]; then
    printf ''
    return 0
  fi
  if has sudo && sudo -n true 2>/dev/null; then
    printf 'sudo'
    return 0
  fi
  return 1
}
