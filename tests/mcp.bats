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

@test "codex: ignora subtabelas env de servidores MCP" {
  cat > "$HOME/config.toml" <<'TOML'
[mcp_servers.notionApi]
command = "npx"

[mcp_servers.notionApi.env]
NOTION_TOKEN = "secret"

[mcp_servers."foo.bar"]
command = "uvx"
TOML
  out="$(parse_mcp_codex_names "$HOME/config.toml" | sort | paste -sd,)"
  [ "$out" == "foo.bar,notionApi" ]
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

# ── mcp_update_plan (K1) ─────────────────────────────────────────────────────

@test "plan: npx sem versão => fresh" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == "context7"$'\t'"fresh"$'\t' ]]
}

@test "plan: npx @latest => fresh (tag flutuante, não pin)" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"cdt":{"command":"npx","args":["chrome-devtools-mcp@latest"]}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == *$'\t'"fresh"$'\t'* ]]
}

@test "plan: uvx com versão fixa => pinned + dist" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"markitdown":{"command":"uvx","args":["markitdown-mcp@0.0.1a4"]}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == "markitdown"$'\t'"pinned"$'\t'"markitdown-mcp" ]]
}

@test "plan: uvx sem pin => refresh + dist" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"md":{"command":"uvx","args":["markitdown-mcp"]}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == "md"$'\t'"refresh"$'\t'"markitdown-mcp" ]]
}

@test "plan: uvx --from git => refresh, dist = nome da ferramenta" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"serena":{"command":"uvx","args":["--from","git+https://github.com/oraios/serena","serena","start-mcp-server"]}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == "serena"$'\t'"refresh"$'\t'"serena" ]]
}

@test "plan: comando direto (node/binário) => external" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"ct":{"command":"node","args":["/opt/ct/server.js"]},"gn":{"command":"gitnexus"}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == *"ct"$'\t'"external"$'\t'* ]]
  [[ "$out" == *"gn"$'\t'"external"$'\t'* ]]
}

@test "plan: url => remote" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"wr":{"url":"https://example.com/mcp"}}}
JSON
  out="$(mcp_update_plan claude "$HOME/.claude.json")"
  [[ "$out" == "wr"$'\t'"remote"$'\t' ]]
}

@test "plan: codex via toml classifica uvx/npx" {
  cat > "$HOME/cx.toml" <<'TOML'
[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
[mcp_servers.serena]
command = "uvx"
args = ["--from", "git+https://github.com/oraios/serena", "serena"]
TOML
  out="$(mcp_update_plan codex "$HOME/cx.toml")"
  [[ "$out" == *"context7"$'\t'"fresh"* ]]
  [[ "$out" == *"serena"$'\t'"refresh"$'\t'"serena"* ]]
}

# ── mcp_update_servers (K1) ──────────────────────────────────────────────────

@test "update: só npx => nada a refrescar, RC 0, não chama uv" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]}}}
JSON
  uv() { echo "NAO DEVERIA CHAMAR uv"; return 1; }
  export -f uv
  run mcp_update_servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nada a refrescar"* ]]
  [[ "$output" != *"NAO DEVERIA"* ]]
}

@test "update: uvx presente mas uv ausente => RC_TODO" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"md":{"command":"uvx","args":["markitdown-mcp"]}}}
JSON
  has() { [[ "$1" != uv ]]; }
  run mcp_update_servers
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"uv não instalado"* ]]
}

@test "update: uvx + uv disponível => limpa cache e RC 0" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"md":{"command":"uvx","args":["markitdown-mcp"]},"serena":{"command":"uvx","args":["--from","git+https://x/serena","serena"]}}}
JSON
  has() { return 0; }
  uv() { printf '%s\n' "uv $*" >> "$HOME/uv.calls"; return 0; }
  run mcp_update_servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cache uv refrescado"* ]]
  grep -q "cache clean" "$HOME/uv.calls"
  grep -q "markitdown-mcp" "$HOME/uv.calls"
  grep -q "serena" "$HOME/uv.calls"
}
