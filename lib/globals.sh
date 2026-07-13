#!/usr/bin/env bash
# lib/globals.sh — variáveis globais de estado, paths de log, arrays de step.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck disable=SC2034  # globais cross-module
#
# NOTA: SCRIPT_VERSION / SCRIPT_PATH / SCRIPT_SHA256 são definidos pelo
# entrypoint (full-upgrade.sh) ANTES de sourcing este arquivo, pois dependem
# de BASH_SOURCE do entrypoint, não desta lib.

# Diretório-base do projeto (definido pelo entrypoint). Fallback defensivo.
: "${FU_ROOT:=}"

LOG_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/system-upgrade"
MAX_LOGS=20

# ── Flags de execução (default; sobrescritas por CLI/config) ──
ASSUME_YES=0
DEVEL_UPDATE=0
DRY_RUN=0
VERBOSE=0
QUIET=0
NO_REPAIR=0
NO_CLEANUP=0
RESTART_SERVICES=0
LIST_STEPS=0
JSON_SUMMARY=0
ONLY_CATEGORY=""
EXPLAIN_STEP=""
MODE=""
SHOW_VERSION=0
SHOW_CONFIG=0
DO_SELF_UPDATE=0
DO_REPORT=0
REPORT_FILE=""
REPORT_FROM=""
FAIL_FAST=0          # 1 = aborta o run no primeiro fail (os restantes viram skip)
RUN_ABORTED=0        # setado quando o fail-fast dispara; gate em run_step
DO_HISTORY=0
HISTORY_N=10
DO_AUDIT=0           # --audit: auditoria de segurança consolidada (read-only)
DO_RESUME=0          # --resume: re-roda só os steps não-ok do último run
RESUME_STEPS=""      # preenchido por --resume: nomes dos steps retomados
DO_DOCTOR_ACK_JOURNAL=0  # --doctor-ack-journal: grava assinaturas "unknown" do journal como ruído local

# ── Systray daemon (--tray) ──
TRAY_MODE=""         # start|enable|disable|status|check (via --tray [--subcmd])
TRAY_LAUNCH=0        # --tray-launch: roda full-upgrade num terminal (usado pelo applet)
TRAY_VIEW_LOG=0      # --tray-view-log: abre o último log
TRAY_LAUNCH_ARGS=()  # args extras repassados pelo --tray-launch (ex.: --mode doctor)
PKG_SNAP_BEFORE=""   # L3: snapshot pacman -Q antes do upgrade
PKG_SNAP_AFTER=""    # L3: snapshot pacman -Q no fim do run
SUDO_KEEPALIVE_PID=""
SUDO_KEEPALIVE_PID_FILE=""
SUDO_READY=0

# ── Listas de ignore (default público vazio; autor define via config) ──
FULL_UPGRADE_AUR_IGNORE="${FULL_UPGRADE_AUR_IGNORE:-}"
FULL_UPGRADE_PIP_USER_IGNORE="${FULL_UPGRADE_PIP_USER_IGNORE:-}"
FULL_UPGRADE_SKIP="${FULL_UPGRADE_SKIP:-}"   # nomes de steps separados por vírgula
FULL_UPGRADE_PACFILES_TODO_REPORTED=0         # evita duplicar TODO de pacfiles no mesmo run

HAS_FAIL=0
RC_WARN=10
RC_TODO=11

# ── Regex compartilhado de erros de rede transitórios (grep -E -i) ──
# Fonte única para run_network_cmd/_retry (core.sh) e o retry AUR (pacman.sh).
# Cobre libcurl/wget e também os erros do reqwest (paru/yay em Rust), que
# reportam "error sending request ... channel closed" quando o RPC do AUR
# corta a conexão — visto em runs reais contra https://aur.archlinux.org/rpc.
NETWORK_TRANSIENT_RE='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect|temporary failure|error sending request|channel closed|connection reset|operation timed out|request timed out|tls handshake|dns error|falha temporária|tempo de conexão esgotado'

# ── PNPM no PATH (se usado) ──
PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
PNPM_BIN_HOME="${PNPM_BIN_HOME:-$PNPM_HOME/bin}"
[[ ":$PATH:" == *":$PNPM_BIN_HOME:"* ]] || PATH="$PNPM_BIN_HOME:$PATH"
[[ ":$PATH:" == *":$PNPM_HOME:"* ]] || PATH="$PNPM_HOME:$PATH"
export PNPM_HOME PNPM_BIN_HOME PATH FULL_UPGRADE_PIP_USER_IGNORE

# ── PATH de usuário (launchers não-interativos) ──
# Runs disparados pelo applet systray (unit systemd --user) ou por cron herdam
# um PATH mínimo, sem os diretórios de tools instaladas no $HOME. Sem isso, os
# gates `has <cmd>` viram skip falso ("corepack não instalado", "cmd-ausente:
# gcloud") mesmo com tudo instalado. Prependa os diretórios padrão que existirem.
augment_user_path() {
    local d
    for d in \
        "$HOME/.dotnet/tools" \
        "$HOME/.ghcup/bin" \
        "$HOME/go/bin" \
        "$HOME/.cargo/bin" \
        "$HOME/.deno/bin" \
        "$HOME/.bun/bin" \
        "$HOME/google-cloud-sdk/bin" \
        "$HOME/.opencode/bin" \
        "${NPM_CONFIG_PREFIX:-$HOME/.npm-global}/bin" \
        "$HOME/.local/bin"; do
        [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
    done
    export PATH
    return 0
}
augment_user_path

# ── Log run-scoped (RUN_ID etc definidos após parse, em setup_logging) ──
RUN_ID=""
RUN_START_ISO=""
LOG_FILE=""
JSONL_FILE=""
SUDO_KEEPALIVE_PID_FILE=""
LATEST_LOG_LINK="${LOG_DIR}/latest.log"
LATEST_JSONL_LINK="${LOG_DIR}/latest.jsonl"

# ── Estado de tracking de steps ──
declare -a STEP_NAMES=()
declare -a STEP_RESULTS=()
declare -a STEP_TIMES=()
declare -a STEP_CATEGORIES=()   # NOVO: categoria por step (p/ resumo agrupado)
STEP_START=0
STEP_START_ISO=""
STEP_LAST_RC=0
STEP_REASON=""                  # motivo opcional p/ warn/todo/fail (gravado no JSONL)
TOTAL_START=$SECONDS
TOTAL_STEPS=0                    # NOVO: total efetivo (p/ barra de progresso)
REBOOT_RECOMMENDATION=""         # rodapé de resumo quando Doctor detectar reboot
LAST_SECTION_GROUP=""            # último cabeçalho de seção impresso ao vivo (output agrupado)
