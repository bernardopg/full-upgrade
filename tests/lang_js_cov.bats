#!/usr/bin/env bats
# tests/lang_js_cov.bats — npm global: auditoria de prefixo, saneamento de
# links quebrados e o laço de update (link local, file:, script bloqueado,
# reinstalação limpa). `npm` é sempre stub; o prefixo vive em $BATS_TEST_TMPDIR.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"
  PREFIX="$HOME/.npm-global"
  mkdir -p "$PREFIX/lib/node_modules" "$PREFIX/bin"
  stub_script npm "case \"\$*\" in
    'config get prefix') echo '$PREFIX' ;;
    'root -g') echo '$PREFIX/lib/node_modules' ;;
    'outdated -g --depth=0 --json') cat \"\$NPM_OUTDATED_JSON\" 2>/dev/null ;;
    'outdated -g --depth=0') echo 'Package Current Latest' ;;
    install\\ -g\\ bad@*) echo 'npm error E404'; exit 1 ;;
    install\\ -g\\ native@*) echo 'npm warn install-scripts native@2.0.0 (postinstall)'; exit 0 ;;
    install\\ -g*) exit 0 ;;
  esac"
}

@test "npm_audit_prefix: /, /usr, HOME e caminho incomum" {
  npm_global_prefix() { echo /; }
  run npm_audit_prefix; [ "$status" -eq 1 ]
  npm_global_prefix() { echo /usr; }
  run npm_audit_prefix; [ "$status" -eq "$RC_WARN" ]
  npm_global_prefix() { echo "$HOME/.npm-global"; }
  run npm_audit_prefix; [ "$status" -eq 0 ]
  npm_global_prefix() { echo /srv/npm; }
  run npm_audit_prefix; [ "$status" -eq "$RC_WARN" ]
  npm_global_prefix() { echo ""; }
  run npm_audit_prefix; [ "$status" -eq 0 ]
}

@test "cleanup_npm_global_tree: remove link quebrado e mantém o válido" {
  touch "$PREFIX/lib/node_modules/real"
  ln -s "$PREFIX/lib/node_modules/real" "$PREFIX/bin/ok"
  ln -s "$PREFIX/lib/node_modules/sumiu" "$PREFIX/bin/quebrado"
  run cleanup_npm_global_tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"Links invalidos removidos do prefixo global do npm: 1"* ]]
  [ -L "$PREFIX/bin/ok" ] && [ ! -e "$PREFIX/bin/quebrado" ]
  run cleanup_npm_global_tree
  [[ "$output" == *"Sem links invalidos"* ]]
}

@test "cleanup_npm_global_tree: sem prefixo não faz nada" {
  npm_global_prefix() { echo ""; }; npm_global_root() { echo ""; }
  run cleanup_npm_global_tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado para saneamento"* ]]
}

@test "update_npm_globals: nada pendente => ok" {
  export NPM_OUTDATED_JSON="$BATS_TEST_TMPDIR/none.json"; echo '{}' > "$NPM_OUTDATED_JSON"
  run update_npm_globals
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem pacotes npm globais pendentes"* ]]
}

@test "update_npm_globals: link local, file:, script bloqueado e falha final" {
  export NPM_OUTDATED_JSON="$BATS_TEST_TMPDIR/out.json"
  printf '%s' '{"good":{"latest":"2.0.0"},"linked":{"latest":"1.1.0"},"filedep":{"latest":"3.0.0"},"native":{"latest":"2.0.0"},"bad":{"latest":"9.0.0"}}' > "$NPM_OUTDATED_JSON"
  npm_get_linked_packages() { echo linked; }
  npm_manifest_has_local_file_deps() { [[ "$1" == filedep@* ]]; }
  npm_clean_reinstall_global_package() { return 1; }
  update_npm_globals >/dev/null || status=$?
  [ "${status:-0}" -ne 0 ]
  grep -q "^npm install -g good@2.0.0" "$STUB_LOG"
  ! grep -q "install -g linked@" "$STUB_LOG"
  ! grep -q "install -g filedep@" "$STUB_LOG"
}

@test "update_npm_globals: prefixo do sistema (não gravável) pula sem falhar" {
  npm_global_writable() { return 1; }
  run update_npm_globals
  [ "$status" -eq 0 ]
  [[ "$output" == *"gerenciado pelo sistema"* ]]
}

@test "update_npm_globals: link e script bloqueado sem falha viram TODO" {
  export NPM_OUTDATED_JSON="$BATS_TEST_TMPDIR/out2.json"
  printf '%s' '{"linked":{"latest":"1.1.0"},"native":{"latest":"2.0.0"}}' > "$NPM_OUTDATED_JSON"
  npm_get_linked_packages() { echo linked; }
  npm_manifest_has_local_file_deps() { return 1; }
  update_npm_globals >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "1 pacote(s) linkado(s) + 1 com script bloqueado" ]
}

@test "update_pnpm_globals: remove dep file:, sem pacotes, ENOENT, rede e sucesso" {
  stub_script python 'exec python3 "$@"'
  stub_script pnpm 'case "$*" in
    "list -g --json") echo "{\"dependencies\":{\"local\":{\"resolved\":\"file:../x\"}}}" ;;
    "rm -g local") exit 0 ;;
    "-g update") printf "%s\n" "${PNPM_OUT:-Done in 1s}"; exit "${PNPM_RC:-0}" ;;
  esac'
  run update_pnpm_globals
  [ "$status" -eq 0 ]
  grep -q "^pnpm rm -g local" "$STUB_LOG"
  sleep() { :; }
  PNPM_RC=1 PNPM_OUT="No global packages found" run update_pnpm_globals
  [ "$status" -eq 0 ]
  PNPM_RC=1 PNPM_OUT="ENOENT: no such file, open 'x/package.json'" run update_pnpm_globals
  [ "$status" -eq 1 ]
  PNPM_RC=1 PNPM_OUT="getaddrinfo ENOTFOUND registry.npmjs.org" run update_pnpm_globals
  [ "$status" -eq "$RC_WARN" ]
  PNPM_RC=4 PNPM_OUT="outro" run update_pnpm_globals
  [ "$status" -eq 4 ]
}
