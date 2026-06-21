#!/usr/bin/env bash
# lib/steps/mcp.sh — diagnóstico de servidores MCP (Model Context Protocol).
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module (STEP_REASON etc.)

# H6 — parser puro: extrai servidores MCP do ~/.claude.json (global + projetos),
# dedup por nome (global vence). Lê o path em $1; emite "nome<TAB>escopo<TAB>detalhe"
# onde escopo ∈ {global, project} e detalhe ∈ {"stdio:<binário>", "remote", "?"}.
parse_mcp_claude_json() {
  local f="$1"
  [[ -r "$f" ]] || return 1
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
seen = set()
def emit(name, scope, cfg):
    if name in seen:
        return
    seen.add(name)
    cmd = cfg.get("command")
    binary = ""
    if isinstance(cmd, list) and cmd:
        binary = cmd[0] or ""
    elif isinstance(cmd, str):
        binary = cmd.split()[0] if cmd else ""
    if binary:
        detail = "stdio:" + binary
    elif cfg.get("url") or cfg.get("endpoint"):
        detail = "remote"
    else:
        detail = "?"
    print(name + "\t" + scope + "\t" + detail)
for name in sorted((d.get("mcpServers") or {})):
    emit(name, "global", (d.get("mcpServers") or {})[name])
for path, pv in (d.get("projects") or {}).items():
    for name in sorted((pv.get("mcpServers") or {})):
        emit(name, "project", (pv.get("mcpServers") or {})[name])
' "$f" 2>/dev/null
}

# H6 — parser puro: extrai nomes de servidores MCP do config.toml do Codex
# (seções [mcp_servers.<nome>]). Lê o path em $1; emite um nome por linha.
parse_mcp_codex_names() {
  local f="$1"
  [[ -r "$f" ]] || return 1
  awk 'match($0, /^\[mcp_servers\.([A-Za-z0-9_.-]+)\]/, m) { print m[1] }' "$f" 2>/dev/null
}

# H6 — Doctor read-only: enumera servidores MCP configurados nas fontes conhecidas
# (hoje: Claude Code via ~/.claude.json, Codex via ~/.codex/config.toml). Lista
# cada servidor com escopo e binário/runtime (stdio:npx, stdio:uvx, remote...).
# Nunca muta nem falha o run; MCP_AUTO_UPDATE (default 0) é guardado p/ futuro
# passo mutating. Sem fontes => skip limpo.
doctor_mcp_servers() {
  local claude_json="${HOME}/.claude.json"
  local codex_toml="${HOME}/.codex/config.toml"
  local has_source=0

  local -A all=()        # name -> "detalhe"
  local -A src_claude=() # name -> 1
  local -A src_codex=()  # name -> 1

  # Claude (JSON): fonte primária, com escopo + binário.
  if [[ -r "$claude_json" ]]; then
    has_source=1
    local name scope detail
    while IFS=$'\t' read -r name scope detail; do
      [[ -n "$name" ]] || continue
      all["$name"]="$detail"
      src_claude["$name"]=1
    done < <(parse_mcp_claude_json "$claude_json")
  fi

  # Codex (TOML): só nomes (header de seção).
  if [[ -r "$codex_toml" ]]; then
    has_source=1
    local cname
    while IFS= read -r cname; do
      [[ -n "$cname" ]] || continue
      src_codex["$cname"]=1
      [[ -n "${all[$cname]:-}" ]] || all["$cname"]="stdio:? (codex)"
    done < <(parse_mcp_codex_names "$codex_toml")
  fi

  if (( has_source == 0 )); then
    log "  Nenhuma fonte MCP configurada (~/.claude.json / ~/.codex/config.toml)."
    return 0
  fi

  local n="${#all[@]}"
  if (( n == 0 )); then
    log "  Fontes MCP presentes, mas nenhum servidor configurado."
    return 0
  fi

  local nc=0 nx=0
  nc="${#src_claude[@]}"
  nx="${#src_codex[@]}"
  log "  MCP: ${n} servidor(es) distinto(s) — Claude: ${nc}, Codex: ${nx}."

  local sname sdetail srcs
  for sname in $(printf '%s\n' "${!all[@]}" | sort); do
    sdetail="${all[$sname]}"
    srcs=""
    [[ -n "${src_claude[$sname]:-}" ]] && srcs="claude"
    [[ -n "${src_codex[$sname]:-}" ]] && srcs="${srcs:+$srcs, }codex"
    log "    • ${sname} [${srcs}, ${sdetail}]"
  done
  log "  Remediação: mantenha runtimes (npx/uvx/node) atualizados; MCP_AUTO_UPDATE=${MCP_AUTO_UPDATE:-0} (auto-update ainda não implementado)."
  return 0
}
