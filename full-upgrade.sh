#!/usr/bin/env bash
# full-upgrade.sh — orquestrador modular de upgrade para Arch Linux.
# Entrypoint fino: resolve o diretório do projeto, carrega lib/* na ordem de
# dependência, faz parse de flags e executa o fluxo.
#
# Uso: full-upgrade.sh [opções]   (veja --help)
# Repo: https://github.com/bernardopg/full-upgrade
set -uo pipefail

# ── Resolução do diretório do projeto ──────────────────────────────────────────
# Segue symlinks para achar a raiz real (suporta instalação via symlink em ~/.local/bin).
_self="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
FU_ROOT="$(cd -- "$(dirname -- "$_self")" && pwd)"
FU_LIB="${FU_ROOT}/lib"
export FU_ROOT FU_LIB

if [[ ! -d "$FU_LIB" ]]; then
  printf 'full-upgrade: diretório lib/ não encontrado em %s\n' "$FU_ROOT" >&2
  printf 'O script precisa do diretório lib/ ao lado dele (ou via symlink resolvido).\n' >&2
  exit 1
fi

# ── Metadados do script (dependem deste arquivo, não das libs) ──────────────────
# Resolução de versão, em ordem de prioridade:
#   1. git describe (rodando a partir de um clone do repo, durante o dev);
#   2. arquivo VERSION ao lado do entrypoint (gravado por install.sh/build.sh);
#   3. fallback embutido (último recurso).
SCRIPT_VERSION="3.29.0"
_git_ver="$(git -C "$FU_ROOT" describe --tags --always 2>/dev/null || true)"
if [[ "$_git_ver" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
  SCRIPT_VERSION="${_git_ver#v}"
elif [[ -r "${FU_ROOT}/VERSION" ]]; then
  _file_ver="$(tr -d '[:space:]' < "${FU_ROOT}/VERSION" 2>/dev/null || true)"
  [[ -n "$_file_ver" ]] && SCRIPT_VERSION="$_file_ver"
  unset _file_ver
fi
unset _git_ver
SCRIPT_SHA256="$(sha256sum "$_self" 2>/dev/null | awk '{print $1}' || printf 'unknown')"
SCRIPT_PATH="$_self"
export SCRIPT_VERSION SCRIPT_SHA256 SCRIPT_PATH

# ── Carregamento das libs na ordem de dependência ───────────────────────────────
# shellcheck source=lib/globals.sh
source "${FU_LIB}/globals.sh"
# shellcheck source=lib/ui.sh
source "${FU_LIB}/ui.sh"
# shellcheck source=lib/core.sh
source "${FU_LIB}/core.sh"
# shellcheck source=lib/json.sh
source "${FU_LIB}/json.sh"
# shellcheck source=lib/sudo.sh
source "${FU_LIB}/sudo.sh"
# shellcheck source=lib/config.sh
source "${FU_LIB}/config.sh"
# shellcheck source=lib/catalog.sh
source "${FU_LIB}/catalog.sh"
# shellcheck source=lib/cli.sh
source "${FU_LIB}/cli.sh"
# shellcheck source=lib/report.sh
source "${FU_LIB}/report.sh"
# shellcheck source=lib/history.sh
source "${FU_LIB}/history.sh"
# shellcheck source=lib/notify.sh
source "${FU_LIB}/notify.sh"
# shellcheck source=lib/tray.sh
source "${FU_LIB}/tray.sh"

# Implementações de steps (ordem não importa — só definições de função).
for _m in "${FU_LIB}"/steps/*.sh; do
  [[ -e "$_m" ]] || continue
  # shellcheck source=/dev/null
  source "$_m"
done
unset _m

# lib/main.sh por último (usa tudo acima).
# shellcheck source=lib/main.sh
source "${FU_LIB}/main.sh"

# ── Fluxo principal ─────────────────────────────────────────────────────────────
load_config                       # lib/config.sh — carrega ~/.config/full-upgrade/config
parse_args "$@"                   # lib/cli.sh
apply_mode_and_early_exits        # lib/cli.sh — resolve --list-steps/--explain-step/--mode

# Integrações empacotadas (steps.d/ ao lado do projeto) são SEMPRE carregadas —
# são código vetado do repositório e os steps decidem rodar por presença da
# ferramenta (cmd_deps do catálogo + checagem interna), como qualquer step core.
# Plugins do USUÁRIO (~/.config/full-upgrade/steps.d/) só são carregados com
# ENABLE_CUSTOM_TOOLS=1, pois são código arbitrário fora do controle do projeto.
# Ordem: empacotados primeiro, usuário por último — a última definição vence,
# então a customização do usuário sobrescreve a versão empacotada.
for _p in "${FU_ROOT}"/steps.d/*.sh; do
  [[ -e "$_p" ]] || continue
  # shellcheck source=/dev/null
  source "$_p"
done
if (( ${ENABLE_CUSTOM_TOOLS:-0} )); then
  for _p in "${FU_CONFIG_DIR}"/steps.d/*.sh; do
    [[ -e "$_p" ]] || continue
    # shellcheck source=/dev/null
    source "$_p"
  done
fi
unset _p

TOTAL_STEPS="$(count_effective_steps)"   # lib/catalog.sh — total p/ barra de progresso
export TOTAL_STEPS

setup_logging                     # lib/json.sh — define RUN_ID/LOG_FILE, rotaciona, abre run
print_banner                      # lib/main.sh
run_all_steps                     # lib/main.sh
finalize                          # lib/main.sh
