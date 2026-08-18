#!/usr/bin/env bats
# tests/npm_secondary_prefix.bats — update_npm_globals_secondary (H6).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  QUIET=0
  STEP_REASON=""
  NPM_CONFIG_PREFIX="${BATS_TEST_TMPDIR}/sec"
  mkdir -p "${NPM_CONFIG_PREFIX}/lib/node_modules"
  INSTALL_ARGS="${BATS_TEST_TMPDIR}/install.args"
  : >"$INSTALL_ARGS"
  INSTALL_RC=0
  INSTALL_OUT=""
  OUTDATED_JSON="{}"
  OUTDATED_TABLE=""
  # Prefixo ativo fictício (nvm) — difere do secundário por padrão.
  npm_global_prefix() { printf '/home/u/.nvm/versions/node/v24.19.0'; }
}

npm() {
  case "$1" in
    outdated)
      if [[ "$*" == *--json* ]]; then
        printf '%s' "$OUTDATED_JSON"
      else
        printf '%s\n' "$OUTDATED_TABLE"
      fi
      return 0
      ;;
    install)
      printf '%s\n' "$*" >>"$INSTALL_ARGS"
      printf '%s\n' "$INSTALL_OUT"
      return "$INSTALL_RC"
      ;;
  esac
  return 0
}

@test "npm secundário: prefixo ausente => rc 0" {
  NPM_CONFIG_PREFIX="${BATS_TEST_TMPDIR}/nao-existe"
  run update_npm_globals_secondary
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "npm secundário: igual ao prefixo ativo => rc 0 (já coberto)" {
  npm_global_prefix() { printf '%s' "$NPM_CONFIG_PREFIX"; }
  run update_npm_globals_secondary
  [ "$status" -eq 0 ]
  [[ "$output" == *"já coberto por 'Atualizar npm global'"* ]]
}

@test "npm secundário: sem pendentes => rc 0" {
  run update_npm_globals_secondary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem pacotes npm globais pendentes"* ]]
}

@test "npm secundário: desatualizado é instalado com --prefix e spec" {
  OUTDATED_JSON='{"codewhale": {"current": "0.9.8", "wanted": "0.9.9", "latest": "0.9.9"}}'
  OUTDATED_TABLE='codewhale  0.9.8  0.9.9  0.9.9  global'
  INSTALL_OUT='changed 1 package in 2s'
  run update_npm_globals_secondary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando npm global [${NPM_CONFIG_PREFIX}]: codewhale@0.9.9"* ]]
  [[ "$output" == *"Prefixo secundário ${NPM_CONFIG_PREFIX} atualizado"* ]]
  local args
  args="$(cat "$INSTALL_ARGS")"
  [[ "$args" == *"install -g --prefix ${NPM_CONFIG_PREFIX} codewhale@0.9.9"* ]]
}

@test "npm secundário: scripts bloqueados => RC_TODO + remediação" {
  OUTDATED_JSON='{"@moonshot-ai/kimi-code": {"current": "0.36.1", "latest": "0.37.1"}}'
  INSTALL_OUT='npm warn install-scripts 2 packages had install scripts blocked
npm warn install-scripts   @moonshot-ai/kimi-code@0.37.1 (postinstall: node scripts/postinstall.mjs)
npm warn install-scripts   node-pty@1.1.0 (install: node scripts/prebuild.js)'
  run update_npm_globals_secondary
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"bloqueou script(s) de install em: @moonshot-ai/kimi-code node-pty"* ]]
  [[ "$output" == *"allow-scripts"* ]]
}

@test "npm secundário: falha de install => rc 1" {
  OUTDATED_JSON='{"codewhale": {"current": "0.9.8", "latest": "0.9.9"}}'
  INSTALL_RC=1
  run update_npm_globals_secondary
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha final em pacote(s) npm"* ]]
}

@test "npm secundário: JSON ilegível => rc 1" {
  OUTDATED_JSON='não é json'
  OUTDATED_TABLE='codewhale  0.9.8  0.9.9'
  run update_npm_globals_secondary
  [ "$status" -eq 1 ]
  [[ "$output" == *"Não foi possível extrair"* ]]
}
