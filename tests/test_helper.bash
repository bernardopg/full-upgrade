#!/usr/bin/env bash
# tests/test_helper.bash — carrega as libs num shell isolado para teste unitário.
# Usado pelos arquivos .bats via `load test_helper`.
# shellcheck shell=bash

# Raiz do projeto (tests/ fica um nível abaixo).
FU_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FU_ROOT="$FU_TEST_ROOT"
export FU_LIB="${FU_TEST_ROOT}/lib"

# Carrega apenas as libs de lógica pura, na ordem mínima de dependência:
#   globals (constantes/estado) -> ui (cores usadas por log) -> core -> catalog.
# NÃO carrega main/cli/json/sudo nem steps/* — esses têm efeitos colaterais
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
