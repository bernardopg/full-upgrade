#!/usr/bin/env bash
# steps/lang_py.sh — pip, pipx, uv, poetry
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é consumido pelo framework em core.sh

poetry_core_requirement() {
  python - <<'PY'
import importlib.metadata as md

try:
    reqs = md.requires("poetry") or []
except md.PackageNotFoundError:
    raise SystemExit

for req in reqs:
    if req.lower().startswith("poetry-core"):
        print(req)
        break
PY
}

_normalize_pkg_name() {
  printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-'
}

# Lista efetiva de pacotes que o update genérico do pip --user deve ignorar.
# Se Poetry está instalado e fixa poetry-core, não atualizamos poetry-core no
# step genérico: o step dedicado do Poetry garante a versão compatível depois.
pip_user_effective_ignore() {
  local base_ignore="${1:-}" poetry_core_req="${2:-}"
  local -a ignored=()
  local name normalized exists

  for name in $base_ignore; do
    normalized="$(_normalize_pkg_name "$name")"
    [[ -n "$normalized" ]] || continue
    ignored+=("$normalized")
  done

  if [[ "$poetry_core_req" == poetry-core* ]]; then
    exists=0
    for name in "${ignored[@]}"; do
      [[ "$name" == "poetry-core" ]] && { exists=1; break; }
    done
    (( exists )) || ignored+=("poetry-core")
  fi

  printf '%s\n' "${ignored[*]}"
}


update_pip_user() {
  local json leaves_json poetry_core_req effective_ignore
  local -a pkgs=()

  poetry_core_req="$(poetry_core_requirement 2>/dev/null || true)"
  effective_ignore="$(pip_user_effective_ignore "${FULL_UPGRADE_PIP_USER_IGNORE:-}" "$poetry_core_req")"

  # Restringe o upgrade a pacotes TOP-LEVEL (--not-required: nenhum outro
  # pacote depende deles). Subir uma dep transitiva isoladamente (ex.: chardet)
  # via --upgrade fura a constraint do pacote pai (ex.: pygount exige
  # chardet<6) e deixa o ambiente quebrado (pip check falha). Atualizando só as
  # folhas, o resolver do pip sobe cada dep dentro da faixa permitida pelo pai.
  json="$(python -m pip list --user --outdated --format=json 2>/dev/null || true)"
  leaves_json="$(python -m pip list --user --not-required --format=json 2>/dev/null || true)"
  if [[ $json == *[![:space:]]* && $leaves_json != *[![:space:]]* ]]; then
    log "  Aviso: 'pip list --not-required' não retornou folhas; subindo todos os desatualizados (sem filtro de top-level)."
  fi
  if [[ $json == *[![:space:]]* ]]; then
    mapfile -t pkgs < <(FULL_UPGRADE_PIP_USER_IGNORE="$effective_ignore" FULL_UPGRADE_PIP_USER_LEAVES="$leaves_json" python -c '
  # kcov-excl-start (programa embutido, não é Bash)
import json, sys
import os

def norm(n):
    return n.lower().replace("_", "-")

ignored = {
    norm(name)
    for name in os.environ.get("FULL_UPGRADE_PIP_USER_IGNORE", "").split()
}
try:
    leaves_data = json.loads(os.environ.get("FULL_UPGRADE_PIP_USER_LEAVES", "") or "[]")
except Exception:
    leaves_data = []
# Conjunto de folhas (top-level). Se a consulta de folhas falhar/voltar vazia,
# o filtro de folhas é desativado (degrada para o comportamento antigo de subir
# tudo) — preferível a parar todos os updates de pip silenciosamente. O caller
# loga um aviso nesse caso.
leaves = {norm(p.get("name")) for p in leaves_data if p.get("name")}
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for pkg in data:
    name = pkg.get("name")
    if not name:
        continue
    key = norm(name)
    if key in ignored:
        continue
    if leaves and key not in leaves:
        continue
    print(name)
' <<<"$json")
# kcov-excl-stop
  fi

  if (( ${#pkgs[@]} == 0 )); then
    if [[ $effective_ignore == *[![:space:]]* ]]; then
      log "  Sem pacotes pip --user desatualizados fora da lista de ignore."
    else
      log "  Sem pacotes pip --user desatualizados."
    fi
    return 0
  fi

  log "  Atualizando pacotes pip --user: ${pkgs[*]}"
  if [[ $effective_ignore == *[![:space:]]* ]]; then
    log "  Ignorando no update genérico do pip: ${effective_ignore}"
  fi
  log "  (--break-system-packages: necessário no Arch — pip user-install não conflita com pacman)"
  run_logged python -m pip install --user --break-system-packages --upgrade "${pkgs[@]}"
}


# Executáveis em ~/.local/bin que o pipx se recusou a relinkar ("File exists at
# X and points to X, not <venv>"). Costuma ser uma cópia antiga de `pip install
# --user` da mesma ferramenta: o pipx atualiza o venv, mas o PATH segue rodando
# a versão velha. Puro/testável.
pipx_shadowed_bins() {
  grep -oE 'File exists at [^[:space:]]+' <<<"$1" | awk '{print $4}' | sort -u
}

update_pipx() {
  local output rc
  output="$(pipx upgrade-all 2>&1)"
  rc=$?
  log_raw "$output"

  # "No packages upgraded" = nada a fazer — substituir por msg limpa em pt-BR
  if grep -q 'No packages upgraded' <<<"$output"; then
    log "  pipx: todos os pacotes já atualizados."
  else
    # Suprimir "upgrading X..." — manter só sumário e linhas de pacotes atualizados
    printf '%s\n' "$output" | grep -v '^upgrading ' | grep -v '^$' | log_out || true
  fi

  # Checado mesmo com "No packages upgraded": o aviso sai a cada run, inclusive
  # quando o venv já está atualizado e só o link ficou para trás.
  local bin
  local -a shadowed=()
  mapfile -t shadowed < <(pipx_shadowed_bins "$output")
  (( rc == 0 && ${#shadowed[@]} > 0 )) || return "$rc"
  for bin in "${shadowed[@]}"; do
    log "  ${C_YELLOW}Aviso: ${bin} não é o link do pipx; o PATH roda outra cópia (provável pip --user).${C_RESET}"
    remediation "python -m pip uninstall --break-system-packages $(basename "$bin")   (ou rm '${bin}') && pipx reinstall $(basename "$bin")"
  done
  # shellcheck disable=SC2034  # global cross-module lida por core.sh
  STEP_REASON="pipx não relinkou: ${shadowed[*]}"
  return "$RC_TODO"
}


update_uv_self() {
  local output rc
  output="$(uv self update 2>&1)"
  rc=$?
  printf '%s\n' "$output" | log_stream
  return "$rc"
}


update_uv_python() {
  local -a managed=()
  local -a minor_versions=()
  local -a seen_minors=()
  local ver minor

  mapfile -t managed < <(uv python list --only-installed 2>/dev/null | grep "uv/python" | awk '{print $1}')

  if (( ${#managed[@]} == 0 )); then
    log "  Sem versões Python gerenciadas pelo uv."
    return 0
  fi

  # Deduplica: pegar só a versão minor (3.13, 3.12, 3.11) para upgrade
  for ver in "${managed[@]}"; do
    # ver = cpython-3.13.12-linux-x86_64-gnu  →  3.13
    minor="$(printf '%s' "$ver" | sed -nE 's/.*cpython-([0-9]+\.[0-9]+).*/\1/p')"
    [[ -n "$minor" ]] || continue
    if ! array_contains "$minor" "${seen_minors[@]}"; then
      seen_minors+=("$minor")
      minor_versions+=("$minor")
    fi
  done

  log "  Versões Python uv instaladas: ${minor_versions[*]}"
  local output rc
  output="$(uv python upgrade "${minor_versions[@]}" 2>&1)"
  rc=$?
  printf '%s\n' "$output" | log_stream
  return "$rc"
}


# Compara as flags longas do ExecStart da unit Headroom com o help da CLI
# recém-instalada. Emite uma flag incompatível por linha; não executa/reinicia
# o serviço, portanto é seguro durante sessões Codex/Claude ativas.
headroom_unit_unsupported_flags() {
  local unit_text="$1" help_text="$2" flag
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    grep -qF -- "$flag" <<<"$help_text" || printf '%s\n' "$flag"
  done < <(sed -n 's/^ExecStart=//p' <<<"$unit_text" | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)
}

# Testa apenas destinos locais explícitos, sem credenciais nem requests de API.
headroom_local_upstream_unavailable() {
  python3 - "$1" <<'PYUPSTREAM'
import shlex, socket, sys
from urllib.parse import urlsplit
for line in sys.argv[1].splitlines():
    if not line.startswith("ExecStart="):
        continue
    try:
        args = shlex.split(line.partition("=")[2])
    except ValueError:
        continue
    for i, arg in enumerate(args):
        for flag in ("--openai-api-url", "--anthropic-api-url"):
            if arg == flag and i + 1 < len(args):
                value = args[i + 1]
            elif arg.startswith(flag + "="):
                value = arg.partition("=")[2]
            else:
                continue
            try:
                url = urlsplit(value)
                if url.hostname not in ("localhost", "127.0.0.1", "::1"):
                    continue
                port = url.port or (443 if url.scheme == "https" else 80)
                with socket.create_connection((url.hostname, port), timeout=2):
                    pass
            except (OSError, ValueError):
                print(f"{flag}: destino local indisponível")
PYUPSTREAM
}

check_headroom_unit_compat() {
  local unit="${HEADROOM_USER_UNIT:-${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/headroom.service}"
  [[ -r "$unit" ]] || return 0
  has headroom || return 0

  local help_text unit_text
  help_text="$(headroom proxy --help 2>/dev/null)" || {
    log "  Headroom: não foi possível consultar 'proxy --help' após o upgrade."
    STEP_REASON="não foi possível validar compatibilidade da unit Headroom"
    return "$RC_WARN"
  }
  unit_text="$(<"$unit")"

  local -a unsupported=()
  mapfile -t unsupported < <(headroom_unit_unsupported_flags "$unit_text" "$help_text")
  if (( ${#unsupported[@]} == 0 )); then
    log "  Headroom: ExecStart compatível com a CLI instalada."
    local unavailable
    unavailable="$(headroom_local_upstream_unavailable "$unit_text")"
    if [[ -n "$unavailable" ]]; then
      log "  Headroom: ${unavailable}"
      log "  Configure um upstream válido para as rotas usadas; serviço preservado durante sessões ativas."
      STEP_REASON="Headroom: ${unavailable}; revisar rota usada após desativar o upstream"
      return "$RC_TODO"
    fi
    return 0
  fi

  log "  Headroom: a unit usa flag(s) não suportada(s): ${unsupported[*]}"
  log "  Serviço não reiniciado para preservar sessões ativas; corrija a unit antes do próximo restart."
  STEP_REASON="unit Headroom incompatível com a CLI: ${unsupported[*]}"
  return "$RC_TODO"
}

# ── uv tool preso por restrição do receipt (U2) ───────────────────────────────
# `uv tool upgrade` respeita as restrições gravadas no uv-receipt.toml (as do
# `--with "mcp<2"` e o pin da própria ferramenta) e sai 0 sem atualizar. O
# headroom ficou em 0.42.0 com a 0.44.0 publicada, porque a 0.43+ exige
# mcp>=2.2, e o step relatou ok. Estes helpers acham a ferramenta presa.

# Nome normalizado pela PEP 503 (Foo_Bar.baz → foo-bar-baz).
_pep503_name() {
  local n="${1,,}"
  printf '%s' "$n" | sed -E 's/[-_.]+/-/g'
}

# Lê o receipt ($1) e imprime, uma por linha, as restrições de versão
# ("nome<spec") gravadas em [tool].requirements. Puro.
uv_receipt_constraints() {
  local receipt="$1" line in_req=0
  [[ -r "$receipt" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*requirements[[:space:]]*= ]] && in_req=1
    ((in_req)) || continue
    if [[ "$line" =~ name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      local name="${BASH_REMATCH[1]}"
      if [[ "$line" =~ specifier[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        printf '%s%s\n' "$name" "${BASH_REMATCH[1]}"
      fi
    fi
    [[ "$line" =~ \][[:space:]]*$ ]] && in_req=0
  done <"$receipt"
  return 0
}

# Spec de reinstalação sem restrições: nome da ferramenta ($2) com os extras
# gravados no receipt ($1), ex.: headroom-ai[all]. Puro.
uv_receipt_install_spec() {
  local receipt="$1" tool="$2" line extras=""
  local want
  want="$(_pep503_name "$tool")"
  if [[ -r "$receipt" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]] || continue
      [[ "$(_pep503_name "${BASH_REMATCH[1]}")" == "$want" ]] || continue
      if [[ "$line" =~ extras[[:space:]]*=[[:space:]]*\[([^]]*)\] ]]; then
        extras="${BASH_REMATCH[1]//\"/}"
        extras="${extras//[[:space:]]/}"
      fi
      break
    done <"$receipt"
  fi
  if [[ -n "$extras" ]]; then
    printf '%s[%s]' "$tool" "$extras"
  else
    printf '%s' "$tool"
  fi
}

# Converte a saída de `uv tool list` em "nome versão" (sem o v). Puro.
uv_tool_list_versions() {
  local line
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)[[:space:]]+v([0-9][^[:space:]]*) ]] || continue
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done <<<"$1"
}

# Última versão publicada no PyPI. Vazio quando a rede ou o PyPI falham, e o
# chamador trata vazio como "desconhecida" (nunca como desatualizada).
pypi_latest_version() {
  has curl || return 0
  local json
  json="$(curl -fsS --connect-timeout 5 --max-time 10 "https://pypi.org/pypi/${1}/json" 2>/dev/null)" || return 0
  if has jq; then
    jq -r '.info.version // empty' <<<"$json" 2>/dev/null
  else
    sed -nE 's/.*"info":\{.*"version":[[:space:]]*"([^"]+)".*/\1/p' <<<"$json" | head -1
  fi
}

# Ferramentas uv com restrição no receipt E atrás da última versão do PyPI.
# Só consulta o PyPI das que têm restrição, então o custo é zero no caso comum.
# Imprime "ferramenta|instalada|última|restrições|spec" por linha.
uv_tools_held_back() {
  local dir list tool ver receipt cons latest
  dir="$(uv tool dir 2>/dev/null)" || return 0
  [[ -n "$dir" && -d "$dir" ]] || return 0
  list="$(uv tool list 2>/dev/null)" || return 0
  while read -r tool ver; do
    [[ -n "$tool" ]] || continue
    receipt="${dir}/${tool}/uv-receipt.toml"
    cons="$(uv_receipt_constraints "$receipt" | paste -sd' ' -)"
    [[ -n "$cons" ]] || continue
    latest="$(pypi_latest_version "$tool")"
    [[ -n "$latest" ]] && version_is_outdated "$ver" "$latest" || continue
    printf '%s|%s|%s|%s|%s\n' "$tool" "$ver" "$latest" "$cons" "$(uv_receipt_install_spec "$receipt" "$tool")"
  done < <(uv_tool_list_versions "$list")
}

# 0 se a ferramenta ($1) está em FULL_UPGRADE_UV_TOOL_HOLD_IGNORE (espaço ou
# vírgula; nomes comparados pela PEP 503).
uv_tool_hold_ignored() {
  local want item
  want="$(_pep503_name "$1")"
  for item in ${FULL_UPGRADE_UV_TOOL_HOLD_IGNORE//,/ }; do
    [[ "$(_pep503_name "$item")" == "$want" ]] && return 0
  done
  return 1
}

update_uv_tools() {
  local output rc

  output="$(uv tool upgrade --all 2>&1)"
  rc=$?
  printf '%s\n' "$output" | log_stream

  if (( rc != 0 )); then
    if grep -qi 'no tools installed\|nothing to upgrade' <<<"$output"; then
      log "  Sem ferramentas uv para atualizar."
      return 0
    fi
    return "$rc"
  fi

  local compat_rc=0
  check_headroom_unit_compat || compat_rc=$?

  local entry tool ver latest cons spec
  local -a held=() held_names=()
  mapfile -t held < <(uv_tools_held_back)
  for entry in "${held[@]}"; do
    IFS='|' read -r tool ver latest cons spec <<<"$entry"
    if uv_tool_hold_ignored "$tool"; then
      log "  ${tool} ${ver} fixado de propósito (FULL_UPGRADE_UV_TOOL_HOLD_IGNORE); última: ${latest}."
      continue
    fi
    log "  ${tool} ${ver} está preso pela restrição '${cons}' do receipt; última versão: ${latest}."
    remediation "uv tool install '${spec}' --force   # reinstala sem '${cons}'; confira a compatibilidade antes"
    held_names+=("${tool} ${ver}→${latest}")
  done

  if ((compat_rc != 0)); then
    ((${#held_names[@]} > 0)) && STEP_REASON="${STEP_REASON:+${STEP_REASON}; }uv tool preso por restrição do receipt: ${held_names[*]}"
    return "$compat_rc"
  fi
  if ((${#held_names[@]} > 0)); then
    STEP_REASON="uv tool preso por restrição do receipt: ${held_names[*]}"
    return "$RC_TODO"
  fi
  return 0
}


update_poetry() {
  local latest core_req
  latest="$(python -m pip list --user --outdated --format=json 2>/dev/null | python -c '
  # kcov-excl-start (programa embutido, não é Bash)
import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for pkg in data:
    if pkg.get("name") == "poetry":
        print(pkg.get("latest", ""))
')"
# kcov-excl-stop

  core_req="$(poetry_core_requirement 2>/dev/null || true)"

  if [[ $latest != *[![:space:]]* ]]; then
    log "  Poetry ja está na versão mais recente (via pip --user)."
  else
    run_logged python -m pip install --user --break-system-packages --upgrade poetry || return $?
  fi

  if [[ $core_req == *[![:space:]]* ]]; then
    log "  Garantindo poetry-core compatível com Poetry: ${core_req}"
    run_logged python -m pip install --user --break-system-packages "$core_req"
  fi
}
