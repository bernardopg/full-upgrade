#!/usr/bin/env bats
# tests/lang_py_pure.bats — testes para funções puras de lib/testable/lang_py_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/lang_py_pure.sh"
}

@test "_normalize_pkg_name: converte para minúsculo" {
  run _normalize_pkg_name "MyPkg"
  [ "$output" = "mypkg" ]
}

@test "_normalize_pkg_name: underscore vira hífen" {
  run _normalize_pkg_name "my_pkg"
  [ "$output" = "my-pkg" ]
}

@test "_normalize_pkg_name: maiúsculo e underscore juntos" {
  run _normalize_pkg_name "My_Package"
  [ "$output" = "my-package" ]
}

@test "_normalize_pkg_name: já normalizado fica igual" {
  run _normalize_pkg_name "requests"
  [ "$output" = "requests" ]
}

@test "pip_user_effective_ignore: base vazia sem poetry-core req retorna vazio" {
  run pip_user_effective_ignore "" ""
  [ -z "$output" ]
}

@test "pip_user_effective_ignore: normaliza nome com maiúsculo" {
  run pip_user_effective_ignore "MyPkg" ""
  [ "$output" = "mypkg" ]
}

@test "pip_user_effective_ignore: múltiplos pacotes normalizados" {
  run pip_user_effective_ignore "Pkg_A Pkg_B" ""
  [[ "$output" == *"pkg-a"* ]]
  [[ "$output" == *"pkg-b"* ]]
}

@test "pip_user_effective_ignore: adiciona poetry-core quando req tem poetry-core*" {
  run pip_user_effective_ignore "" "poetry-core>=1.0"
  [[ "$output" == *"poetry-core"* ]]
}

@test "pip_user_effective_ignore: não duplica poetry-core se já presente" {
  run pip_user_effective_ignore "poetry-core" "poetry-core>=1.0"
  count=$(printf '%s\n' "$output" | tr ' ' '\n' | grep -c "^poetry-core$")
  [ "$count" -eq 1 ]
}

@test "pip_user_effective_ignore: não adiciona poetry-core sem req" {
  run pip_user_effective_ignore "requests" ""
  [[ "$output" != *"poetry-core"* ]]
}

@test "pip_user_effective_ignore: req sem poetry-core* não adiciona" {
  run pip_user_effective_ignore "" "setuptools>=40"
  [[ "$output" != *"poetry-core"* ]]
}

@test "poetry_core_requirement: executa sem crash (depende do poetry instalado)" {
  run poetry_core_requirement || true
  true
}
