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
: "${AUR_HELPER:=}"                 # auto = detecta (paru > yay > pikaur); ou nome explícito
: "${PRIV_CMD:=}"                   # auto = detecta (sudo > doas > sudo-rs > run0); ou nome explícito
: "${MIN_FREE_GIB:=2}"              # espaço livre mínimo em / (GiB)
: "${MIN_BOOT_FREE_MIB:=200}"       # espaço livre mínimo em /boot (MiB; ESP é pequeno)
: "${SNAPSHOT_MIN_FREE_GIB:=2}"     # mínimo de livre em / p/ criar snapshot (0 = desliga)
: "${SNAPSHOT_KEEP:=5}"             # snapshots full-upgrade antigos a manter
# Doctor: limiares de saúde
: "${BTRFS_SCRUB_MAX_DAYS:=30}"     # alerta se o último scrub btrfs em / for mais antigo que isso
: "${BOOT_TIME_WARN_S:=60}"         # alerta se o boot (systemd-analyze) exceder N segundos
: "${DOCKER_INFO_TIMEOUT_S:=5}"     # timeout curto para detectar daemon Docker inacessível
: "${ORPHAN_CLEANUP_MAX_ROUNDS:=5}" # rodadas máximas para remover órfãos recursivos
: "${AUTO_FIX_RUST_CVES:=0}"        # 1 = oferece remediar CVEs de toolchain Rust (rustup self update/update + cargo install-update) sob --yes/confirmação; 0 = só reporta
: "${AUTO_BTRFS_SCRUB:=0}"          # 1 = oferece iniciar `btrfs scrub start` quando o scrub estiver vencido/ausente sob --yes/confirmação; 0 = só reporta
: "${REPORT_ON_FINISH:=0}"          # 1 = grava relatório Markdown do run em ~/.cache/system-upgrade/full-upgrade-<run_id>.md ao final; 0 = desliga
: "${ARCH_NEWS_CHECK:=1}"           # 1 = checa Arch News (RSS) antes das mutações e alerta sobre itens novos; 0 = desliga
: "${NOTIFY_ON_FINISH:=0}"          # 1 = envia notificação desktop (notify-send) com o resumo ao fim do run; 0 = desliga
: "${MCP_AUTO_UPDATE:=0}"           # reservado: 1 = (futuro) atualiza servidores MCP npm/uvx; 0 = só doctor read-only
: "${OLLAMA_SELF_UPDATE:=0}"        # 1 = reexecuta o instalador oficial do Ollama (curl|sh) no step; 0 = só reporta a versão
: "${IDE_EXT_CLIS:=}"               # lista (espaço) de CLIs VSCode-family p/ atualizar extensões; vazio = autodetect (code cursor codium ...)
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

# I3 — detecta o helper AUR a usar. Prioridade: AUR_HELPER explícito (se
# instalado) > paru > yay > pikaur. Emite o nome em stdout (rc 0) ou nada (rc 1).
detect_aur_helper() {
  local h
  if [[ -n "${AUR_HELPER:-}" ]] && has "$AUR_HELPER" 2>/dev/null; then
    printf '%s' "$AUR_HELPER"; return 0
  fi
  for h in paru yay pikaur; do
    has "$h" 2>/dev/null && { printf '%s' "$h"; return 0; }
  done
  return 1
}

# I3 — detecta o elevador de privilégio. Prioridade: PRIV_CMD explícito (se
# instalado) > sudo > doas > sudo-rs > run0. Emite o nome (rc 0) ou nada (rc 1).
detect_priv_cmd() {
  local c
  if [[ -n "${PRIV_CMD:-}" ]] && has "$PRIV_CMD" 2>/dev/null; then
    printf '%s' "$PRIV_CMD"; return 0
  fi
  for c in sudo doas sudo-rs run0; do
    has "$c" 2>/dev/null && { printf '%s' "$c"; return 0; }
  done
  return 1
}

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

  # I3 — auto-detecção de helper AUR e elevador de privilégio (depois do config
  # do usuário, que pode sobrescrever). Default final de PRIV_CMD é sempre sudo.
  [[ -z "${AUR_HELPER:-}" ]] && AUR_HELPER="$(detect_aur_helper 2>/dev/null || true)"
  [[ -z "${PRIV_CMD:-}"   ]] && PRIV_CMD="$(detect_priv_cmd 2>/dev/null || printf sudo)"
  # Shim: quando o elevador não é sudo (ex.: doas), expõe `sudo` como alias para
  # $PRIV_CMD. Assim todos os steps continuam chamando `sudo <cmd>` (incluindo os
  # diagnósticos do doctor) sem refactor. doas/sudo-rs suportam `-n` como sudo.
  if [[ "$PRIV_CMD" != sudo ]]; then
    sudo() { "$PRIV_CMD" "$@"; }
  fi

  export ENABLE_CUSTOM_TOOLS LANG_OVERRIDE SNAPSHOT_TOOL MIRROR_TOOL MIN_FREE_GIB MIN_BOOT_FREE_MIB
  export SNAPSHOT_MIN_FREE_GIB SNAPSHOT_KEEP BACKUP_CONFIGS BACKUP_KEEP BACKUP_PATHS
  export BTRFS_SCRUB_MAX_DAYS BOOT_TIME_WARN_S DOCKER_INFO_TIMEOUT_S ORPHAN_CLEANUP_MAX_ROUNDS
  export AUTO_FIX_RUST_CVES AUTO_BTRFS_SCRUB REPORT_ON_FINISH ARCH_NEWS_CHECK IDE_EXT_CLIS NOTIFY_ON_FINISH OLLAMA_SELF_UPDATE MCP_AUTO_UPDATE
  export AUR_HELPER PRIV_CMD
  export GCLOUD_BIN COPILOT_BIN ADGUARD_BIN OPENCLAW_BIN DMS_PLUGINS_DIR
  export FULL_UPGRADE_REPO FULL_UPGRADE_UPDATE_CHANNEL
}

# ── Inspeção de configuração (--config / -c) ───────────────────────────────────
# Imprime: caminho do config, status, valores efetivos em uso, listas de ignore,
# locais de log/cache e um exemplo completo de config. Read-only; sai com 0.
# Requer load_config() já ter rodado (valores resolvidos/auto-detectados).

# Helper: imprime "  chave = valor" alinhado, valor vazio vira <auto>/<vazio>.
_cfg_kv() {
  local key="$1" val="$2" empty_label="${3:-<vazio>}"
  [[ -z "$val" ]] && val="${C_DIM}${empty_label}${C_RESET}"
  printf '  %s%-26s%s %s\n' "$C_CYAN" "$key" "$C_RESET" "$val"
}

# Imprime um exemplo completo de config. Prefere o arquivo config.example ao lado
# do projeto (instalação modular); cai para um heredoc embutido (standalone).
print_config_example() {
  local example=""
  if [[ -r "${FU_ROOT}/config.example" ]]; then
    example="${FU_ROOT}/config.example"
  elif [[ -r "${FU_CONFIG_DIR}/config.example" ]]; then
    example="${FU_CONFIG_DIR}/config.example"
  fi

  if [[ -n "$example" ]]; then
    cat "$example"
    return 0
  fi

  # Fallback embutido (build standalone não tem o arquivo ao lado).
  cat <<'EOF'
# full-upgrade — configuração do usuário
# Copie para ~/.config/full-upgrade/config e edite.
# É um arquivo bash sourced: use sintaxe shell (VAR=valor, arrays, etc).

# ── Idioma ── auto = detecta de $LANG | pt | en
LANG_OVERRIDE=auto

# ── Tools custom (steps.d/) ── 0 = só steps genéricos | 1 = habilita plugins
ENABLE_CUSTOM_TOOLS=0

# ── Snapshot pré-upgrade ── auto | snapper | timeshift | none
SNAPSHOT_TOOL=auto
SNAPSHOT_MIN_FREE_GIB=2
SNAPSHOT_KEEP=5

# ── Backup de configs críticas de /etc ──
BACKUP_CONFIGS=1
BACKUP_KEEP=5
# BACKUP_PATHS="/etc/pacman.conf /etc/pacman.d /etc/fstab /etc/mkinitcpio.conf /etc/systemd/system"

# ── Mirror refresh ── auto | reflector | rate-mirrors | none
MIRROR_TOOL=auto

# ── Helper AUR e elevador de privilégio (I3) ──
# Vazio = auto-detecta. AUR_HELPER: paru > yay > pikaur.
# PRIV_CMD: sudo > doas > sudo-rs > run0. Quando PRIV_CMD não é sudo, um shim
# faz todos os `sudo <cmd>` usarem o elevador configurado (doas/sudo-rs têm -n).
#AUR_HELPER=yay
#PRIV_CMD=doas

# ── Espaço mínimo livre ──
MIN_FREE_GIB=2
MIN_BOOT_FREE_MIB=200

# ── Limiares, timeouts e limites ──
BTRFS_SCRUB_MAX_DAYS=30
BOOT_TIME_WARN_S=60
DOCKER_INFO_TIMEOUT_S=5
ORPHAN_CLEANUP_MAX_ROUNDS=5

# ── Auto-remediação de CVEs de toolchain Rust (F7) ──
# 0 = só reporta (default). 1 = oferece aplicar rustup self update/update +
# cargo install-update quando a auditoria achar CVEs corrigíveis. A aplicação
# exige confirmação interativa ou --yes; nunca roda sob --mode doctor/--dry-run.
AUTO_FIX_RUST_CVES=0

# ── Auto-remediação de scrub btrfs (G1) ──
# 0 = só reporta (default). 1 = oferece iniciar `btrfs scrub start` quando o
# último scrub em / estiver ausente ou mais antigo que BTRFS_SCRUB_MAX_DAYS.
# Exige confirmação interativa ou --yes; nunca roda sob --mode doctor/--dry-run.
AUTO_BTRFS_SCRUB=0

# ── Relatório automático ao fim do run (G3) ──
# 0 = desliga (default). 1 = grava o relatório Markdown do run concluído em
# ~/.cache/system-upgrade/full-upgrade-<run_id>.md (mesmo conteúdo de --report).
REPORT_ON_FINISH=0

# ── Arch News pré-upgrade (I1) ──
# 1 = checa o feed RSS de Arch News antes das mutações e alerta (todo) sobre
# itens novos desde a última verificação. 0 = desliga.
ARCH_NEWS_CHECK=1

# ── Notificação desktop ao fim do run (I4) ──
# 1 = envia resumo (ok/warn/todo/fail/skip) via notify-send ao final, com
# urgência conforme o pior status. 0 = desliga (default).
NOTIFY_ON_FINISH=0

# ── MCP servers (H6) ──
# 0 = só doctor read-only (default). 1 = reservado para futura atualização
# automática de MCP servers npm/uvx; ainda não muta nesta versão.
MCP_AUTO_UPDATE=0

# ── Auto-update do Ollama (H2) ──
# 0 = só reporta a versão (default). 1 = reexecuta o instalador oficial
# (curl -fsSL https://ollama.com/install.sh | sh) no step "Atualizar Ollama".
OLLAMA_SELF_UPDATE=0

# ── Extensões de IDE (H3) ──
# Lista (separada por espaço) de CLIs VSCode-family cujas extensões atualizar.
# Vazio = autodetect (code cursor codium code-insiders vscodium).
IDE_EXT_CLIS=""

# ── Listas de ignore ──
FULL_UPGRADE_AUR_IGNORE=""
# Se Poetry fixa poetry-core, poetry-core entra no ignore efetivo automaticamente.
FULL_UPGRADE_PIP_USER_IGNORE=""

# ── Overrides de path (vazio = auto-detecta) ──
# GCLOUD_BIN="$HOME/google-cloud-sdk/bin/gcloud"
# COPILOT_BIN="$HOME/.local/bin/copilot"
# ADGUARD_BIN="/usr/local/bin/adguardvpn-cli"
# DMS_PLUGINS_DIR="$HOME/.config/DankMaterialShell/plugins"
# OPENCLAW_BIN="/usr/local/bin/openclaw"

# ── Auto-atualização do próprio full-upgrade ──
FULL_UPGRADE_REPO="bernardopg/full-upgrade"
FULL_UPGRADE_UPDATE_CHANNEL="release"
EOF
}

show_config() {
  local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/system-upgrade"

  printf '%s%sConfiguração do full-upgrade%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '%s%s%s\n' "$C_BOLD" "$(ui_hr "$HR_LIGHT")" "$C_RESET"

  # ── Caminhos ──
  printf '%sCaminhos%s\n' "$C_BOLD" "$C_RESET"
  if [[ -f "$FU_CONFIG_FILE" ]]; then
    _cfg_kv "config" "$FU_CONFIG_FILE ${C_GREEN}(${SYM_OK} carregado)${C_RESET}"
  else
    _cfg_kv "config" "$FU_CONFIG_FILE ${C_YELLOW}(${SYM_SKIP} não existe — usando defaults)${C_RESET}"
  fi
  _cfg_kv "steps.d (empacotado)" "${FU_ROOT}/steps.d"
  _cfg_kv "steps.d (usuário)" "${FU_CONFIG_DIR}/steps.d"
  _cfg_kv "logs/cache" "$cache_dir"
  printf '\n'

  # ── Valores efetivos em uso ──
  printf '%sValores efetivos em uso%s %s(config + defaults + auto-detecção)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  _cfg_kv "LANG_OVERRIDE" "$LANG_OVERRIDE"
  _cfg_kv "ENABLE_CUSTOM_TOOLS" "$ENABLE_CUSTOM_TOOLS"
  _cfg_kv "SNAPSHOT_TOOL" "$SNAPSHOT_TOOL"
  _cfg_kv "SNAPSHOT_MIN_FREE_GIB" "$SNAPSHOT_MIN_FREE_GIB"
  _cfg_kv "SNAPSHOT_KEEP" "$SNAPSHOT_KEEP"
  _cfg_kv "MIRROR_TOOL" "$MIRROR_TOOL"
  _cfg_kv "AUR_HELPER" "${AUR_HELPER:-(nenhum)}"
  _cfg_kv "PRIV_CMD" "${PRIV_CMD:-sudo}"
  _cfg_kv "MIN_FREE_GIB" "$MIN_FREE_GIB"
  _cfg_kv "MIN_BOOT_FREE_MIB" "$MIN_BOOT_FREE_MIB"
  _cfg_kv "BACKUP_CONFIGS" "$BACKUP_CONFIGS"
  _cfg_kv "BACKUP_KEEP" "$BACKUP_KEEP"
  _cfg_kv "BACKUP_PATHS" "$BACKUP_PATHS"
  _cfg_kv "BTRFS_SCRUB_MAX_DAYS" "$BTRFS_SCRUB_MAX_DAYS"
  _cfg_kv "BOOT_TIME_WARN_S" "$BOOT_TIME_WARN_S"
  _cfg_kv "DOCKER_INFO_TIMEOUT_S" "$DOCKER_INFO_TIMEOUT_S"
  _cfg_kv "ORPHAN_CLEANUP_MAX_ROUNDS" "$ORPHAN_CLEANUP_MAX_ROUNDS"
  _cfg_kv "AUTO_FIX_RUST_CVES" "$AUTO_FIX_RUST_CVES"
  _cfg_kv "AUTO_BTRFS_SCRUB" "$AUTO_BTRFS_SCRUB"
  _cfg_kv "REPORT_ON_FINISH" "$REPORT_ON_FINISH"
  _cfg_kv "ARCH_NEWS_CHECK" "$ARCH_NEWS_CHECK"
  _cfg_kv "NOTIFY_ON_FINISH" "$NOTIFY_ON_FINISH"
  _cfg_kv "MCP_AUTO_UPDATE" "$MCP_AUTO_UPDATE"
  _cfg_kv "OLLAMA_SELF_UPDATE" "$OLLAMA_SELF_UPDATE"
  _cfg_kv "IDE_EXT_CLIS" "${IDE_EXT_CLIS:-(autodetect)}"
  _cfg_kv "FULL_UPGRADE_REPO" "$FULL_UPGRADE_REPO"
  _cfg_kv "FULL_UPGRADE_UPDATE_CHANNEL" "$FULL_UPGRADE_UPDATE_CHANNEL"
  printf '\n'

  # ── Listas de ignore (env + config) ──
  printf '%sListas de ignore%s\n' "$C_BOLD" "$C_RESET"
  _cfg_kv "FULL_UPGRADE_AUR_IGNORE" "$FULL_UPGRADE_AUR_IGNORE" "<nenhum>"
  _cfg_kv "FULL_UPGRADE_PIP_USER_IGNORE" "$FULL_UPGRADE_PIP_USER_IGNORE" "<nenhum>"
  _cfg_kv "FULL_UPGRADE_SKIP" "$FULL_UPGRADE_SKIP" "<nenhum>"
  printf '\n'

  # ── Paths de tools (auto-detectados ou via override) ──
  printf '%sPaths de tools%s %s(vazio = não encontrado/desabilitado)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  _cfg_kv "GCLOUD_BIN" "$GCLOUD_BIN" "<não encontrado>"
  _cfg_kv "COPILOT_BIN" "$COPILOT_BIN" "<não encontrado>"
  _cfg_kv "ADGUARD_BIN" "$ADGUARD_BIN" "<não encontrado>"
  _cfg_kv "OPENCLAW_BIN" "$OPENCLAW_BIN" "<não encontrado>"
  _cfg_kv "DMS_PLUGINS_DIR" "$DMS_PLUGINS_DIR"
  printf '\n'

  # ── Config de exemplo ──
  printf '%sConfig de exemplo%s %s(copie para %s)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$FU_CONFIG_FILE" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$(ui_hr "$HR_LIGHT")" "$C_RESET"
  print_config_example
  printf '%s%s%s\n' "$C_DIM" "$(ui_hr "$HR_LIGHT")" "$C_RESET"

  # ── Dica ──
  printf '\n'
  if [[ -f "$FU_CONFIG_FILE" ]]; then
    printf '%sDica:%s edite %s para sobrescrever os valores acima.\n' \
      "$C_BOLD" "$C_RESET" "$FU_CONFIG_FILE"
  else
    printf '%sDica:%s crie o config copiando o exemplo:\n' "$C_BOLD" "$C_RESET"
    printf '  mkdir -p %s\n' "$FU_CONFIG_DIR"
    if [[ -r "${FU_ROOT}/config.example" ]]; then
      printf '  cp %s %s\n' "${FU_ROOT}/config.example" "$FU_CONFIG_FILE"
    else
      printf '  full-upgrade --config-example > %s\n' "$FU_CONFIG_FILE"
    fi
  fi
}

# Step custom só roda se: tools custom habilitados E a função foi carregada de steps.d/.
# Uso: custom_step_or_skip "Nome do step" funcao_impl
custom_step_or_skip() {
  local name="$1" fn="$2"
  if (( ${ENABLE_CUSTOM_TOOLS:-0} == 0 )); then
    step_skip "$name" "requer ENABLE_CUSTOM_TOOLS=1"
  elif ! declare -F "$fn" >/dev/null 2>&1; then
    step_skip "$name" "função ${fn} não carregada de steps.d/"
  else
    run_step "$name" "$fn"
  fi
}
