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

# ── update_claude_code: classificação de falhas ────────────────────────────────
# Regressão: o instalador nativo falha por rede com o erro cru do Node
# ("connect ECONNREFUSED", "fetch failed"). Antes o step devolvia o rc bruto do
# `claude update`, então uma queda de rede transitória marcava o run como FALHO
# — divergindo dos steps irmãos (opencode/pi/ollama), que reportam warn.

# Instala um `claude` stub num PATH próprio para o `command -v` do step achá-lo
# sem depender do claude real da máquina.
_stub_claude_on_path() {
  local bindir="${VERSIONS_DIR}/bin"
  mkdir -p "$bindir"
  printf '#!/bin/sh\nexit 0\n' > "${bindir}/claude"
  chmod +x "${bindir}/claude"
  PATH="${bindir}:${PATH}"
  CLAUDE_NATIVE_VERSIONS_DIR="${VERSIONS_DIR}/versions"
  QUIET=0            # sem isso o `log` só escreve no LOG_FILE e $output fica vazio
  STEP_REASON=""
}

@test "claude: falha de rede no update vira RC_WARN (não derruba o run)" {
  _stub_claude_on_path
  run_network_cmd() { printf 'Error: connect ECONNREFUSED 35.190.46.17:443\n'; return "$RC_WARN"; }
  run update_claude_code
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha de rede ao atualizar"* ]]
  [[ "$STEP_REASON" == *"rede indisponível"* ]] || true
}

@test "claude: falha não-rede no update vira RC_WARN (CLI antigo segue usável)" {
  _stub_claude_on_path
  run_network_cmd() { printf 'erro qualquer\n'; return 1; }
  run update_claude_code
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao atualizar (rc="* ]]
}

@test "claude: update bem-sucedido retorna 0" {
  _stub_claude_on_path
  run_network_cmd() { printf 'Already up to date\n'; return 0; }
  run update_claude_code
  [ "$status" -eq 0 ]
  [[ "$output" != *"falha"* ]]
}

@test "claude: symlink apontando p/ binário truncado vira RC_WARN acionável" {
  _stub_claude_on_path
  mkdir -p "$CLAUDE_NATIVE_VERSIONS_DIR"
  # Stub de 0 byte COM bit de execução: `command -v` ainda o resolve (é -x), mas
  # a varredura o remove por estar vazio — deixando o symlink pendurado, que é
  # exatamente o estado que o step precisa reportar.
  : > "${CLAUDE_NATIVE_VERSIONS_DIR}/2.1.231"
  chmod +x "${CLAUDE_NATIVE_VERSIONS_DIR}/2.1.231"
  ln -sf "${CLAUDE_NATIVE_VERSIONS_DIR}/2.1.231" "${VERSIONS_DIR}/bin/claude"
  run_network_cmd() { printf 'ok\n'; return 0; }
  run update_claude_code
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"incompleta"* ]]
}
