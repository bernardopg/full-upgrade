#!/usr/bin/env bats
# tests/lang_js.bats — helpers puros de steps/lang_js.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  # `npm_global_prefix` real chama `npm config get prefix` (I/O + ambiente);
  # nos testes substituímos por um stub que devolve um caminho do tmpdir.
  # Usamos _npm_prefix (não `prefix`) para não colidir com o `local prefix`
  # declarado dentro das funções testadas (evita shadowing).
  log() { :; }
}

@test "npm_global_writable: true quando lib/node_modules é gravável em \$HOME" {
  _npm_prefix="$BATS_TEST_TMPDIR/npm-home"
  mkdir -p "$_npm_prefix/lib/node_modules"
  npm_global_prefix() { printf '%s' "$_npm_prefix"; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_global_writable: false quando prefixo é root/pacman (não gravável)" {
  _npm_prefix="$BATS_TEST_TMPDIR/npm-root"
  mkdir -p "$_npm_prefix/lib/node_modules"
  chmod a-w "$_npm_prefix/lib/node_modules"
  npm_global_prefix() { printf '%s' "$_npm_prefix"; }
  run npm_global_writable
  [ "$status" -ne 0 ]
  chmod u+w "$_npm_prefix/lib/node_modules"
}

@test "npm_global_writable: prefixo vazio não bloqueia (retorna true)" {
  npm_global_prefix() { :; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_global_writable: sem lib/node_modules checa gravabilidade do próprio prefix" {
  _npm_prefix="$BATS_TEST_TMPDIR/npm-flat"
  mkdir -p "$_npm_prefix"
  npm_global_prefix() { printf '%s' "$_npm_prefix"; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_audit_prefix: prefixo /usr sinaliza conflito com pacman (RC_WARN)" {
  npm_global_prefix() { printf '%s' '/usr'; }
  run npm_audit_prefix
  [ "$status" -eq "$RC_WARN" ]
}

@test "npm_audit_prefix: prefixo em \$HOME é seguro (0)" {
  # npm_audit_prefix só inspeciona a string do prefixo (não testa o filesystem),
  # então um caminho /home/* literal basta — não precisa existir em disco.
  npm_global_prefix() { printf '%s' '/home/usuario/.npm-global'; }
  run npm_audit_prefix
  [ "$status" -eq 0 ]
}

@test "npm_allow_scripts_packages: extrai pacotes bloqueados pelo npm" {
  out="$(printf '%s\n' \
    'npm warn allow-scripts 2 packages have install scripts not yet covered by allowScripts:' \
    'npm warn allow-scripts   better-sqlite3@12.11.1 (install: prebuild-install || node-gyp rebuild --release)' \
    'npm warn allow-scripts   @scope/native-addon@1.2.3 (install: node-gyp rebuild)' \
    'npm warn allow-scripts' \
    'changed 2 packages in 1s' \
    | npm_allow_scripts_packages)"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ]
  [[ "$out" == *"better-sqlite3"* ]]
  [[ "$out" == *"@scope/native-addon"* ]]
}
