#!/usr/bin/env bats
# tests/lang_js_more_cov.bats — helpers do npm global (file: absoluto, links,
# reinstalação limpa), ramos finais do update npm, prefixos secundários, pnpm
# self-update e seus fallbacks, nvm por git (clone descartável) e bun/deno.
# PATH isolado; git real só em repositórios sob $BATS_TEST_TMPDIR.

load test_helper
load stub_helper

setup() {
  GIT_REAL="$(type -P git)"
  load_libs
  source "${FU_LIB}/steps/lang_js.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  set -o pipefail
}

# ── helpers do npm global ────────────────────────────────────────────────────

@test "file: absoluto no manifest bloqueia; vendor relativo e vazio não" {
  stub npm 0 '{"dependencies":{"x":"file:/home/dev/x"}}'
  run npm_manifest_has_local_file_deps foo@1
  [ "$status" -eq 0 ]
  stub npm 0 '{"dependencies":{"x":"file:./vendor/x"},"optionalDependencies":["a"]}'
  run npm_manifest_has_local_file_deps foo@1
  [ "$status" -eq 1 ]
  stub npm 0 ""
  run npm_manifest_has_local_file_deps foo@1
  [ "$status" -eq 1 ]
}

@test "links locais e reinstalação limpa" {
  stub npm 0 '{"dependencies":{"a":{"resolved":"file:../a"},"b":{"link":true},"c":{"resolved":"https://r"}}}'
  run npm_get_linked_packages
  [ "$output" = $'a\nb' ]
  stub npm 0 ""; : > "$STUB_LOG"
  cleanup_npm_global_tree() { echo limpou; }
  run npm_clean_reinstall_global_package foo foo@2
  [ "$status" -eq 0 ]
  [[ "$output" == *"reinstalacao limpa de foo"* ]]
  [ "$(stub_calls npm | tr '\n' '|')" = "uninstall -g foo|cache verify|install -g foo@2|" ]
}

# ── update_npm_globals: ramos finais ─────────────────────────────────────────

@test "npm globals: prefixo inválido falha; JSON ilegível falha; sucesso mantém o warn do prefixo" {
  npm_audit_prefix() { return 1; }
  run update_npm_globals
  [ "$status" -eq 1 ]
  npm_audit_prefix() { return "$RC_WARN"; }
  npm_global_writable() { return 0; }
  cleanup_npm_global_tree() { :; }
  npm_get_linked_packages() { :; }
  npm_manifest_has_local_file_deps() { return 1; }
  stub_script npm 'case "$*" in "outdated -g --depth=0 --json") echo "${OUTDATED:-}" ;; esac; exit 0'
  OUTDATED="lixo" run update_npm_globals
  [ "$status" -eq 1 ]
  [[ "$output" == *"Não foi possivel extrair lista"* ]]
  OUTDATED='{"foo":{"latest":"2.0.0"}}' run update_npm_globals
  [ "$status" -eq "$RC_WARN" ]
  npm_audit_prefix() { return 0; }
  OUTDATED='{"foo":{"latest":"2.0.0"}}' run update_npm_globals
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando npm global: foo@2.0.0"* ]]
}

@test "prefixos secundários: oculto ignorado, sem escrita pula, falha domina" {
  local sec="$BATS_TEST_TMPDIR/sec"
  mkdir -p "$sec/lib/node_modules/.cache" "$sec/lib/node_modules/pkg"
  [ "$(npm_prefix_packages "$sec")" = pkg ]
  chmod 555 "$sec/lib/node_modules"
  run _npm_update_secondary_prefix "$sec" "/outro"
  chmod 755 "$sec/lib/node_modules"
  [ "$status" -eq 0 ]
  [[ "$output" == *"não é gravável pelo usuário"* ]]
  npm_global_prefix() { echo /p; }
  npm_secondary_prefix_candidates() { printf '/a\n/b\n'; }
  _npm_update_secondary_prefix() { [[ "$1" == /b ]] && { STEP_REASON="b falhou"; return 1; }; return "$RC_WARN"; }
  update_npm_globals_secondary >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
}

# ── pnpm self-update ─────────────────────────────────────────────────────────

# pnpm: versão em $BATS_TEST_TMPDIR/pnpm.ver; self-update grava $SELF_VER e
# imprime $SELF_OUT com rc $SELF_RC.
_pnpm() {
  echo "$1" > "$BATS_TEST_TMPDIR/pnpm.ver"
  stub_script pnpm 'case "$1" in
  --version) cat "$BATS_TEST_TMPDIR/pnpm.ver" ;;
  self-update) [[ -n "${SELF_VER:-}" ]] && echo "$SELF_VER" > "$BATS_TEST_TMPDIR/pnpm.ver"; echo "${SELF_OUT:-}"; exit "${SELF_RC:-0}" ;;
esac'
  stub_script npm 'case "$1" in view) echo "${LATEST-11.0.0}" ;; install) echo "${FB_OUT:-}"; exit "${FB_RC:-0}" ;; esac'
}

@test "pnpm: registry indisponível, à frente do latest e atualizado" {
  _pnpm 10.0.0
  LATEST="" run update_pnpm_self
  [[ "$output" == *"não foi possível verificar versão mais recente"* ]]
  SELF_OUT="pnpm is newer than latest" SELF_RC=1 run update_pnpm_self
  [ "$status" -eq 0 ]
  [[ "$output" == *"à frente do registry latest=11.0.0"* ]]
  SELF_VER=11.0.0 run update_pnpm_self
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm atualizado: 10.0.0 → 11.0.0"* ]]
}

@test "pnpm: self-update falho sem projeto global, fallback sem rede e fallback sem efeito" {
  _pnpm 10.0.0
  pnpm_global_project_dir() { :; }
  SELF_OUT="ERR_PNPM_LOCKFILE" SELF_RC=7 run update_pnpm_self
  [ "$status" -eq 7 ]
  [[ "$output" == *"projeto global ativo não pôde ser localizado"* ]]
  pnpm_global_project_dir() { echo "$BATS_TEST_TMPDIR"; }
  SELF_RC=7 FB_RC=1 FB_OUT="npm error network request failed, reason: getaddrinfo EAI_AGAIN" run update_pnpm_self
  [ "$status" -eq "$RC_WARN" ]
  SELF_RC=7 FB_RC=0 run update_pnpm_self
  [ "$status" -eq 1 ]
}

# ── nvm ───────────────────────────────────────────────────────────────────────

@test "_nvm roda a função do nvm.sh num bash à parte" {
  export NVM_DIR="$BATS_TEST_TMPDIR/nvm"; mkdir -p "$NVM_DIR"
  echo 'nvm() { echo "nvm:$*"; }' > "$NVM_DIR/nvm.sh"
  [ "$(_nvm version default)" = "nvm:version default" ]
}

_nvm_repo() {
  ln -s "$GIT_REAL" "$STUB_SAFE/git"; hash -r
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
  export NVM_DIR="$BATS_TEST_TMPDIR/nvm"
  git init -q "$NVM_DIR"
  echo 'nvm() { :; }' > "$NVM_DIR/nvm.sh"
  git -C "$NVM_DIR" add nvm.sh; git -C "$NVM_DIR" commit -qm v1; git -C "$NVM_DIR" tag v0.1.0
  _nvm() { echo "${NVM_DEFAULT:-}"; }
}

@test "nvm git: alterações locais, fetch sem rede e fetch falho" {
  _nvm_repo
  echo sujo >> "$NVM_DIR/nvm.sh"
  run update_node_nvm
  [[ "$output" == *"tem alterações locais"* ]]
  [[ "$output" == *"nvm sem alias default instalado"* ]]
  git -C "$NVM_DIR" checkout -q nvm.sh
  run_network_cmd() { return "$RC_WARN"; }
  update_node_nvm >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "sem rede para atualizar o nvm" ]
  run_network_cmd() { echo "fatal: x"; return 128; }
  unset status
  update_node_nvm >/dev/null || status=$?
  [ "${status:-0}" -eq 128 ]
  [ "$STEP_REASON" = "git fetch do nvm falhou" ]
}

@test "nvm git: sobe para a tag nova, já atual e checkout impossível" {
  _nvm_repo
  run_network_cmd() { return 0; }
  echo 'nvm() { :; } # v2' > "$NVM_DIR/nvm.sh"; git -C "$NVM_DIR" commit -qam v2; git -C "$NVM_DIR" tag v0.2.0
  git -C "$NVM_DIR" checkout -q v0.1.0
  run update_node_nvm
  [[ "$output" == *"nvm: v0.1.0 → v0.2.0"* ]]
  run update_node_nvm
  [[ "$output" == *"nvm v0.2.0 já na versão mais recente"* ]]
  # Tag apontando para uma árvore (não um commit): o checkout falha.
  git -C "$NVM_DIR" tag v0.9.0 "$(git -C "$NVM_DIR" rev-parse 'HEAD^{tree}')"
  update_node_nvm >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "checkout do nvm v0.9.0 falhou" ]
}

# ── bun e deno ────────────────────────────────────────────────────────────────

@test "bun: binário do sistema, já na mais recente e upgrade falho" {
  stub bun 0 "1.2.0"
  chmod 555 "$STUB_BIN/bun"
  run update_bun
  [[ "$output" == *"não é gravável"* ]]
  chmod 755 "$STUB_BIN/bun"
  github_latest_release_version() { :; }
  with_updater_github_token() { "$@"; }
  stub_script bun 'case "$1" in --version) echo 1.2.0 ;; upgrade) echo "${BUN_OUT:-}"; exit "${BUN_RC:-0}" ;; esac'
  BUN_OUT="Congrats! You're already on the latest version of Bun" run update_bun
  [ "$status" -eq 0 ]
  [[ "$output" == *"bun já na versão mais recente."* ]]
  BUN_OUT="error: falhou" BUN_RC=4 run update_bun
  [ "$status" -eq 4 ]
}

@test "deno: binário do sistema e já na mais recente" {
  stub deno 0 "deno 2.1.0"
  chmod 555 "$STUB_BIN/deno"
  run update_deno
  [[ "$output" == *"não é gravável"* ]]
  chmod 755 "$STUB_BIN/deno"
  stub_script deno 'case "$1" in --version) echo "deno 2.1.0" ;; upgrade) echo "Local deno version 2.1.0 is the most recent release" ;; esac'
  run update_deno
  [ "$status" -eq 0 ]
  [[ "$output" == *"deno já na versão mais recente"* ]]
}
