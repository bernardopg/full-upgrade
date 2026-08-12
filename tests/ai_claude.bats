#!/usr/bin/env bats
# tests/ai_claude.bats — varredura de binários truncados do instalador nativo do
# Claude Code (regressão: timeout do catálogo matava o download no meio e o stub
# de 0 byte fazia o updater considerar a versão "já instalada").

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  VERSIONS_DIR="$(mktemp -d)"
}

teardown() {
  [[ -n "${VERSIONS_DIR:-}" && -d "$VERSIONS_DIR" ]] && rm -rf "$VERSIONS_DIR"
}

@test "prune: remove binário de 0 byte (download interrompido)" {
  : > "${VERSIONS_DIR}/2.1.229"
  run claude_prune_partial_versions "$VERSIONS_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "${VERSIONS_DIR}/2.1.229" ]
}

@test "prune: remove arquivo não-vazio sem bit de execução" {
  printf 'parcial' > "${VERSIONS_DIR}/2.1.229"
  chmod 644 "${VERSIONS_DIR}/2.1.229"
  run claude_prune_partial_versions "$VERSIONS_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "${VERSIONS_DIR}/2.1.229" ]
}

@test "prune: preserva binário íntegro (não-vazio e executável)" {
  printf 'binario completo' > "${VERSIONS_DIR}/2.1.228"
  chmod 755 "${VERSIONS_DIR}/2.1.228"
  run claude_prune_partial_versions "$VERSIONS_DIR"
  [ "$status" -eq 0 ]
  [ -x "${VERSIONS_DIR}/2.1.228" ]
}

@test "prune: remove só o truncado e mantém o íntegro na mesma pasta" {
  printf 'binario completo' > "${VERSIONS_DIR}/2.1.228"
  chmod 755 "${VERSIONS_DIR}/2.1.228"
  : > "${VERSIONS_DIR}/2.1.229"
  run claude_prune_partial_versions "$VERSIONS_DIR"
  [ "$status" -eq 0 ]
  [ -x "${VERSIONS_DIR}/2.1.228" ]
  [ ! -e "${VERSIONS_DIR}/2.1.229" ]
}

@test "prune: diretório inexistente é no-op silencioso" {
  run claude_prune_partial_versions "${VERSIONS_DIR}/nao-existe"
  [ "$status" -eq 0 ]
}

@test "prune: diretório vazio é no-op" {
  run claude_prune_partial_versions "$VERSIONS_DIR"
  [ "$status" -eq 0 ]
}

@test "prune: ignora subdiretórios (só remove arquivos regulares)" {
  mkdir -p "${VERSIONS_DIR}/algum-dir"
  run claude_prune_partial_versions "$VERSIONS_DIR"
  [ "$status" -eq 0 ]
  [ -d "${VERSIONS_DIR}/algum-dir" ]
}

@test "catálogo: step do Claude Code tem timeout compatível com download de ~300 MB" {
  local timeout
  timeout="$(step_catalog | awk -F'|' '$1 == "Atualizar Claude Code CLI" {print $5}')"
  [ -n "$timeout" ]
  [ "$timeout" -ge 600 ]
}

@test "catálogo: step do Claude Code é marcado como slow" {
  local tags
  tags="$(step_catalog | awk -F'|' '$1 == "Atualizar Claude Code CLI" {print $3}')"
  [[ "$tags" == *slow* ]]
}
