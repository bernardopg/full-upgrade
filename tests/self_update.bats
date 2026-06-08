#!/usr/bin/env bats
# tests/self_update.bats — comparação de versão (função pura) do auto-update

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # self_update.sh não é carregado por load_libs (é um step); carrega aqui.
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/self_update.sh"
}

# ── _self_normalize_version ───────────────────────────────────────────────────

@test "normalize: remove prefixo v" {
  run _self_normalize_version "v3.0.4"
  [ "$output" = "3.0.4" ]
}

@test "normalize: corta sufixo de git describe" {
  run _self_normalize_version "3.0.3-2-gabc123"
  [ "$output" = "3.0.3" ]
}

@test "normalize: versão já limpa passa intacta" {
  run _self_normalize_version "3.0.4"
  [ "$output" = "3.0.4" ]
}

# ── self_version_compare (0=igual, 1=a>b, 2=a<b) ──────────────────────────────

@test "compare: versões iguais retornam 0" {
  run self_version_compare "3.0.4" "3.0.4"
  [ "$output" = "0" ]
}

@test "compare: a < b (patch) retorna 2" {
  run self_version_compare "3.0.3" "3.0.4"
  [ "$output" = "2" ]
}

@test "compare: a > b (patch) retorna 1" {
  run self_version_compare "3.0.4" "3.0.3"
  [ "$output" = "1" ]
}

@test "compare: ordenação numérica (3.0.10 > 3.0.3), não lexical" {
  run self_version_compare "3.0.10" "3.0.3"
  [ "$output" = "1" ]
}

@test "compare: minor maior vence patch" {
  run self_version_compare "3.1.0" "3.0.9"
  [ "$output" = "1" ]
}

@test "compare: major maior vence tudo" {
  run self_version_compare "4.0.0" "3.9.9"
  [ "$output" = "1" ]
}

@test "compare: prefixo v é ignorado em ambos os lados" {
  run self_version_compare "v3.0.3" "3.0.4"
  [ "$output" = "2" ]
}

@test "compare: sufixo git describe é ignorado" {
  run self_version_compare "3.0.4-5-gdeadbee" "3.0.4"
  [ "$output" = "0" ]
}

@test "compare: número de campos diferente (3.0 vs 3.0.1)" {
  run self_version_compare "3.0" "3.0.1"
  [ "$output" = "2" ]
}
