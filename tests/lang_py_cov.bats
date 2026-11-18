#!/usr/bin/env bats
# tests/lang_py_cov.bats — requisito do poetry-core e update do Poetry via pip
# --user. `python` é stub (nenhum pip real roda): devolve a lista de pacotes
# desatualizados e registra cada `pip install`.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/lang_py.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  # python -m pip list → $OUTDATED; python -c/- → Python real só para o parser.
  stub_script python 'if [[ "$1" == -m && "$2" == pip ]]; then
  case "$3" in list) echo "${OUTDATED:-[]}" ;; install) exit "${INSTALL_RC:-0}" ;; esac
  exit 0
fi
[[ "$1" == - ]] && { cat >/dev/null; echo "${CORE_REQ:-}"; exit 0; }
exec python3 "$@"'
}

@test "poetry_core_requirement entrega o script ao python por stdin" {
  CORE_REQ="poetry-core (>=2.0.0,<3.0.0)" run poetry_core_requirement
  [ "$output" = "poetry-core (>=2.0.0,<3.0.0)" ]
}

@test "update_poetry: já na última e sem poetry-core fixado" {
  run update_poetry
  [ "$status" -eq 0 ]
  [[ "$output" == *"Poetry ja está na versão mais recente"* ]]
  ! stub_calls python | grep -q "install"
}

@test "update_poetry: atualiza e garante o poetry-core; falha do install propaga" {
  OUTDATED='[{"name":"poetry","latest":"2.2.0"}]' CORE_REQ="poetry-core>=2.0" run update_poetry
  [ "$status" -eq 0 ]
  [[ "$output" == *"Garantindo poetry-core compatível com Poetry: poetry-core>=2.0"* ]]
  stub_calls python | grep -q -- "install --user --break-system-packages --upgrade poetry"
  stub_calls python | grep -q -- "install --user --break-system-packages poetry-core>=2.0"
  OUTDATED='[{"name":"poetry","latest":"2.2.0"}]' INSTALL_RC=3 run update_poetry
  [ "$status" -eq 3 ]
}
