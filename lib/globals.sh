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
SUDO_KEEPALIVE_PID=""
SUDO_KEEPALIVE_PID_FILE=""
SUDO_READY=0

# ── Listas de ignore (default público vazio; autor define via config) ──
FULL_UPGRADE_AUR_IGNORE="${FULL_UPGRADE_AUR_IGNORE:-}"
FULL_UPGRADE_PIP_USER_IGNORE="${FULL_UPGRADE_PIP_USER_IGNORE:-}"
FULL_UPGRADE_SKIP="${FULL_UPGRADE_SKIP:-}"   # nomes de steps separados por vírgula

HAS_FAIL=0
RC_WARN=10
RC_TODO=11

# ── PNPM no PATH (se usado) ──
PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
PNPM_BIN_HOME="${PNPM_BIN_HOME:-$PNPM_HOME/bin}"
[[ ":$PATH:" == *":$PNPM_BIN_HOME:"* ]] || PATH="$PNPM_BIN_HOME:$PATH"
[[ ":$PATH:" == *":$PNPM_HOME:"* ]] || PATH="$PNPM_HOME:$PATH"
export PNPM_HOME PNPM_BIN_HOME PATH FULL_UPGRADE_PIP_USER_IGNORE

# ── Log run-scoped (RUN_ID etc definidos após parse, em setup_logging) ──
RUN_ID=""
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
