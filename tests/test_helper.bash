#!/usr/bin/env bash
# tests/test_helper.bash — carrega as libs num shell isolado para teste unitário.
# Usado pelos arquivos .bats via `load test_helper`.
# shellcheck shell=bash

# Raiz do projeto (tests/ fica um nível abaixo).
FU_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FU_ROOT="$FU_TEST_ROOT"
export FU_LIB="${FU_TEST_ROOT}/lib"

# Neutraliza variáveis de contexto do git herdadas do processo pai. O hook
# pre-push roda sob `git push`, que exporta GIT_DIR (e afins) para o hook —
# sem o unset, os testes que criam repositórios temporários (DMS, helpers de
# plugin, realign) teriam suas chamadas `git` desviadas para o repositório
# REAL, falhando de forma determinística sob o hook e podendo tocar o índice
# do projeto. Mesma lista sanitizada em scripts/preflight.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

# Os diretórios XDG da sessão apontam para o HOME real: um teste que troca o
# HOME por um tmpdir ainda cairia em ~/.local/share, ~/.cache etc. (o step do
# Herdr achou o herdr-app de verdade). Sem eles, tudo deriva do HOME do teste,
# como no runner do CI.
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME

# Config, token do GitHub e o binário do pacote apontam para caminhos que não
# existem: sem isso o resultado dependia da máquina (o config real do usuário
# era carregado, o token dele era lido e o /usr/bin/full-upgrade do pacman
# mudava o caminho do --update). O CI não tem nada disso e media outra coisa.
_fu_isolated="${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/fu-isolado"
export FU_CONFIG_DIR="${_fu_isolated}/config" FU_CONFIG_FILE="${_fu_isolated}/config/config"
export GITHUB_TOKEN_FILE="${_fu_isolated}/github-token"
export FULL_UPGRADE_SYSTEM_BIN="${_fu_isolated}/usr-bin-full-upgrade"
export REPAIR_LOCAL_BIN_DIR="${_fu_isolated}/usr-local-bin"
unset _fu_isolated GITHUB_TOKEN GH_TOKEN

# Carrega libs compartilhadas, na ordem mínima do entrypoint:
#   globals -> ui -> core -> json -> catalog.
# NÃO carrega main/cli/sudo nem steps/* — esses podem ter efeitos colaterais
# (sudo, fork, I/O) que não queremos num teste unitário.
load_libs() {
  # Neutraliza I/O antes de sourcing (log/run_logged escrevem em $LOG_FILE).
  LOG_FILE="/dev/null"
  QUIET=1
  # Evita que a detecção de TTY/locale produza saída não-determinística.
  NO_COLOR=1
  # Largura fixa e larga: os testes de mensagem checam o TEXTO, não o layout, e
  # sem isso a quebra de linha do `log` (ui_wrap) partiria frases longas no meio
  # e faria o assert de conteúdo falhar. Quem testa layout (tests/ui.bats)
  # sobrescreve COLUMNS localmente.
  COLUMNS=200
  export LOG_FILE QUIET NO_COLOR COLUMNS

  # shellcheck source=/dev/null
  source "${FU_LIB}/globals.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/ui.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/core.sh"
  # json.sh vem antes de catalog.sh como no entrypoint: history.sh, report.sh e
  # tray.sh dependem de helpers dele (jsonl_is_dry_run), e sem carregá-lo aqui o
  # teste falha por "comando não encontrado" onde a produção funciona.
  # shellcheck source=/dev/null
  source "${FU_LIB}/json.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/catalog.sh"

  # Reafirma após globals.sh (que pode redefinir).
  LOG_FILE="/dev/null"
  QUIET=1
}

# Carregador específico para testes do healthcheck. Centraliza a ordem real de
# dependências (config antes do módulo) e evita que cada arquivo .bats replique
# sources que acabam divergindo do entrypoint.
load_healthcheck_libs() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/config.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/healthcheck.sh"
}

# J2 — valida que $1 é JSON e que a expressão Python $2 (com o objeto em `d`)
# é verdadeira. Falha o teste se o JSON for inválido ou a asserção for falsa.
assert_json() {
  local json="$1" expr="$2"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if not (eval(sys.argv[2], {"d": d})):
    sys.exit(1)
' "$json" "$expr"
}
