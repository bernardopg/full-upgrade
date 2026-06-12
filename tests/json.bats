#!/usr/bin/env bats
# tests/json.bats — escape JSON (lib/json.sh). Funções puras, sem mutação.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/json.sh"
}

@test "json_escape: string simples vira JSON válido" {
  run json_escape 'texto simples'
  [ "$status" -eq 0 ]
  [ "$output" = '"texto simples"' ]
}

@test "json_escape: aspas e backslash escapados" {
  result="$(json_escape 'a"b\c')"
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: newline, tab e CR escapados como sequências" {
  result="$(json_escape "$(printf 'l1\nl2\tcol\r')")"
  [[ "$result" == *'\n'* ]]
  [[ "$result" == *'\t'* ]]
  [[ "$result" == *'\r'* ]]
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: ESC ANSI (0x1b) não invalida o JSON" {
  # Regressão #18: reason com cor ANSI quebrava a linha do JSONL.
  result="$(json_escape "$(printf 'a\033[31mvermelho\033[0mb')")"
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: control chars diversos são removidos" {
  result="$(json_escape "$(printf 'a\001b\002c\037d')")"
  [ "$result" = '"abcd"' ]
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: UTF-8 multibyte passa intacto" {
  run json_escape 'ação ✔ ⚠ não'
  [ "$output" = '"ação ✔ ⚠ não"' ]
}
