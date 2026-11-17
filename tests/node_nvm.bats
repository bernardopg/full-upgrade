#!/usr/bin/env bats
# tests/node_nvm.bats — update_node_nvm (nvm + Node.js do alias default).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  QUIET=0
  STEP_REASON=""
  NVM_DIR="${BATS_TEST_TMPDIR}/nvm"
  mkdir -p "$NVM_DIR"
  : > "${NVM_DIR}/nvm.sh"
  printf 'x\n' > "${NVM_DIR}/nvm.sh"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  : > "$CALLS"
  NVM_DEFAULT="v24.19.0"
  NVM_REMOTE_MAJOR="v24.22.3"
  NVM_REMOTE_LTS="v24.22.3"
  NVM_INSTALL_RC=0
  NPM_RC=0
  # Sem .git => a parte de auto-update do nvm é pulada nestes testes.
  _nvm() {
    printf 'nvm %s\n' "$*" >>"$CALLS"
    case "$1 ${2:-}" in
      "version default") printf '%s\n' "$NVM_DEFAULT" ;;
      "version-remote --lts") printf '%s\n' "$NVM_REMOTE_LTS" ;;
      version-remote*) printf '%s\n' "$NVM_REMOTE_MAJOR" ;;
      install*) mkdir -p "${NVM_DIR}/versions/node/$2/lib/node_modules"; return "$NVM_INSTALL_RC" ;;
    esac
    return 0
  }
  npm() { printf 'npm %s\n' "$*" >>"$CALLS"; return "$NPM_RC"; }
}

@test "node nvm: sem nvm.sh => rc 0" {
  rm -f "${NVM_DIR}/nvm.sh"
  run update_node_nvm
  [ "$status" -eq 0 ]
  [[ "$output" == *"nvm não encontrado"* ]]
}

@test "node nvm: default já é o último da major => não instala" {
  NVM_REMOTE_MAJOR="v24.19.0"
  run update_node_nvm
  [ "$status" -eq 0 ]
  [[ "$output" == *"já é o último v24.x"* ]]
  ! grep -q '^nvm install' "$CALLS"
}

@test "node nvm: patch novo instala, carrega globais do prefixo antigo e troca o default" {
  mkdir -p "${NVM_DIR}/versions/node/v24.19.0/lib/node_modules/"{npm,corepack,defuddle,@crowdin/cli}
  run update_node_nvm
  [ "$status" -eq 0 ]
  grep -q '^nvm install v24.22.3' "$CALLS"
  grep -q "^npm install -g --prefix ${NVM_DIR}/versions/node/v24.22.3 @crowdin/cli@latest defuddle@latest$" "$CALLS"
  grep -q '^nvm alias default 24.22.3' "$CALLS"
}

@test "node nvm: falha ao reinstalar globais vira TODO com o Node já trocado" {
  mkdir -p "${NVM_DIR}/versions/node/v24.19.0/lib/node_modules/defuddle"
  NPM_RC=1
  run update_node_nvm
  [ "$status" -eq "$RC_TODO" ]
  grep -q '^nvm alias default 24.22.3' "$CALLS"
}

@test "node nvm: install com rc != 0 por causa do prefix, mas Node extraído => segue" {
  NVM_INSTALL_RC=10
  mkdir -p "${NVM_DIR}/versions/node/v24.22.3/bin"
  printf '#!/bin/sh\necho v24.22.3\n' > "${NVM_DIR}/versions/node/v24.22.3/bin/node"
  chmod +x "${NVM_DIR}/versions/node/v24.22.3/bin/node"
  run update_node_nvm
  [ "$status" -eq 0 ]
  grep -q '^nvm alias default 24.22.3' "$CALLS"
}

@test "node nvm: nvm install falhou => fail, default intocado" {
  NVM_INSTALL_RC=3
  run update_node_nvm
  [ "$status" -eq 3 ]
  ! grep -q '^nvm alias' "$CALLS"
}

@test "node nvm: nova major LTS só é anunciada" {
  NVM_REMOTE_MAJOR="v24.19.0"
  NVM_REMOTE_LTS="v26.13.1"
  run update_node_nvm
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nova linha LTS disponível: v26.13.1"* ]]
  ! grep -q '^nvm install' "$CALLS"
}

@test "node nvm: consulta remota vazia => warn" {
  NVM_REMOTE_MAJOR="N/A"
  run update_node_nvm
  [ "$status" -eq "$RC_WARN" ]
}
