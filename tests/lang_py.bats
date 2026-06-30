#!/usr/bin/env bats
# tests/lang_py.bats — helpers puros de steps/lang_py.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_py.sh"
}

@test "pip_user_effective_ignore: preserva ignores existentes normalizados" {
  run pip_user_effective_ignore "Foo_Bar chardet" ""
  [ "$status" -eq 0 ]
  [ "$output" = "foo-bar chardet" ]
}

@test "pip_user_effective_ignore: adiciona poetry-core quando Poetry fixa requisito" {
  run pip_user_effective_ignore "chardet" "poetry-core (==2.4.0)"
  [ "$status" -eq 0 ]
  [ "$output" = "chardet poetry-core" ]
}

@test "pip_user_effective_ignore: não duplica poetry-core" {
  run pip_user_effective_ignore "poetry_core chardet" "poetry-core (==2.4.0)"
  [ "$status" -eq 0 ]
  [ "$output" = "poetry-core chardet" ]
}

@test "pip_user_effective_ignore: não adiciona poetry-core sem requisito do Poetry" {
  run pip_user_effective_ignore "chardet" ""
  [ "$status" -eq 0 ]
  [ "$output" = "chardet" ]
}

# ── update_* (caminhos com mocks) ─────────────────────────────────────────────
@test "update_pipx: nada a atualizar => propaga rc" {
  log() { :; }; log_raw() { :; }
  pipx() { echo "No packages upgraded"; return 0; }
  run update_pipx
  [ "$status" -eq 0 ]
}

@test "update_pipx: pacotes atualizados => rc 0" {
  log() { :; }; log_raw() { :; }; remediation() { :; }
  pipx() { printf 'upgrading foo...\nfoo 1.0 -> 2.0\n'; return 0; }
  run update_pipx
  [ "$status" -eq 0 ]
}

@test "update_uv_self: propaga rc do uv" {
  uv() { echo "updated"; return 0; }
  run update_uv_self
  [ "$status" -eq 0 ]
}

@test "update_uv_python: sem versões gerenciadas => 0" {
  log() { :; }
  uv() { :; }   # lista vazia
  run update_uv_python
  [ "$status" -eq 0 ]
}

@test "update_uv_tools: nenhuma tool instalada => 0" {
  log() { :; }
  uv() { echo "No tools installed"; return 1; }
  run update_uv_tools
  [ "$status" -eq 0 ]
}

@test "update_uv_tools: sucesso => 0" {
  log() { :; }
  uv() { echo "upgraded"; return 0; }
  run update_uv_tools
  [ "$status" -eq 0 ]
}
