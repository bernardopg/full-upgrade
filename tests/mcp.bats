#!/usr/bin/env bats
# tests/mcp.bats — Doctor de servidores MCP (H6).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/mcp.sh"
  # doctor_mcp_servers migrou para doctor/dev.sh (Série T4)
  source "${FU_LIB}/steps/doctor/dev.sh"
  QUIET=0
  HOME="$(mktemp -d)"
  XDG_CONFIG_HOME="$HOME/.config"
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

@test "codex entries: preserva remote e aponta env obrigatória ausente sem expor valor" {
  cat > "$HOME/config.toml" <<'TOML'
[mcp_servers.github]
url = "https://example.com/mcp"
bearer_token_env_var = "TEST_MCP_TOKEN_AUSENTE"
TOML
  out="$(parse_mcp_codex_entries "$HOME/config.toml")"
  [[ "$out" == "github"$'\t'"remote"$'\t'"env ausente: TEST_MCP_TOKEN_AUSENTE" ]]
}

@test "json entries: cobre OpenCode e hub central" {
  cat > "$HOME/opencode.json" <<'JSON'
{"mcp":{"local":{"type":"local","command":["npx","pkg"]},"remote":{"type":"remote","url":"https://example.com/mcp"}}}
JSON
  out="$(parse_mcp_json_entries "$HOME/opencode.json")"
  [[ "$out" == *"local"$'\t'"stdio:npx"* ]]
  [[ "$out" == *"remote"$'\t'"remote"* ]]
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

@test "doctor: problema de configuração MCP vira warning acionável" {
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'TOML'
[mcp_servers.github]
url = "https://example.com/mcp"
bearer_token_env_var = "TEST_MCP_TOKEN_AUSENTE"
TOML
  run doctor_mcp_servers
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"codex:github: env ausente: TEST_MCP_TOKEN_AUSENTE"* ]]
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
  [[ "$out" == "markitdown"$'\t'"pinned"$'\t'"markitdown-mcp"$'\t'"pypi:markitdown-mcp@0.0.1a4" ]]
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

@test "plan: JSON classifica comando array do OpenCode" {
  cat > "$HOME/open.json" <<'JSON'
{"mcp":{"md":{"enabled":true,"command":["uvx","markitdown-mcp"]}}}
JSON
  out="$(mcp_update_plan json "$HOME/open.json")"
  [[ "$out" == "md"$'\t'"refresh"$'\t'"markitdown-mcp" ]]
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

@test "update: mesmo nome em clientes diferentes não mascara runtime uvx" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"same":{"command":"npx","args":["pkg"]}}}
JSON
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'TOML'
[mcp_servers.same]
command = "uvx"
args = ["markitdown-mcp"]
TOML
  has() { return 0; }
  uv() { printf '%s\n' "$*" >> "$HOME/uv.calls"; return 0; }
  run mcp_update_servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"refresh(uvx): 1"* ]]
  grep -q 'cache clean markitdown-mcp' "$HOME/uv.calls"
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

@test "update: lock do cache uv ocupado por server ativo => RC 0 informativo (N2)" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"serena":{"command":"uvx","args":["--from","git+https://x/serena","serena"]}}}
JSON
  has() { return 0; }
  uv() { echo "error: Timeout (15s) when waiting for lock on .cache/uv/.lock, is another uv process running?" >&2; return 2; }
  run mcp_update_servers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cache uv em uso"* ]]
  [[ "$output" == *"não é falha"* ]]
  [[ "$output" == *"uv cache clean serena"* ]]
}

# ── mcp_uv_lock_busy (N2, puro) ───────────────────────────────────────────────

@test "lock_busy: timeout no lock => true" {
  run mcp_uv_lock_busy "error: Timeout (15s) when waiting for lock on .cache/uv/.lock"
  [ "$status" -eq 0 ]
}

@test "lock_busy: 'another uv process running' => true" {
  run mcp_uv_lock_busy "is another uv process running?"
  [ "$status" -eq 0 ]
}

@test "lock_busy: erro genérico (disco cheio) => false" {
  run mcp_uv_lock_busy "error: No space left on device"
  [ "$status" -ne 0 ]
}

@test "update: erro genérico do uv => RC_WARN" {
  cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers":{"md":{"command":"uvx","args":["markitdown-mcp"]}}}
JSON
  has() { return 0; }
  uv() { echo "error: disco cheio" >&2; return 1; }
  run mcp_update_servers
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"uv cache clean retornou erro"* ]]
}

# ── codex_toml_duplicate_tables / autofix_codex_mcp_toml ────────────────────
# Regressão: `headroom init codex` reanexa [mcp_servers.headroom_memory] no fim
# do config a cada atualização do headroom. O TOML fica inválido e o Codex
# perde TODOS os mcp_servers de uma vez (Doctor reportava "Codex: 0").

_write_codex_dup_identical() {
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'TOML'
model = "gpt-5"

[mcp_servers.headroom_memory]
args = [
    "-m",
    "headroom.memory.mcp_server",
]
command = "/usr/bin/python3"
startup_timeout_sec = 30

[mcp_servers.outro]
command = "npx"

# --- Headroom memory MCP (auto-injected) ---
[mcp_servers.headroom_memory]
command = "/usr/bin/python3"
args = ["-m", "headroom.memory.mcp_server"]
startup_timeout_sec = 30
# --- end Headroom memory ---
TOML
}

@test "codex dup: detecta duplicata e a reconhece como idêntica apesar do formato" {
  _write_codex_dup_identical
  run codex_toml_duplicate_tables "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  # nome<TAB>linha_original<TAB>início<TAB>fim<TAB>idêntica
  [[ "${lines[0]}" == "mcp_servers.headroom_memory	3	14	19	1" ]]
}

@test "codex dup: config válido não produz duplicata" {
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.a]\ncommand = "x"\n' > "$HOME/.codex/config.toml"
  run codex_toml_duplicate_tables "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  [ -z "${output//[[:space:]]/}" ]
}

@test "codex dup: [[array of tables]] repetido não é duplicata" {
  mkdir -p "$HOME/.codex"
  printf '[[hosts]]\nname = "a"\n\n[[hosts]]\nname = "b"\n' > "$HOME/.codex/config.toml"
  run codex_toml_duplicate_tables "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  # TOML válido: o autofix nem chega a inspecionar, mas o parser não pode
  # marcar [[x]] repetido como erro — é sintaxe legítima de array de tabelas.
  python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$HOME/.codex/config.toml"
}

@test "codex autofix: remove duplicata idêntica, preserva original e valida" {
  _write_codex_dup_identical
  run autofix_codex_mcp_toml
  [ "$status" -eq 0 ]
  [[ "$output" == *"válido novamente"* ]]
  # Arquivo volta a parsear com os dois servers distintos.
  run python3 -c 'import sys,tomllib; print(sorted((tomllib.load(open(sys.argv[1],"rb")).get("mcp_servers") or {})))' "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"headroom_memory"* ]]
  [[ "$output" == *"outro"* ]]
  # Backup do estado anterior fica ao lado.
  run bash -c 'ls "$HOME"/.codex/config.toml.bak-*-dupfix'
  [ "$status" -eq 0 ]
}

@test "codex autofix: duplicata divergente vira todo e não toca no arquivo" {
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.x]\ncommand = "a"\n\n[mcp_servers.x]\ncommand = "DIFERENTE"\n' \
    > "$HOME/.codex/config.toml"
  local before
  before="$(cat "$HOME/.codex/config.toml")"
  run autofix_codex_mcp_toml
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"DIVERGENTE"* ]]
  [[ "$(cat "$HOME/.codex/config.toml")" == "$before" ]]
}

@test "codex autofix: config já válido é no-op" {
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.a]\ncommand = "x"\n' > "$HOME/.codex/config.toml"
  run autofix_codex_mcp_toml
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a remediar"* ]]
}

@test "codex autofix: AUTO_FIX_CODEX_MCP=0 não mexe em config quebrado" {
  _write_codex_dup_identical
  local before
  before="$(cat "$HOME/.codex/config.toml")"
  AUTO_FIX_CODEX_MCP=0 run autofix_codex_mcp_toml
  [ "$status" -eq 0 ]
  [[ "$(cat "$HOME/.codex/config.toml")" == "$before" ]]
}

@test "codex autofix: TOML inválido por outra causa vira todo sem editar" {
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.a\ncommand = "x"\n' > "$HOME/.codex/config.toml"
  local before
  before="$(cat "$HOME/.codex/config.toml")"
  run autofix_codex_mcp_toml
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"sem tabela duplicada"* ]]
  [[ "$(cat "$HOME/.codex/config.toml")" == "$before" ]]
}

@test "mcp_pin_outdated: npm com escopo atrás da latest é reportado" {
  npm() { echo "0.0.82"; }
  run mcp_pin_outdated "npm:@playwright/mcp@0.0.81" "playwright"
  [ "$output" = "playwright: @playwright/mcp 0.0.81 → 0.0.82" ]
}

@test "mcp_pin_outdated: pin igual à latest não é reportado" {
  npm() { echo "3.0.0"; }
  run mcp_pin_outdated "npm:@browserbasehq/mcp@3.0.0" "browserbase"
  [ -z "$output" ]
}

@test "mcp_pin_outdated: pypi atrás da latest é reportado; rede fora = silêncio" {
  curl() { echo '{"info":{"version":"0.0.1a7"}}'; }
  run mcp_pin_outdated "pypi:markitdown-mcp@0.0.1a4" "markitdown"
  [ "$output" = "markitdown: markitdown-mcp 0.0.1a4 → 0.0.1a7" ]
  curl() { return 6; }
  run mcp_pin_outdated "pypi:markitdown-mcp==0.0.1a4" "markitdown"
  [ -z "$output" ]
}
