#!/usr/bin/env bats
# tests/mcp.bats — Doctor de servidores MCP (H6).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/mcp.sh"
  QUIET=0
  HOME="$(mktemp -d)"
}

teardown() {
  [[ -n "${HOME:-}" && -d "$HOME" ]] && rm -rf "$HOME"
}

# ── parse_mcp_claude_json ────────────────────────────────────────────────────

@test "claude: stdio global com binário" {
  mkdir -p "$HOME"
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"context7":{"command":["npx","-y","@context7/mcp"]}}}
JSON
  out="$(parse_mcp_claude_json "$HOME/.claude.json")"
  [[ "$out" == "context7"$'\t'"global"$'\t'"stdio:npx" ]]
}

@test "claude: servidor remoto (url) => remote" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"web-reader":{"url":"https://example.com/mcp"}}}
JSON
  out="$(parse_mcp_claude_json "$HOME/.claude.json")"
  [[ "$out" == *"remote"* ]]
}

@test "claude: global vence projeto na dedup por nome" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"dup":{"command":["global-bin"]}},"projects":{"/x":{"mcpServers":{"dup":{"command":["proj-bin"]}}}}}
JSON
  out="$(parse_mcp_claude_json "$HOME/.claude.json")"
  [ "$(printf '%s\n' "$out" | grep -c '^dup')" -eq 1 ]
  [[ "$out" == *"global-bin"* ]]
}

@test "claude: sem mcpServers => vazio" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{},"projects":{}}
JSON
  out="$(parse_mcp_claude_json "$HOME/.claude.json")"
  [ -z "$out" ]
}

@test "claude: arquivo inexistente => rc 1" {
  run parse_mcp_claude_json "$HOME/nao.json"
  [ "$status" -eq 1 ]
}

# ── parse_mcp_codex_names ────────────────────────────────────────────────────

@test "codex: extrai nomes de [mcp_servers.X]" {
  cat > "$HOME/config.toml" <<'TOML'
[mcp_servers.serena]
command = "uvx"

[mcp_servers.context7]
command = "npx"
TOML
  out="$(parse_mcp_codex_names "$HOME/config.toml" | sort | paste -sd,)"
  [ "$out" == "context7,serena" ]
}

@test "codex: ignora seções não-mcp" {
  cat > "$HOME/config.toml" <<'TOML'
[projects."/home"]
trust_level = "trusted"

[mcp_servers.foo]
command = "x"
TOML
  out="$(parse_mcp_codex_names "$HOME/config.toml")"
  [ "$out" == "foo" ]
}

# ── doctor_mcp_servers (agregador) ───────────────────────────────────────────

@test "doctor: sem fontes => mensagem de nenhuma fonte (RC 0)" {
  run doctor_mcp_servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma fonte MCP"* ]]
}

@test "doctor: claude + codex agregados e rotulados" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"shared":{"command":["npx"]},"only-c":{"command":["uvx"]}}}
JSON
  cat > "$HOME/config.toml" <<'TOML'
[mcp_servers.shared]
command = "npx"
[mcp_servers.only-x]
command = "node"
TOML
  cp "$HOME/config.toml" "$HOME/.codex/config.toml" 2>/dev/null || mkdir -p "$HOME/.codex" && cp "$HOME/config.toml" "$HOME/.codex/config.toml"
  run doctor_mcp_servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 servidor(es)"* ]]
  [[ "$output" == *"Claude: 2, Codex: 2"* ]]
  [[ "$output" == *"shared [claude, codex"* ]]
  [[ "$output" == *"only-c [claude"* ]]
  [[ "$output" == *"only-x [codex"* ]]
}
