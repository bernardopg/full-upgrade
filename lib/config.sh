#!/usr/bin/env bash
# lib/config.sh — carregamento de configuração do usuário + auto-detecção.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

# Diretório de config (XDG). Exposto para o entrypoint achar steps.d/ do usuário.
FU_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/full-upgrade"
FU_CONFIG_FILE="${FU_CONFIG_DIR}/config"
export FU_CONFIG_DIR FU_CONFIG_FILE

# Defaults de config (zero-config funciona). Sobrescritos pelo arquivo se existir.
: "${ENABLE_CUSTOM_TOOLS:=0}"
: "${LANG_OVERRIDE:=auto}"          # auto|pt|en
: "${SNAPSHOT_TOOL:=auto}"          # auto|snapper|timeshift|none
: "${MIRROR_TOOL:=auto}"            # auto|reflector|rate-mirrors|none
: "${MIN_FREE_GIB:=2}"              # espaço livre mínimo em / e /boot
# Overrides de path (vazio = auto-detecta via command -v / locais conhecidos)
: "${GCLOUD_BIN:=}"
: "${COPILOT_BIN:=}"
: "${ADGUARD_BIN:=}"
: "${DMS_PLUGINS_DIR:=}"

load_config() {
  if [[ -f "$FU_CONFIG_FILE" ]]; then
    # Config é bash sourced. Validação leve: só permite num arquivo regular do usuário.
    if [[ -r "$FU_CONFIG_FILE" ]]; then
      # shellcheck source=/dev/null
      source "$FU_CONFIG_FILE"
    fi
  fi

  # Auto-detecção de paths quando não definidos no config.
  [[ -z "$GCLOUD_BIN"  ]] && GCLOUD_BIN="$(command -v gcloud 2>/dev/null || true)"
  [[ -z "$COPILOT_BIN" ]] && COPILOT_BIN="$(command -v copilot 2>/dev/null || true)"
  [[ -z "$ADGUARD_BIN" ]] && ADGUARD_BIN="$(command -v adguardvpn-cli 2>/dev/null || true)"
  [[ -z "$DMS_PLUGINS_DIR" ]] && DMS_PLUGINS_DIR="${HOME}/.config/DankMaterialShell/plugins"

  export ENABLE_CUSTOM_TOOLS LANG_OVERRIDE SNAPSHOT_TOOL MIRROR_TOOL MIN_FREE_GIB
  export GCLOUD_BIN COPILOT_BIN ADGUARD_BIN DMS_PLUGINS_DIR
}
