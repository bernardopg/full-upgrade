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
FULL_UPGRADE_DISABLED_INTEGRATIONS="${FULL_UPGRADE_DISABLED_INTEGRATIONS:-}" # IDs estáveis, separados por vírgula
STALE_SERVICES_IGNORE="${STALE_SERVICES_IGNORE:-}" # units saciadas da auditoria de libs antigas (globs permitidos)
FULL_UPGRADE_PACFILES_TODO_REPORTED=0         # evita duplicar TODO de pacfiles no mesmo run

HAS_FAIL=0
RC_WARN=10
RC_TODO=11

# ── Regex compartilhado de erros de rede transitórios (grep -E -i) ──
# Fonte única para run_network_cmd/_retry (core.sh) e o retry AUR (pacman.sh).
# Cobre libcurl/wget e também os erros do reqwest (paru/yay em Rust), que
# reportam "error sending request ... channel closed" quando o RPC do AUR
# corta a conexão — visto em runs reais contra https://aur.archlinux.org/rpc.
# Inclui também os códigos crus do Node/undici (`fetch failed`, ENOTFOUND,
# ENETUNREACH…): as CLIs de IA em JS (pi, codex, gemini, qwen, cline, kimi) não
# traduzem o erro de socket, então sem esses tokens uma queda de rede era
# classificada como falha do updater em vez de aviso transitório.
# Inclui ainda as respostas HTTP que são transitórias POR DEFINIÇÃO — 429
# (rate limit) e 5xx de gateway/indisponibilidade: o servidor pede para tentar
# de novo mais tarde, e nada no full-upgrade pode "corrigir" o outro lado.
# Sem isto, um `hermes update` recusado pelo rate limit do GitHub
# ("RPC failed; HTTP 429 ... returned error: 429") era classificado como fail
# duro, tingindo de vermelho um run inteiro por uma condição que se resolve
# sozinha em minutos. Os 4xx permanentes (401/403/404) seguem em
# GIT_REMOTE_GONE_RE, que é avaliado ANTES deste nos steps de git.
NETWORK_TRANSIENT_RE='name or service not known|name resolution|could not resolve|could not reach|network is unreachable|no route to host|connection timed out|connection refused|failed to connect|temporary failure|error sending request|channel closed|connection reset|operation timed out|request timed out|tls handshake|dns error|falha temporária|tempo de conexão esgotado|fetch failed|socket hang up|enetunreach|eaddrnotavail|enotfound|eai_again|econnreset|econnrefused|etimedout|ehostunreach|rate limit|rate-limit|too many requests|returned error: 429|returned error: 50[0234]|http 429|http 50[0234]|status code 429|status code 50[0234]|service unavailable|bad gateway|gateway time-?out|secondary rate'

# ── Regex de upstream git PERMANENTEMENTE inacessível (grep -E -i) ──
# Terceira categoria de falha de fetch, entre "transitório" e "falha do tool".
# Repo deletado, tornado privado, renomeado sem redirect ou com credencial
# revogada NUNCA volta sozinho: reclassificar como fail duro fazia o step falhar
# em todo run, para sempre, sem nada que o full-upgrade pudesse fazer.
# Caso real: .repos/9fc715c3c021190e (github.com/TaylanTatli/dms-plugins, 404)
# quebrava o step "Atualizar plugins DankMaterialShell" em 100% dos runs.
# Isto é pendência do usuário (remover o clone órfão ou corrigir o remote), não
# erro operacional — por isso vira RC_TODO com instrução acionável, não fail.
GIT_REMOTE_GONE_RE='repository not found|not found: did you run git update-server-info|remote: not found|does not appear to be a git repository|could not read username|could not read password|authentication failed|permission denied \(publickey|access denied|requested url returned error: 40|returned error: 403|returned error: 404|http code = 40|repository is archived'

# Isola builds AUR de daemons/caches Gradle criados pelo Java padrão do usuário.
# PKGBUILDs que exigem outro JDK (ex.: 17 com host em 26) deixam de reutilizar
# bytecode incompatível, mantendo o cache persistente entre runs.
AUR_GRADLE_USER_HOME="${AUR_GRADLE_USER_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/full-upgrade/gradle-aur}"

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
declare -a STEP_REASONS=()      # motivo por step, alinhado aos arrays acima
STEP_START=0
STEP_START_ISO=""
STEP_LAST_RC=0
STEP_REASON=""                  # motivo opcional p/ warn/todo/fail (gravado no JSONL)
TOTAL_START=$SECONDS
TOTAL_STEPS=0                    # NOVO: total efetivo (p/ barra de progresso)
REBOOT_RECOMMENDATION=""         # rodapé de resumo quando Doctor detectar reboot

# ── Portão de conectividade dos steps com tag `network` ─────────────────────
# Um step de rede rodando sem rede não falha rápido: ele PENDURA até estourar o
# timeout do catálogo. Foi assim que o `Doctor: CVEs de pacotes oficiais
# (arch-audit)` — ~2s de trabalho real — queimou os 120s inteiros num run em que
# a rede havia caído. O portão troca esse minuto de espera cega por um aviso
# imediato, dizendo exatamente o que aconteceu.
NETWORK_GATE="${NETWORK_GATE:-1}"                  # 0 desliga o portão
NETWORK_GATE_HOST="${NETWORK_GATE_HOST:-archlinux.org}"  # nome resolvido na sonda
NETWORK_GATE_WAIT_S="${NETWORK_GATE_WAIT_S:-20}"   # espera máx. pela volta da rede
NETWORK_GATE_PROBE_TIMEOUT_S="${NETWORK_GATE_PROBE_TIMEOUT_S:-2}"  # teto de cada sonda
NETWORK_GATE_UP_TTL_S="${NETWORK_GATE_UP_TTL_S:-30}"     # validade do veredito "up"
AI_CLI_VERSION_TIMEOUT_S="${AI_CLI_VERSION_TIMEOUT_S:-5}" # teto individual do --version no Doctor
NETWORK_GATE_DOWN_TTL_S="${NETWORK_GATE_DOWN_TTL_S:-10}" # validade do veredito "down"
NETWORK_GATE_CACHE_STATE=""      # up|down|"" (sem veredito ainda)
NETWORK_GATE_CACHE_AT=0          # $SECONDS do último veredito
NETWORK_GATE_WAITED=0            # segundos esperados no último veredito "down"
LAST_SECTION_GROUP=""            # último cabeçalho de seção impresso ao vivo (output agrupado)
# Tipo do último bloco impresso no terminal: "" (nada), "section" (cabeçalho de
# grupo), "step" (step executado, com header + resultado) ou "skip". Serve só
# para espaçamento: o skip precisa de uma linha em branco quando vem depois de
# um step executado, mas uma sequência de skips (ex.: --dry-run, onde TODO step
# vira skip) tem que continuar compacta.
LAST_OUTPUT_KIND=""
COMPACT_SKIP_OUTPUT=0           # muitos skips: detalhes só no log/JSONL
