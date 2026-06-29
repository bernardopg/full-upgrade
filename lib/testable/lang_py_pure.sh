#!/usr/bin/env bash
# lib/testable/lang_py_pure.sh — funções puras extraídas de lib/steps/lang_py.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# _normalize_pkg_name — normaliza nome de pacote PyPI (lower, _ -> -)
_normalize_pkg_name() {
  printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-'
}

# pip_user_effective_ignore — lista efetiva de ignores para pip user
# $1 = base_ignore (space-separated), $2 = poetry_core_req (string ou vazio)
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

# poetry_core_requirement — string de requirement do poetry-core (simulado para teste)
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