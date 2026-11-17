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
  # Sem isto o prefixo do Node real (nvm) da máquina de teste entraria na lista.
  NODE_PREFIX=""
  npm_node_install_prefix() { [[ -n "$NODE_PREFIX" ]] && printf '%s\n' "$NODE_PREFIX"; return 0; }
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
  # O logger pode quebrar a mensagem segundo COLUMNS; valida após colapsar o
  # whitespace para não tornar este teste dependente de testes anteriores de UI.
  local normalized
  normalized="$(tr '\n' ' ' <<< "$output" | tr -s ' ')"
  [[ "$normalized" == *"já coberto por 'Atualizar npm global'"* ]]
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

@test "npm secundário: prefixo do Node (nvm) entra quando difere do ativo" {
  # Cenário real: ~/.npmrc com prefix=~/.npm-global (ativo) e o npm/corepack
  # usados de fato no prefixo do nvm, que vem antes no PATH.
  NODE_PREFIX="${BATS_TEST_TMPDIR}/nvm-node"
  mkdir -p "${NODE_PREFIX}/lib/node_modules/npm"
  npm_global_prefix() { printf '%s' "$NPM_CONFIG_PREFIX"; }
  OUTDATED_JSON='{"npm":{"current":"12.0.2","latest":"12.2.2"}}'
  run update_npm_globals_secondary
  [ "$status" -eq 0 ]
  [[ "$output" == *"já coberto"* ]]
  grep -q -- "--prefix ${NODE_PREFIX} npm@12.2.2" "$INSTALL_ARGS"
}

@test "npm secundário: pacote duplicado nos dois prefixos gera aviso" {
  NODE_PREFIX="${BATS_TEST_TMPDIR}/nvm-node"
  mkdir -p "${NODE_PREFIX}/lib/node_modules/@openai/codex" "${NODE_PREFIX}/lib/node_modules/npm" \
    "${NPM_CONFIG_PREFIX}/lib/node_modules/@openai/codex" "${NPM_CONFIG_PREFIX}/lib/node_modules/npm"
  npm_global_prefix() { printf '%s' "$NPM_CONFIG_PREFIX"; }
  run update_npm_globals_secondary
  [ "$status" -eq 0 ]
  [[ "$(tr -s '[:space:]' ' ' <<<"$output")" == *"@openai/codex"*"só a cópia do primeiro diretório no PATH"* ]]
  [[ "$output" != *"npm corepack"* ]]
}

@test "npm secundário: rc pior entre prefixos prevalece (fail > ok)" {
  NODE_PREFIX="${BATS_TEST_TMPDIR}/nvm-node"
  mkdir -p "${NODE_PREFIX}/lib/node_modules"
  OUTDATED_JSON='{"x":{"latest":"2.0.0"}}'
  INSTALL_RC=1
  run update_npm_globals_secondary
  [ "$status" -eq 1 ]
}

@test "npm_node_install_prefix: alias default do nvm tem precedência" {
  unset -f npm_node_install_prefix
  source "${FU_LIB}/steps/lang_js.sh"
  NVM_DIR="${BATS_TEST_TMPDIR}/nvm"
  mkdir -p "${NVM_DIR}/alias" "${NVM_DIR}/versions/node/v24.22.3/lib/node_modules"
  printf '24.22.3\n' > "${NVM_DIR}/alias/default"
  run npm_node_install_prefix
  [ "$output" = "${NVM_DIR}/versions/node/v24.22.3" ]
}

@test "npm_node_install_prefix: Node do sistema (/usr) fica de fora" {
  unset -f npm_node_install_prefix
  source "${FU_LIB}/steps/lang_js.sh"
  NVM_DIR="${BATS_TEST_TMPDIR}/sem-nvm"
  node() { :; }
  command() { [[ "$1 $2" == "-v node" ]] && { printf '/usr/bin/node\n'; return 0; }; builtin command "$@"; }
  readlink() { printf '/usr/bin/node\n'; }
  run npm_node_install_prefix
  [ -z "$output" ]
}
