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
