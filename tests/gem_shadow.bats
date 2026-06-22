#!/usr/bin/env bats
# tests/gem_shadow.bats — N3: gems do usuário sombreando o sistema (Arch).
#
# gem_shadow_diff é puro (compara dois `gem list`). Os testes usam fixtures que
# imitam o formato real (incluindo entradas "default:").

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_other.sh"
}

# helper: grava $2... como linhas no arquivo $1
_mk() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }

@test "shadow: versão real divergente (rdoc) é sinalizada" {
  _mk "$BATS_TEST_TMPDIR/sys" 'rdoc (6.14.0)' 'json (default: 2.9.1)'
  _mk "$BATS_TEST_TMPDIR/usr" 'rdoc (7.2.0)' 'json (default: 2.9.1)'
  run gem_shadow_diff "$BATS_TEST_TMPDIR/sys" "$BATS_TEST_TMPDIR/usr"
  [ "$output" = "rdoc|6.14.0|7.2.0" ]
}

@test "shadow: gem default (sistema só default) é ignorada mesmo com user mais novo" {
  _mk "$BATS_TEST_TMPDIR/sys" 'bundler (default: 4.0.3)'
  _mk "$BATS_TEST_TMPDIR/usr" 'bundler (4.0.14, 4.0.13, default: 4.0.3)'
  run gem_shadow_diff "$BATS_TEST_TMPDIR/sys" "$BATS_TEST_TMPDIR/usr"
  [ -z "$output" ]
}

@test "shadow: mesma versão real => não sinaliza" {
  _mk "$BATS_TEST_TMPDIR/sys" 'nokogiri (1.16.0)'
  _mk "$BATS_TEST_TMPDIR/usr" 'nokogiri (1.16.0)'
  run gem_shadow_diff "$BATS_TEST_TMPDIR/sys" "$BATS_TEST_TMPDIR/usr"
  [ -z "$output" ]
}

@test "shadow: gem só no usuário (ausente no sistema) => não sinaliza" {
  _mk "$BATS_TEST_TMPDIR/sys" 'rdoc (6.14.0)'
  _mk "$BATS_TEST_TMPDIR/usr" 'rdoc (6.14.0)' 'rails (7.1.0)'
  run gem_shadow_diff "$BATS_TEST_TMPDIR/sys" "$BATS_TEST_TMPDIR/usr"
  [ -z "$output" ]
}

@test "shadow: usuário tem a do sistema + uma extra divergente => sinaliza" {
  _mk "$BATS_TEST_TMPDIR/sys" 'psych (5.2.2)'
  _mk "$BATS_TEST_TMPDIR/usr" 'psych (5.4.0, 5.2.2)'
  run gem_shadow_diff "$BATS_TEST_TMPDIR/sys" "$BATS_TEST_TMPDIR/usr"
  [ "$output" = "psych|5.2.2|5.4.0 5.2.2" ]
}

@test "shadow: arquivos inexistentes => vazio, rc 0" {
  run gem_shadow_diff "$BATS_TEST_TMPDIR/nope1" "$BATS_TEST_TMPDIR/nope2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "shadow: múltiplas gems divergentes, uma por linha" {
  _mk "$BATS_TEST_TMPDIR/sys" 'rdoc (6.14.0)' 'rake (13.0.0)' 'json (default: 2.9.1)'
  _mk "$BATS_TEST_TMPDIR/usr" 'rdoc (7.2.0)' 'rake (13.3.0)' 'json (default: 2.9.1)'
  run gem_shadow_diff "$BATS_TEST_TMPDIR/sys" "$BATS_TEST_TMPDIR/usr"
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"rdoc|6.14.0|7.2.0"* ]]
  [[ "$output" == *"rake|13.0.0|13.3.0"* ]]
}
