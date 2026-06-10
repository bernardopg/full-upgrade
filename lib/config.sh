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
: "${MIN_FREE_GIB:=2}"              # espaço livre mínimo em / (GiB)
: "${MIN_BOOT_FREE_MIB:=200}"       # espaço livre mínimo em /boot (MiB; ESP é pequeno)
: "${SNAPSHOT_MIN_FREE_GIB:=2}"     # mínimo de livre em / p/ criar snapshot (0 = desliga)
# Backup de configs críticas antes das mutações (F1)
: "${BACKUP_CONFIGS:=1}"            # 1 = arquiva /etc críticas antes do update; 0 = desliga
: "${BACKUP_KEEP:=5}"               # quantos tarballs de backup manter (rotação)
# Lista de paths a arquivar (separados por espaço); default cobre o essencial p/ recuperar boot/pacman.
: "${BACKUP_PATHS:=/etc/pacman.conf /etc/pacman.d /etc/fstab /etc/mkinitcpio.conf /etc/mkinitcpio.d /etc/default/grub /etc/systemd/system /etc/environment /etc/hostname /etc/locale.conf}"
# Auto-atualização do próprio script
: "${FULL_UPGRADE_REPO:=bernardopg/full-upgrade}"   # slug owner/repo no GitHub
: "${FULL_UPGRADE_UPDATE_CHANNEL:=release}"         # release (última tag) | main (bleeding edge)
# Overrides de path (vazio = auto-detecta via command -v / locais conhecidos)
: "${GCLOUD_BIN:=}"
: "${COPILOT_BIN:=}"
: "${ADGUARD_BIN:=}"
: "${DMS_PLUGINS_DIR:=}"
: "${OPENCLAW_BIN:=}"

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
  [[ -z "$OPENCLAW_BIN" ]] && OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || true)"
  [[ -z "$DMS_PLUGINS_DIR" ]] && DMS_PLUGINS_DIR="${HOME}/.config/DankMaterialShell/plugins"

  export ENABLE_CUSTOM_TOOLS LANG_OVERRIDE SNAPSHOT_TOOL MIRROR_TOOL MIN_FREE_GIB MIN_BOOT_FREE_MIB
  export SNAPSHOT_MIN_FREE_GIB BACKUP_CONFIGS BACKUP_KEEP BACKUP_PATHS
  export GCLOUD_BIN COPILOT_BIN ADGUARD_BIN OPENCLAW_BIN DMS_PLUGINS_DIR
  export FULL_UPGRADE_REPO FULL_UPGRADE_UPDATE_CHANNEL
}

# Step custom só roda se: tools custom habilitados E a função foi carregada de steps.d/.
# Uso: custom_step_or_skip "Nome do step" funcao_impl
custom_step_or_skip() {
  local name="$1" fn="$2"
  if (( ${ENABLE_CUSTOM_TOOLS:-0} )) && declare -F "$fn" >/dev/null 2>&1; then
    run_step "$name" "$fn"
  else
    step_skip "$name" "tool custom desabilitado (ENABLE_CUSTOM_TOOLS=0)"
  fi
}
