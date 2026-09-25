#!/usr/bin/env bash
# lib/steps/doctor/dev.sh — auditorias de toolchain de desenvolvimento: CLIs de IA, Python, JS/pnpm e autofix de deps.
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)



# H4 — extrai a primeira linha não-vazia de `<cmd> --version`, normalizada.
# Helper puro (lê stdin), testável.
_ai_cli_first_version() {
  grep -m1 -E '[0-9]' || true
}



# H4 — inventário read-only das CLIs de IA instaladas e suas versões. Cobre o
# conjunto moderno (claude, copilot, codex, gemini, qwen, cline, opencode,
# 9router, ollama, kimi, hermes, pi, headroom, tokensave). Apenas reporta — nunca muta nem falha o run;
# CLIs ausentes são omitidas para reduzir ruído. Conta quantas foram detectadas.
doctor_ai_clis() {
  # Lista "rótulo:comando". A maioria aceita `--version`.
  local -a clis=(
    "claude:claude" "copilot:copilot" "codex:codex" "gemini:gemini"
    "qwen:qwen" "cline:cline" "opencode:opencode" "9router:9router"
    "ollama:ollama" "kimi:kimi" "hermes:hermes" "pi:pi"
    "headroom:headroom" "tokensave:tokensave"
  )
  local version_timeout="${AI_CLI_VERSION_TIMEOUT_S:-5}"
  [[ "$version_timeout" =~ ^[1-9][0-9]*$ ]] || version_timeout=5

  local entry label cmd ver out rc found=0
  for entry in "${clis[@]}"; do
    label="${entry%%:*}"; cmd="${entry#*:}"
    has "$cmd" || continue
    found=$((found + 1))
    # Uma CLI pode consultar a rede ou travar durante a inicialização. Um teto
    # individual preserva o inventário das demais e evita estourar o timeout do
    # step inteiro por causa de uma só ferramenta. Funções são usadas apenas
    # como doubles nos testes; binários reais sempre passam pelo timeout.
    if [[ "$(type -t "$cmd")" == function ]]; then
      out="$("$cmd" --version 2>/dev/null)"
      rc=$?
    else
      out="$(timeout "${version_timeout}s" "$cmd" --version 2>/dev/null)"
      rc=$?
    fi
    if (( rc == 124 )); then
      log "  ${label}: verificação de versão excedeu ${version_timeout}s."
      continue
    fi
    ver="$(printf '%s\n' "$out" | _ai_cli_first_version)"
    if [[ -n "$ver" ]]; then
      log "  ${label}: ${ver}"
    else
      log "  ${label}: instalado (versão indisponível)."
    fi
  done

  if (( found == 0 )); then
    log "  Nenhuma CLI de IA conhecida instalada."
  else
    log "  ${found} CLI(s) de IA detectada(s)."
  fi
  return 0
}




# Puro: lê `pnpm list -g --json` no stdin e emite, um por linha, os gerenciadores
# de pacote instalados como dependência no store global do pnpm (pnpm/npm/yarn)
# — sempre instalação-sombra quando o corepack já fornece o shim ativo. JSON
# inválido ou vazio => saída vazia (best-effort; nunca derruba o step).
pnpm_global_shadow_managers() {
  python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    data = [data]
seen = []
for entry in data or []:
    if not isinstance(entry, dict):
        continue
    for key in ('dependencies', 'devDependencies'):
        for name in (entry.get(key) or {}):
            if name in ('pnpm', 'npm', 'yarn') and name not in seen:
                seen.append(name)
print('\\n'.join(seen))
" 2>/dev/null || true
}



doctor_js_conflicts() {
  local status=0

  # Prefixo npm
  if has npm; then
    local prefix
    prefix="$(npm_global_prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
      case "$prefix" in
        /|/usr|/usr/local)
          log "  npm: prefixo global em ${prefix} — risco de conflito com pacotes do sistema (pacman)."
          log "  Configure: npm config set prefix ~/.local"
          STEP_REASON="npm global em ${prefix} (prefixo gerenciado pelo pacman)"
          (( status == 0 )) && status="$RC_WARN"
          ;;
        "$HOME"*|/home/*)
          log "  npm: prefixo global ok (${prefix})."
          ;;
        *)
          log "  npm: prefixo global incomum (${prefix}) — verifique se é intencional."
          STEP_REASON="npm prefixo global incomum (${prefix})"
          (( status == 0 )) && status="$RC_WARN"
          ;;
      esac
    fi
  fi

  # Conflitos npm global × pnpm global
  if has npm && has pnpm; then
    local npm_json pnpm_json conflicts
    npm_json="$(npm list -g --depth=0 --json 2>/dev/null || true)"
    pnpm_json="$(pnpm list -g --json 2>/dev/null || true)"

    if [[ $npm_json == *[![:space:]]* && $pnpm_json == *[![:space:]]* ]]; then
      local _npm_tmp _pnpm_tmp
      _npm_tmp="$(mktemp)"
      _pnpm_tmp="$(mktemp)"
      printf '%s\n' "$npm_json"  > "$_npm_tmp"
      printf '%s\n' "$pnpm_json" > "$_pnpm_tmp"
      conflicts="$(python3 - "$_npm_tmp" "$_pnpm_tmp" 2>/dev/null <<'PYEOF' || true
import json, sys

def load_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

npm_data  = load_file(sys.argv[1])
pnpm_data = load_file(sys.argv[2])

npm_pkgs  = set(npm_data.get("dependencies", {}).keys())
pnpm_deps = pnpm_data if isinstance(pnpm_data, list) else [pnpm_data]
pnpm_pkgs = set()
for entry in pnpm_deps:
    pnpm_pkgs.update(entry.get("dependencies", {}).keys())

for pkg in sorted(npm_pkgs & pnpm_pkgs):
    print(pkg)
PYEOF
)"
      rm -f "$_npm_tmp" "$_pnpm_tmp"

      if [[ $conflicts == *[![:space:]]* ]]; then
        local cc
        cc="$(printf '%s\n' "$conflicts" | wc -l)"
        log "  Conflito npm/pnpm global: ${cc} pacote(s) instalado(s) em ambos:"
        printf '%s\n' "$conflicts" | log_stream
        log "  Remova de um dos gestores para evitar versões divergentes."
        (( status == 0 )) && status="$RC_WARN"
      else
        log "  npm/pnpm global: sem pacotes duplicados."
      fi
    fi
  fi

  # Gerenciador instalado como PACOTE enquanto o corepack versiona o shim ativo.
  #
  # A checagem anterior chamava `corepack list`, subcomando que não existe
  # (corepack ≥0.30 responde "Unknown Syntax Error"), então ela nunca disparava.
  # O sinal confiável é a resolução do próprio shim: se `pnpm` resolve para o
  # dist do corepack, quem versiona o pnpm é o corepack — e um pnpm instalado
  # dentro do store global do próprio pnpm (resíduo típico de instalação via
  # `npm --prefix <global project>`) vira sombra: recoloca um shim antigo no
  # PATH, faz `pnpm --version` depender do diretório e aparece para sempre em
  # `pnpm outdated -g` — pendência que update nenhum resolve, porque o pnpm
  # recusa atualizar a si mesmo por essa via.
  if has pnpm; then
    local pnpm_bin pnpm_real shadow
    pnpm_bin="$(command -v pnpm 2>/dev/null || true)"
    pnpm_real="$(readlink -f "$pnpm_bin" 2>/dev/null || printf '%s' "$pnpm_bin")"
    if [[ "$pnpm_real" == */corepack/* ]]; then
      shadow="$(pnpm list -g --json 2>/dev/null | pnpm_global_shadow_managers)"
      shadow="${shadow//$'\n'/ }"
      if [[ $shadow == *[![:space:]]* ]]; then
        log "  pnpm ativo vem do corepack (${pnpm_real}), mas o store global do pnpm contém: ${shadow}"
        log "  Instalação-sombra: devolve um shim antigo ao PATH e fica eterna em 'pnpm outdated -g'."
        remediation "remova a sombra do store global do pnpm: pnpm remove -g ${shadow}"
        status="$RC_TODO"
      fi
    fi
  fi

  if (( status == 0 )); then
    log "  JavaScript global: sem conflitos detectados."
  fi

  return "$status"
}




# J1 — helper puro: resume a saída de `pip check`, agrupando os conflitos por
# pacote dependente e anotando o detalhe. Lê stdin, emite "<pacote>\t<detalhe>"
# (uma linha por dependente, ordenado). Cobre as duas formas do pip check:
#   "<pkg> <ver> has requirement <spec>, but you have <inst ver>."
#   "<pkg> <ver> requires <spec>, which is not installed."
# As âncoras são os sufixos da frase (", but you have" / ", which is not
# installed") — NÃO vírgula/ponto — para preservar versões com ponto ("7.4.3")
# e specs PEP 440 com múltiplos bounds ("foo>=1.0,<2.0").
summarize_pip_check() {
  awk '
    match($0, /^([A-Za-z0-9_.-]+) [^ ]+ has requirement (.+), but you have (.+)\.$/, m) {
      d = m[2] " (instalado: " m[3] ")"
      grp[m[1]] = grp[m[1]] (grp[m[1]] == "" ? "" : "; ") d
      next
    }
    match($0, /^([A-Za-z0-9_.-]+) [^ ]+ requires (.+), which is not installed\.?$/, m2) {
      grp[m2[1]] = grp[m2[1]] (grp[m2[1]] == "" ? "" : "; ") m2[2] " (ausente)"
      next
    }
    END { for (k in grp) printf "%s\t%s\n", k, grp[k] }
  ' | sort
}



# J1 — classifica a origem de cada pacote conflitante (stdin: um nome de
# distribuição por linha) inspecionando onde sua dist-info está instalada.
# Emite "<pkg>\tsystem|user":
#   /usr/lib/python*, /usr/lib64/python*, /usr/local/lib/python* => "system"
#     (gerenciado pelo pacman — pacote oficial/AUR — NÃO mexer com pip)
#   demais (ex.: ~/.local/lib/python*) => "user" (instalação pip --user)
# Falha silenciosa (pkg não resolvido) => "user". Importante: pipx/uv vivem em
# venvs isoladas e não aparecem no `pip check` do python do sistema.
_classify_pip_origins() {
  python3 -c '
import importlib.metadata as md, sys
for line in sys.stdin:
    pkg = line.strip()
    if not pkg:
        continue
    try:
        loc = str(md.distribution(pkg)._path)
        origin = "system" if loc.startswith((
            "/usr/lib/python", "/usr/lib64/python", "/usr/local/lib/python"
        )) else "user"
    except Exception:
        origin = "user"
    print(f"{pkg}\t{origin}")
' 2>/dev/null
}



doctor_python_env() {
  local status=0

  if has python && python -m pip --version >/dev/null 2>&1; then
    local pip_check_out pip_check_rc
    pip_check_out="$(python -m pip check 2>&1)"
    pip_check_rc=$?
    log_raw "$pip_check_out"
    if (( pip_check_rc == 0 )); then
      log "  pip check: sem dependências Python quebradas."
    else
      local summary cnt tab
      tab="$(printf '\t')"
      summary="$(printf '%s\n' "$pip_check_out" | summarize_pip_check)"
      if [[ $summary == *[![:space:]]* ]]; then
        cnt="$(printf '%s\n' "$summary" | grep -c "$tab")"
        log "  pip check: ${cnt} pacote(s) com dependência quebrada:"
        # Origem de cada pacote (sistema/pacman vs pip --user) decide a
        # remediação: 'pip install' sobre pacote do sistema quebra o pacman.
        local -A origin_map=()
        local _pkg _orig dep detail sys=0 usr=0
        while IFS=$'\t' read -r _pkg _orig; do
          [[ -n "$_pkg" ]] && origin_map["$_pkg"]="$_orig"
        done < <(_classify_pip_origins < <(printf '%s\n' "$summary" | cut -f1))
        while IFS=$'\t' read -r dep detail; do
          [[ -z "$dep" ]] && continue
          if [[ "${origin_map[$dep]:-user}" == "system" ]]; then
            sys=1; log "    • ${dep} [pacman/AUR]: ${detail}"
          else
            usr=1; log "    • ${dep} [pip --user]: ${detail}"
          fi
        done <<< "$summary"
        log "  Remediação sugerida (sem auto-instalação):"
        (( sys == 1 )) && log "    • [pacman/AUR]: NÃO use 'pip install' (quebra o pacman) — atualize via 'sudo pacman -Syu' ou rebuild do pacote AUR."
        (( usr == 1 )) && log "    • [pip --user]: isole com 'pipx install <ferramenta>' (venv) ou corrija o pin com 'pip install --user <dep>==<ver>'."
        # Deps AUSENTES de pacotes pip --user têm auto-remediação opcional;
        # conflitos de versão (pin) seguem manuais por decisão de design.
        if (( usr == 1 )) && (( ${AUTO_FIX_PIP_DEPS:-0} == 0 )); then
          log "    • AUTO_FIX_PIP_DEPS=1 instala sozinho as deps AUSENTES de pacotes pip --user (step 'Auto-remediar deps Python ausentes')."
        fi
      else
        # Parser não casou — preserva o dump bruto.
        log "  pip check encontrou dependências Python quebradas:"
        printf '%s\n' "$pip_check_out" | grep -v '^$' | log_stream
      fi
      (( status == 0 )) && status="$RC_WARN"
    fi
  fi

  # pipx: venvs quebradas
  if has pipx; then
    local pipx_json broken_count
    pipx_json="$(pipx list --json 2>/dev/null || true)"
    if [[ $pipx_json == *[![:space:]]* ]]; then
      # venv quebrada = python interpreter não existe no venv
      broken_count="$(printf '%s\n' "$pipx_json" | python3 -c '
import json, sys, os
data = json.load(sys.stdin)
broken = []
for pkg, info in data.get("venvs", {}).items():
    py = info.get("metadata", {}).get("python_path", "")
    if py and not os.path.isfile(py):
        broken.append(f"{pkg}: {py}")
for b in broken:
    print(b)
' 2>/dev/null || true)"
      if [[ $broken_count == *[![:space:]]* ]]; then
        local bc
        bc="$(printf '%s\n' "$broken_count" | wc -l)"
        log "  pipx: ${bc} venv(s) quebrada(s) — interpreter ausente:"
        printf '%s\n' "$broken_count" | log_stream
        log "  Repare com: pipx reinstall-all"
        (( status == 0 )) && status="$RC_TODO"
      else
        log "  pipx: todas as venvs com interpreter válido."
      fi
    fi
  fi

  # uv tools: ferramentas com interpreter ausente
  if has uv; then
    local uv_json broken_uv
    uv_json="$(uv tool list --format=json 2>/dev/null || true)"
    if [[ $uv_json == *[![:space:]]* ]]; then
      broken_uv="$(printf '%s\n' "$uv_json" | python3 -c '
import json, sys, os
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for tool in (data if isinstance(data, list) else []):
    py = tool.get("python", "") or tool.get("python_path", "")
    name = tool.get("name", "?")
    if py and not os.path.isfile(py):
        print(f"{name}: {py}")
' 2>/dev/null || true)"
      if [[ $broken_uv == *[![:space:]]* ]]; then
        local buc
        buc="$(printf '%s\n' "$broken_uv" | wc -l)"
        log "  uv tools: ${buc} ferramenta(s) com interpreter ausente:"
        printf '%s\n' "$broken_uv" | log_stream
        log "  Repare com: uv tool install --reinstall <nome>"
        (( status == 0 )) && status="$RC_TODO"
      else
        log "  uv tools: interpreters OK."
      fi
    fi
  fi

  if ! has pipx && ! has uv; then
    log "  pipx e uv não instalados; nada a auditar."
  fi


  return "$status"
}



# Auto-remediação opcional de dependências pip --user AUSENTES. O doctor
# 'ambiente Python' reporta pacotes pip --user com dependência ausente (ex.:
# 'fvs 0.3.4 requires orjson, which is not installed'). Sob AUTO_FIX_PIP_DEPS=1,
# instala cada requisito ausente com 'pip install --user' — aditivo por
# construção: se a dependência existisse em qualquer site visível (inclusive o
# do pacman), o pip check não a teria listado como ausente —, logo nunca
# sobrepõe arquivo gerenciado pelo pacman. Conflitos de VERSÃO ('requires X,
# but you have Y') seguem manuais: a correção certa depende de pin/downgrade e
# o doctor segue sugerindo. Pacotes de origem system são intocáveis. Re-executa
# o pip check ao final e reporta antes→depois. Gate de wiring em main.sh (nunca
# sob --no-repair; --mode doctor/--dry-run pulam steps mutating).
autofix_pip_user_deps() {
  if (( ${AUTO_FIX_PIP_DEPS:-0} == 0 )); then
    log "  AUTO_FIX_PIP_DEPS desligado; nada a remediar."
    return 0
  fi
  if ! has python || ! python -m pip --version >/dev/null 2>&1; then
    log "  pip indisponível; nada a remediar."
    return 0
  fi

  # Mesma triagem do doctor: summary "pkg\tdetail" + origem via dist-info.
  local summary pkg detail origin entry req d
  local -a reqs=() failed_installs=()
  summary="$(python -m pip check 2>&1 | summarize_pip_check)"
  if [[ $summary != *[![:space:]]* ]]; then
    log "  pip check limpo; nada a remediar."
    return 0
  fi

  while IFS=$'\t' read -r pkg detail; do
    [[ -n "$pkg" ]] || continue
    origin="$(_classify_pip_origins <<<"$pkg" | cut -f2)"
    [[ "$origin" == "user" ]] || continue  # system/pacman: NUNCA pip install
    # Só requisitos AUSENTES ('dep (ausente)'); conflito de versão é pin manual.
    while IFS=$'\n' read -r d; do
      d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"  # trim
      [[ "$d" == *"(ausente)" ]] || continue
      req="${d% (ausente)}"
      [[ -n "$req" ]] && reqs+=("${pkg}"$'\t'"${req}")
    done <<< "${detail//;/$'\n'}"
  done <<< "$summary"

  if (( ${#reqs[@]} == 0 )); then
    log "  Sem dependências ausentes em pacotes pip --user; nada a remediar."
    return 0
  fi

  log "  Instalando ${#reqs[@]} dependência(s) ausente(s) de pacotes pip --user…"
  local pkg_log
  for entry in "${reqs[@]}"; do
    req="${entry#*$'\t'}"
    pkg_log="${entry%%$'\t'*}"
    log "  [${pkg_log}] pip install --user ${req}"
    if run_logged python -m pip install --user --break-system-packages "$req"; then
      continue
    fi
    failed_installs+=("$req")
  done

  if (( ${#failed_installs[@]} > 0 )); then
    log "  Falha ao instalar: ${failed_installs[*]}"
    STEP_REASON="pip install falhou para ${#failed_installs[@]} dep(s)"
    return "$RC_WARN"
  fi

  local after
  after="$(python -m pip check 2>&1 | summarize_pip_check)"
  if [[ $after != *[![:space:]]* ]]; then
    log "  ${C_GREEN}pip check limpo após remediação.${C_RESET}"
    return 0
  fi
  log "  pip check ainda reporta pendências (conflitos de versão exigem pin manual):"
  printf '%s\n' "$after" | log_stream
  log "  Consulte 'Doctor: ambiente Python' para as sugestões."
  return 0
}



# N3 — helper puro: dado o `gem list` do sistema ($1) e o do usuário ($2),
# emite as gems que o usuário SOMBREIA com versão divergente. Considera só as
# versões REAIS (instaladas) — entradas "default: X" (gems bundled do Ruby) são
# ignoradas, pois existem em ambos e upgrades de usuário nelas são normais. Uma
# linha por gem: "nome|versões_reais_sistema|versões_reais_usuário". Flag quando
# o sistema tem versão real (gem do Arch) e o usuário tem alguma real ausente nela.
# Read-only. Formato de entrada (gem list): "nome (1.2.3, 1.0.0, default: 0.9)".
gem_shadow_diff() {
  local sys="$1" usr="$2"
  [[ -r "$sys" && -r "$usr" ]] || return 0
  awk '
    function gname(line,   name) { name = line; sub(/ *\(.*/, "", name); return name }
    function realvers(line,   vers, n, parts, i, p, out) {
      if (line !~ /\(/) return ""
      vers = line; sub(/^[^(]*\(/, "", vers); sub(/\).*/, "", vers)
      n = split(vers, parts, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        p = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (p == "" || p ~ /^default:/) continue
        out = (out == "") ? p : out " " p
      }
      return out
    }
    NR == FNR { if ($0 ~ /\(/) sysv[gname($0)] = realvers($0); next }
    {
      if ($0 !~ /\(/) next
      name = gname($0)
      if (!(name in sysv) || sysv[name] == "") next   # sistema sem versão real => ignora
      uv = realvers($0)
      if (uv == "") next                               # usuário só tem default => ignora
      nn = split(uv, U, " "); diff = 0
      for (i = 1; i <= nn && !diff; i++) {
        found = 0; mm = split(sysv[name], S, " ")
        for (j = 1; j <= mm; j++) if (U[i] == S[j]) { found = 1; break }
        if (!found) diff = 1
      }
      if (diff) print name "|" sysv[name] "|" uv
    }
  ' "$sys" "$usr"
}


# N3 — Doctor read-only: gems instaladas pelo USUÁRIO que sombreiam uma gem real
# do sistema (Arch) com versão divergente — ex.: rdoc 7.2.0 (user) sobre 6.14.0
# (Arch), que faz toda invocação ruby carregar a do usuário e despejar
# "already initialized constant". Gems default do Ruby são ignoradas. Sem gem =>
# skip via catálogo. Acionável (`gem uninstall --user-install`) => RC_TODO.
doctor_gem_shadow() {
  has gem || { log "  gem não disponível; pulando."; return 0; }
  local sys_home usr_home
  sys_home="$(gem env home 2>/dev/null || true)"
  usr_home="$(gem env user_gemhome 2>/dev/null || true)"
  if [[ -z "$sys_home" || "$sys_home" == "$HOME"* || -z "$usr_home" || ! -d "$usr_home" ]]; then
    log "  Sem separação sistema/usuário de gems; nada a checar."
    return 0
  fi

  local sysf usrf
  sysf="$(mktemp)"; usrf="$(mktemp)"
  GEM_HOME="$sys_home" GEM_PATH="$sys_home" gem list --local 2>/dev/null > "$sysf"
  GEM_HOME="$usr_home" GEM_PATH="$usr_home" gem list --local 2>/dev/null > "$usrf"
  local -a shadow=()
  mapfile -t shadow < <(gem_shadow_diff "$sysf" "$usrf")
  rm -f "$sysf" "$usrf"

  if (( ${#shadow[@]} == 0 )); then
    log "  Sem gems do usuário sombreando gems do sistema (Arch)."
    return 0
  fi

  log "  ${C_YELLOW}${#shadow[@]} gem(s) do usuário sombreiam a versão do sistema (Arch):${C_RESET}"
  local line name sysv usrv shown=0
  for line in "${shadow[@]}"; do
    IFS='|' read -r name sysv usrv <<< "$line"
    if (( shown < 20 )); then
      log "    • ${name}: sistema ${sysv} vs usuário ${usrv}"
      shown=$((shown + 1))
    fi
  done
  (( ${#shadow[@]} > 20 )) && log "    … e mais $(( ${#shadow[@]} - 20 ))."
  log "  Dica: remova a cópia do usuário p/ usar a do Arch — gem uninstall --user-install <gem>"
  STEP_REASON="${#shadow[@]} gem(s) do usuário sombreando o sistema"
  return "$RC_TODO"
}


# H6 — Doctor read-only: enumera servidores MCP configurados nas fontes conhecidas
# (hoje: Claude Code via ~/.claude.json, Codex via ~/.codex/config.toml). Lista
# cada servidor com escopo e binário/runtime (stdio:npx, stdio:uvx, remote...).
# Nunca muta nem falha o run; MCP_AUTO_UPDATE (default 0) é guardado p/ futuro
# passo mutating. Sem fontes => skip limpo.
doctor_mcp_servers() {
  local claude_json="${HOME}/.claude.json"
  local codex_toml="${HOME}/.codex/config.toml"
  local opencode_json="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/opencode.json"
  local hub_json="${XDG_CONFIG_HOME:-${HOME}/.config}/mcp-central/mcp-hub.json"
  local hermes_yaml="${HOME}/.hermes/config.yaml"
  local has_source=0

  local -x CODEX_GITHUB_PERSONAL_ACCESS_TOKEN="${CODEX_GITHUB_PERSONAL_ACCESS_TOKEN:-}"
  local -x Z_AI_API_KEY="${Z_AI_API_KEY:-${ZAI_API_KEY:-}}"

  local -A all=()        # name -> "detalhe"
  local -A src_claude=() # name -> 1
  local -A src_codex=()  # name -> 1
  local -A src_opencode=() src_hub=() src_hermes=() scope_claude=() issues=()

  # Claude (JSON): fonte primária, com escopo + binário.
  if [[ -r "$claude_json" ]]; then
    has_source=1
    local name scope detail
    while IFS=$'\t' read -r name scope detail; do
      [[ -n "$name" ]] || continue
      all["$name"]="$detail"
      src_claude["$name"]=1
      scope_claude["$name"]="$scope"
    done < <(parse_mcp_claude_json "$claude_json")
  fi

  # Codex (TOML): runtime real e referências de ambiente obrigatórias.
  if [[ -r "$codex_toml" ]]; then
    has_source=1
    # O wrapper local do Codex reutiliza a credencial protegida pelo keyring do
    # gh. Espelha a resolução no Doctor sem persistir/imprimir o token.
    if [[ -z "$CODEX_GITHUB_PERSONAL_ACCESS_TOKEN" ]] \
       && grep -q 'CODEX_GITHUB_PERSONAL_ACCESS_TOKEN' "$codex_toml" && has gh; then
      CODEX_GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi
    local cname cdetail cissue
    while IFS=$'\t' read -r cname cdetail cissue; do
      [[ -n "$cname" ]] || continue
      if [[ "$cname" == "__CONFIG_ERROR__" ]]; then
        issues["codex"]="$cissue"
        continue
      fi
      src_codex["$cname"]=1
      [[ -n "${all[$cname]:-}" ]] || all["$cname"]="$cdetail"
      [[ -z "$cissue" ]] || issues["codex:$cname"]="$cissue"
    done < <(parse_mcp_codex_entries "$codex_toml")
  fi

  local source file sname sdetail sissue
  for source in opencode hub; do
    [[ "$source" == opencode ]] && file="$opencode_json" || file="$hub_json"
    [[ -r "$file" ]] || continue
    has_source=1
    while IFS=$'\t' read -r sname sdetail sissue; do
      [[ -n "$sname" ]] || continue
      if [[ "$sname" == "__CONFIG_ERROR__" ]]; then
        issues["$source"]="$sissue"
        continue
      fi
      if [[ "$source" == opencode ]]; then src_opencode["$sname"]=1; else src_hub["$sname"]=1; fi
      [[ -n "${all[$sname]:-}" ]] || all["$sname"]="$sdetail"
      [[ -z "$sissue" ]] || issues["${source}:$sname"]="$sissue"
    done < <(parse_mcp_json_entries "$file")
  done

  local hermes_name hermes_rc=0
  if [[ -r "$hermes_yaml" ]]; then
    has_source=1
    while IFS= read -r hermes_name; do
      [[ -n "$hermes_name" ]] || continue
      src_hermes["$hermes_name"]=1
      [[ -n "${all[$hermes_name]:-}" ]] || all["$hermes_name"]="configurado (hermes)"
    done < <(parse_mcp_hermes_names "$hermes_yaml")
    if has hermes; then
      timeout 15 hermes mcp list >/dev/null 2>&1
      hermes_rc=$?
      if (( hermes_rc != 0 )); then
        issues["hermes"]="'hermes mcp list' falhou (rc=${hermes_rc})"
      fi
    fi
  fi

  if (( has_source == 0 )); then
    log "  Nenhuma fonte MCP configurada (Claude/Codex/OpenCode/mcp-central)."
    return 0
  fi

  local n="${#all[@]}"
  if (( n == 0 )); then
    log "  Fontes MCP presentes, mas nenhum servidor configurado."
    return 0
  fi

  local nc=0 nx=0 no=0 nh=0 nhe=0
  nc="${#src_claude[@]}"
  nx="${#src_codex[@]}"
  no="${#src_opencode[@]}"
  nh="${#src_hub[@]}"
  nhe="${#src_hermes[@]}"
  log "  MCP: ${n} servidor(es) distinto(s) — Claude: ${nc}, Codex: ${nx}, OpenCode: ${no}, Hub: ${nh}, Hermes: ${nhe}."

  local sname sdetail srcs
  for sname in $(printf '%s\n' "${!all[@]}" | sort); do
    sdetail="${all[$sname]}"
    srcs=""
    if [[ -n "${src_claude[$sname]:-}" ]]; then
      srcs="claude"
      [[ "${scope_claude[$sname]:-global}" == project:* ]] && srcs="claude/${scope_claude[$sname]}"
    fi
    [[ -n "${src_codex[$sname]:-}" ]] && srcs="${srcs:+$srcs, }codex"
    [[ -n "${src_opencode[$sname]:-}" ]] && srcs="${srcs:+$srcs, }opencode"
    [[ -n "${src_hub[$sname]:-}" ]] && srcs="${srcs:+$srcs, }hub"
    [[ -n "${src_hermes[$sname]:-}" ]] && srcs="${srcs:+$srcs, }hermes"
    log "    • ${sname} [${srcs}, ${sdetail}]"
  done
  if (( ${#issues[@]} > 0 )); then
    local ikey
    log "  Problemas MCP detectados:"
    for ikey in $(printf '%s\n' "${!issues[@]}" | sort); do
      log "    • ${ikey}: ${issues[$ikey]}"
    done
    if [[ "${issues[codex]:-}" == "TOML inválido"* ]]; then
      local _backup_exists=0 _has_headroom=0
      [[ -f "${HOME}/.codex/config.toml.headroom-backup" ]] && _backup_exists=1
      has headroom && _has_headroom=1
      log "  Remediação (codex):"
      local _hint_line
      while IFS= read -r _hint_line; do
        log "    • ${_hint_line}"
      done < <(codex_toml_remediation_hints "$_backup_exists" "$_has_headroom")
    fi
    STEP_REASON="${#issues[@]} problema(s) de configuração MCP"
    return "$RC_WARN"
  fi
  if (( ${MCP_AUTO_UPDATE:-0} == 1 )); then
    log "  Remediação: MCP_AUTO_UPDATE=1 — o step 'Atualizar servidores MCP' refresca os runtimes uvx."
  else
    log "  Remediação: mantenha runtimes (npx/uvx/node) atualizados; MCP_AUTO_UPDATE=0 (ligue p/ refrescar uvx automaticamente)."
  fi
  return 0
}
