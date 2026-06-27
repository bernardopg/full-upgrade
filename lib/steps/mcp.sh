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
  python3 -c '
import sys
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        data = tomllib.load(fh)
except Exception:
    sys.exit(0)
servers = data.get("mcp_servers") or {}
if isinstance(servers, dict):
    for name in sorted(servers):
        print(name)
' "$f" 2>/dev/null
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
  if (( ${MCP_AUTO_UPDATE:-0} == 1 )); then
    log "  Remediação: MCP_AUTO_UPDATE=1 — o step 'Atualizar servidores MCP' refresca os runtimes uvx."
  else
    log "  Remediação: mantenha runtimes (npx/uvx/node) atualizados; MCP_AUTO_UPDATE=0 (ligue p/ refrescar uvx automaticamente)."
  fi
  return 0
}

# K1 — planner puro de atualização de servidores MCP. Lê uma fonte ($2) de um
# tipo conhecido ($1 ∈ {claude, codex}) e classifica cada servidor numa ação:
#   fresh    — runtime npx/bunx/pnpm dlx sem versão fixa (resolve a última a cada
#              invocação) → nada a fazer.
#   refresh  — runtime uvx (ambiente em cache) sem pin, ou origem git (HEAD anda)
#              → `uv cache clean <dist>` força rebuild da última no próximo launch.
#   pinned   — versão explícita (pkg@1.2.3 / ==/>=) → não dá pra subir com segurança.
#   external — comando direto (binário global, node, script) → atualiza pela
#              própria toolchain (ex.: npm global, cargo, pipx).
#   remote   — servidor HTTP/SSE/url → sem atualização local.
# Emite "nome<TAB>ação<TAB>dist" (dist = nome p/ `uv cache clean`, só em refresh).
# claude: dedup global>projeto. codex: nomes de [mcp_servers.<nome>].
mcp_update_plan() {
  local kind="$1" f="$2"
  [[ -r "$f" ]] || return 1
  python3 -c '
import sys, os, re, json
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib
kind, path = sys.argv[1], sys.argv[2]

NPX = {"npx", "bunx", "pnpx", "npm", "pnpm", "yarn"}
UVX = {"uvx", "uv"}
UVX_VALUE_FLAGS = {"--from", "--with", "--with-requirements", "--python", "-p",
                   "--index", "--index-url", "--extra-index-url", "--constraint", "-c"}
NPX_VALUE_FLAGS = {"-p", "--package", "-c", "--call"}

def is_pinned(tok):
    if not tok or tok.startswith(("git+", "http://", "https://", "file:", ".", "/")):
        return False
    rest = tok.split("/", 1)[1] if tok.startswith("@") else tok  # tira escopo @scope/
    return bool(re.search(r"@\d", rest)) or any(op in rest for op in ("==", ">=", "<=", "~=", "!="))

def distname(tok):
    if not tok or tok.startswith(("git+", "http://", "https://", "file:", ".", "/")):
        return ""
    return re.split(r"[@=<>~!]", tok)[0].strip()

def classify(cfg):
    cmd = cfg.get("command")
    extra = cfg.get("args") or []
    if isinstance(cmd, list):
        parts = list(cmd) + list(extra)
    elif isinstance(cmd, str) and cmd:
        parts = [cmd] + list(extra)
    else:
        parts = list(extra)
    if not parts:
        url = cfg.get("url") or cfg.get("endpoint") or cfg.get("serverUrl")
        if url or cfg.get("type") in ("http", "sse", "streamable-http"):
            return ("remote", "")
        return ("external", "")
    base = os.path.basename(parts[0])
    rest = parts[1:]
    if base in NPX:
        pkg = None
        i = 0
        while i < len(rest):
            a = rest[i]
            if a in NPX_VALUE_FLAGS:
                i += 2; continue
            if a in ("dlx", "exec", "run"):
                i += 1; continue
            if a.startswith("-"):
                i += 1; continue
            pkg = a; break
        if not pkg:
            return ("fresh", "")
        return ("pinned", "") if is_pinned(pkg) else ("fresh", "")
    if base in UVX:
        src = None; tool = None; i = 0
        while i < len(rest):
            a = rest[i]
            if a in UVX_VALUE_FLAGS:
                if a == "--from" and i + 1 < len(rest):
                    src = rest[i + 1]
                i += 2; continue
            if a.startswith("-"):
                i += 1; continue
            tool = a; break
        spec = src if src else tool
        if not spec:
            return ("external", "")
        if src and src.startswith("git+"):
            dist = distname(tool) or (tool or "")
        elif src:
            dist = distname(src)
        else:
            dist = distname(tool)
        if src and src.startswith("git+"):
            return ("refresh", dist)
        if is_pinned(spec):
            return ("pinned", dist)
        return ("refresh", dist)
    return ("external", "")

def emit(name, cfg, seen):
    if name in seen:
        return
    seen.add(name)
    action, dist = classify(cfg)
    print(name + "\t" + action + "\t" + dist)

seen = set()
if kind == "claude":
    try:
        d = json.load(open(path))
    except Exception:
        sys.exit(0)
    for name in sorted((d.get("mcpServers") or {})):
        emit(name, (d.get("mcpServers") or {})[name], seen)
    for _p, pv in (d.get("projects") or {}).items():
        for name in sorted((pv.get("mcpServers") or {})):
            emit(name, (pv.get("mcpServers") or {})[name], seen)
elif kind == "codex":
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except Exception:
        sys.exit(0)
    servers = data.get("mcp_servers") or {}
    if isinstance(servers, dict):
        for name in sorted(servers):
            cfg = servers[name]
            if isinstance(cfg, dict):
                emit(name, cfg, seen)
' "$kind" "$f" 2>/dev/null
}

# N2 — true (rc 0) se a saída do `uv cache clean` ($1) indica que o lock global
# de ~/.cache/uv está ocupado por um server uvx ativo. Esse é o caso ESPERADO num
# upgrade conduzido por agente: a própria sessão (Claude/Codex) mantém o serena
# uvx vivo, segurando o lock. Não é falha — apenas adiamento. Puro/testável.
mcp_uv_lock_busy() {
  printf '%s' "$1" | grep -qiE 'lock|in[ -]?use|another uv process|timeout'
}

# K1 — step mutating (gated MCP_AUTO_UPDATE=1): refresca os servidores MCP cujo
# runtime é uvx (ambiente em cache que defasa) rodando `uv cache clean <dist>`,
# forçando o próximo launch a reconstruir a última versão/HEAD. Servidores npx
# sem pin já resolvem a última a cada run (auto-fresh); pinned/external/remote
# ficam fora de escopo e são apenas reportados. Operação local (sem rede); nunca
# muta pacote do sistema. Sem alvos uvx => ok. uv ausente com alvos => RC_TODO.
# N2: lock ocupado por server uvx ativo => informativo (ok), não `todo` — é o
# caso recorrente e sem ação prática durante o upgrade; erro de outra causa => warn.
mcp_update_servers() {
  local claude_json="${HOME}/.claude.json"
  local codex_toml="${HOME}/.codex/config.toml"

  local -A action_of=() cache_of=() seen=()
  local entry kind file name action dist
  for entry in "claude:${claude_json}" "codex:${codex_toml}"; do
    kind="${entry%%:*}"; file="${entry#*:}"
    [[ -r "$file" ]] || continue
    while IFS=$'\t' read -r name action dist; do
      [[ -n "$name" ]] || continue
      [[ -n "${seen[$name]:-}" ]] && continue   # 1ª fonte (claude) vence na dedup
      seen["$name"]=1
      action_of["$name"]="$action"
      cache_of["$name"]="$dist"
    done < <(mcp_update_plan "$kind" "$file")
  done

  local total="${#action_of[@]}"
  if (( total == 0 )); then
    log "  Nenhum servidor MCP a avaliar."
    return 0
  fi

  # Conta por ação e coleta nomes-dist únicos dos alvos 'refresh'.
  local n_refresh=0 n_fresh=0 n_pinned=0 n_external=0 n_remote=0
  local -A targets=()
  for name in "${!action_of[@]}"; do
    case "${action_of[$name]}" in
      refresh)
        (( n_refresh++ ))
        dist="${cache_of[$name]}"
        [[ -n "$dist" ]] && targets["$dist"]=1
        ;;
      fresh)    (( n_fresh++ )) ;;
      pinned)   (( n_pinned++ )) ;;
      external) (( n_external++ )) ;;
      remote)   (( n_remote++ )) ;;
    esac
  done

  log "  MCP: ${total} servidor(es) — refresh(uvx): ${n_refresh}, auto-fresh(npx): ${n_fresh}, pinned: ${n_pinned}, externo: ${n_external}, remoto: ${n_remote}."

  if (( n_refresh == 0 )); then
    log "  Nada a refrescar: servers npx resolvem a última a cada run; pinned/externo/remoto ficam fora de escopo."
    return 0
  fi

  if ! has uv; then
    log "  uv não instalado; não é possível refrescar o cache dos servers uvx."
    STEP_REASON="instalar uv para refrescar servers MCP uvx"
    return "$RC_TODO"
  fi

  if (( ${#targets[@]} == 0 )); then
    log "  Servers uvx sem nome de distribuição resolvível; nada a limpar."
    return 0
  fi

  local -a names=()
  for dist in "${!targets[@]}"; do names+=("$dist"); done
  log "  Limpando cache uv de: ${names[*]} (rebuild da última no próximo launch)."

  # `uv cache clean` exige o lock global de ~/.cache/uv. Se algum server uvx
  # estiver rodando (sessão Claude/Codex ativa), o lock fica ocupado e o uv
  # espera UV_LOCK_TIMEOUT (default 300s) antes de falhar — estouraria o timeout
  # do step. Fixamos um timeout curto p/ falhar rápido e degradar p/ `todo` em
  # vez de travar; nunca usamos `--force` (ignoraria server em uso e poderia
  # corromper o cache de um processo vivo).
  local uv_out uv_rc
  uv_out="$(UV_LOCK_TIMEOUT=15 uv cache clean "${names[@]}" 2>&1)"
  uv_rc=$?
  if (( uv_rc == 0 )); then
    log "  Cache uv refrescado para ${#names[@]} pacote(s) de servers MCP."
    return 0
  fi
  if mcp_uv_lock_busy "$uv_out"; then
    log "  Cache uv em uso (server uvx ativo); refresh adiado para evitar travar/corromper — não é falha."
    log "  Rode quando os servers MCP estiverem ociosos: uv cache clean ${names[*]}"
    STEP_REASON="cache uv em uso (server ativo); refrescar ocioso: uv cache clean ${names[*]}"
    return 0
  fi
  log "  uv cache clean retornou erro (não-fatal): $(printf '%s' "$uv_out" | tail -n1)"
  STEP_REASON="uv cache clean falhou para servers MCP"
  return "$RC_WARN"
}
