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
  export LOG_FILE QUIET NO_COLOR

  # shellcheck source=/dev/null
  source "${FU_LIB}/globals.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/ui.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/core.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/catalog.sh"

  # Reafirma após globals.sh (que pode redefinir).
  LOG_FILE="/dev/null"
  QUIET=1
}
