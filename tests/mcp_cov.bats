#!/usr/bin/env bats
# tests/mcp_cov.bats — pins MCP atrás da última release, contagem por ação,
# alvos uvx sem distribuição, autofix do config.toml do Codex (sem arquivo, sem
# python3, backup falho, rollback) e o hub sem python3. HOME descartável; o
# plano por arquivo e o registry são funções falsas.

load test_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/mcp.sh"
  QUIET=0 STEP_REASON="" LOG_FILE=/dev/null
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.codex"
  echo '{}' > "$HOME/.claude.json"
}

# Plano falso: uma linha "nome<TAB>ação<TAB>dist<TAB>pin" por servidor.
_plan() { PLAN="$1"; mcp_update_plan() { [[ "$1" == claude ]] && printf '%b' "$PLAN"; return 0; }; }

@test "pins: npm com escopo e pypi atrás da última" {
  npm() { echo 2.0.0; }
  curl() { echo '{"info":{"version":"1.5.0"}}'; }
  timeout() { shift; "$@"; }
  run mcp_pin_outdated "npm:@scope/srv@1.0.0" "a,b"
  [[ "$output" == *"@scope/srv 1.0.0 → 2.0.0"* ]]
  run mcp_pin_outdated "npm:plain@1.0.0" "a"
  [[ "$output" == *"plain 1.0.0 → 2.0.0"* ]]
  run mcp_pin_outdated "pypi:markitdown-mcp==1.0.0" "c"
  [[ "$output" == *"markitdown-mcp 1.0.0 → 1.5.0"* ]]
  run mcp_pin_outdated "cargo:x@1" "d"
  [ -z "$output" ]
}

@test "update: nenhum servidor, todas as ações contadas e pins velhos viram TODO" {
  _plan ""
  run mcp_update_servers
  [[ "$output" == *"Nenhum servidor MCP a avaliar"* ]]
  _plan 'a\tfresh\t\tnpm:a@1\nb\tpinned\t\tnpm:b@1\nc\texternal\t\t\nd\tremote\t\t\n'
  mcp_pin_outdated() { echo "$2: $1 → novo"; }
  mcp_update_servers >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "2 server(s) MCP fixado(s) em versão antiga" ]
  run mcp_update_servers
  [[ "$output" == *"auto-fresh(npx): 1, pinned: 1, externo: 1, remoto: 1"* ]]
  [[ "$output" == *"versão fixada atrás da última release"* ]]
}

@test "update: uvx sem distribuição e limpeza ok com pins velhos" {
  has() { return 0; }
  mcp_pin_outdated() { :; }
  _plan 'u\trefresh\t\t\n'
  run mcp_update_servers
  [[ "$output" == *"sem nome de distribuição resolvível"* ]]
  _plan 'u\trefresh\tmarkitdown-mcp\tpypi:markitdown-mcp==1\n'
  mcp_pin_outdated() { echo "u: velho"; }
  uv() { return 0; }
  mcp_update_servers >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}

@test "codex autofix: sem arquivo, sem python3, backup falho e rollback" {
  run autofix_codex_mcp_toml
  [[ "$output" == *"ausente ou sem permissão de escrita"* ]]
  printf '[mcp_servers.x]\ncommand = "a"\n\n[mcp_servers.x]\ncommand = "a"\n' > "$HOME/.codex/config.toml"
  has() { [[ "$1" != python3 ]]; }
  run autofix_codex_mcp_toml
  [[ "$output" == *"python3 indisponível"* ]]
  unset -f has; source "${FU_LIB}/core.sh"
  cp() { return 1; }
  autofix_codex_mcp_toml >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "backup do config.toml do Codex falhou" ]
  unset -f cp; unset status
  # A remoção da duplicata "funciona", mas o arquivo segue inválido: rollback.
  printf 'lixo = = =\n[mcp_servers.x]\ncommand = "a"\n\n[mcp_servers.x]\ncommand = "a"\n' > "$HOME/.codex/config.toml"
  before="$(cat "$HOME/.codex/config.toml")"
  autofix_codex_mcp_toml >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "remoção de duplicata não corrigiu o config.toml do Codex" ]
  [ "$(cat "$HOME/.codex/config.toml")" = "$before" ]
}

@test "hub: sem python3 vira TODO" {
  touch "$BATS_TEST_TMPDIR/render.py" "$BATS_TEST_TMPDIR/hub.json"
  mcp_hub_renderer() { echo "$BATS_TEST_TMPDIR/render.py"; }
  mcp_hub_json() { echo "$BATS_TEST_TMPDIR/hub.json"; }
  has() { [[ "$1" != python3 ]]; }
  MCP_HUB_RENDER=1 mcp_render_hub >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "python3 ausente; hub MCP não renderizado" ]
}

# Regressão: com IFS=$'\t' o campo dist vazio de um server npx fixado colapsava
# e o pin ia parar em `dist` — o @playwright/mcp fixado nunca era comparado.
@test "update: pin de server npx sem dist chega à checagem do registry" {
  echo '{"mcpServers":{"pw":{"command":"npx","args":["-y","@playwright/mcp@0.0.30"]}}}' > "$HOME/.claude.json"
  mcp_pin_outdated() { echo "$2: $1"; }
  mcp_update_servers >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  run mcp_update_servers
  [[ "$output" == *"pw: npm:@playwright/mcp@0.0.30"* ]]
}
