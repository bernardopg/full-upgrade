#!/usr/bin/env bats
# tests/lang_py_more_cov.bats — pip --user sem nada pendente, Python do uv,
# unit do Headroom (help indisponível, flags compatíveis com upstream local
# fora, flag não suportada), versão do PyPI com e sem jq e uv tool falho.
# PATH isolado; arquivos de unit descartáveis.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/lang_py.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}

@test "pip --user: nada desatualizado sem lista de ignore" {
  stub_script python 'if [[ "$1 $2" == "-m pip" ]]; then echo "[]"; exit 0; fi; [[ "$1" == - ]] && { cat >/dev/null; exit 0; }; exec python3 "$@"'
  FULL_UPGRADE_PIP_USER_IGNORE="" run update_pip_user
  [[ "$output" == *"Sem pacotes pip --user desatualizados."* ]]
}

@test "uv python: deduplica minors e atualiza" {
  stub_script uv 'case "$1 $2" in
  "python list") printf "%s\n" "cpython-3.13.1-linux    /home/u/.local/share/uv/python/a" "cpython-3.13.2-linux    /home/u/.local/share/uv/python/b" "cpython-3.12.8-linux    /home/u/.local/share/uv/python/c" "pypy-3.10    /home/u/.local/share/uv/python/d" ;;
  "python upgrade") echo "upgrade $*" ;;
esac'
  run update_uv_python
  [ "$status" -eq 0 ]
  [[ "$output" == *"Versões Python uv instaladas: 3.13 3.12"* ]]
  [ "$(stub_calls uv | tail -1)" = "python upgrade 3.13 3.12" ]
}

@test "headroom: help indisponível, compatível com upstream fora e flag não suportada" {
  export HEADROOM_USER_UNIT="$BATS_TEST_TMPDIR/headroom.service"
  printf '[Service]\nExecStart=/usr/bin/headroom proxy --port 8787 --velha\n' > "$HEADROOM_USER_UNIT"
  stub headroom 1 ""
  check_headroom_unit_compat >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "não foi possível validar compatibilidade da unit Headroom" ]
  stub headroom 0 "--port"
  unset status
  check_headroom_unit_compat >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "unit Headroom incompatível com a CLI: --velha" ]
  stub headroom 0 "--port --velha"
  run check_headroom_unit_compat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ExecStart compatível"* ]]
  headroom_local_upstream_unavailable() { echo "--openai-url: destino local indisponível"; }
  unset status
  check_headroom_unit_compat >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "Headroom: --openai-url: destino local indisponível"* ]]
}

@test "pypi: versão com jq e sem jq" {
  stub curl 0 '{"info":{"name":"x","version":"1.2.3"},"urls":[]}'
  [ "$(pypi_latest_version x)" = 1.2.3 ]
  mv "$STUB_SAFE/jq" "$STUB_SAFE/jq.x"; hash -r
  [ "$(pypi_latest_version x)" = 1.2.3 ]
  mv "$STUB_SAFE/jq.x" "$STUB_SAFE/jq"; hash -r
}

@test "uv tools: falha real devolve o rc" {
  stub uv 4 "error: network"
  run update_uv_tools
  [ "$status" -eq 4 ]
}
