#!/usr/bin/env bash
# steps/lang_py.sh — pip, pipx, uv, poetry
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

update_pip_user() {
  local json
  local -a pkgs=()

  json="$(python -m pip list --user --outdated --format=json 2>/dev/null || true)"
  if [[ -n "${json//[[:space:]]/}" ]]; then
    mapfile -t pkgs < <(
      printf '%s' "$json" | python -c '
import json, sys
import os

ignored = {
    name.lower().replace("_", "-")
    for name in os.environ.get("FULL_UPGRADE_PIP_USER_IGNORE", "").split()
}
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for pkg in data:
    name = pkg.get("name")
    if name and name.lower().replace("_", "-") not in ignored:
        print(name)
'
    )
  fi

  if (( ${#pkgs[@]} == 0 )); then
    if [[ -n "${FULL_UPGRADE_PIP_USER_IGNORE//[[:space:]]/}" ]]; then
      log "  Sem pacotes pip --user desatualizados fora da lista de ignore."
    else
      log "  Sem pacotes pip --user desatualizados."
    fi
    return 0
  fi

  log "  Atualizando pacotes pip --user: ${pkgs[*]}"
  if [[ -n "${FULL_UPGRADE_PIP_USER_IGNORE//[[:space:]]/}" ]]; then
    log "  Ignorando no update genérico do pip: ${FULL_UPGRADE_PIP_USER_IGNORE}"
  fi
  log "  (--break-system-packages: necessário no Arch — pip user-install não conflita com pacman)"
  run_logged python -m pip install --user --break-system-packages --upgrade "${pkgs[@]}"
}


update_pipx() {
  local output rc
  output="$(pipx upgrade-all 2>&1)"
  rc=$?
  log_raw "$output"

  # "No packages upgraded" = nada a fazer — substituir por msg limpa em pt-BR
  if printf '%s\n' "$output" | grep -q 'No packages upgraded'; then
    log "  pipx: todos os pacotes já atualizados."
    return "$rc"
  fi

  # Suprimir "upgrading X..." — manter só sumário e linhas de pacotes atualizados
  printf '%s\n' "$output" | grep -v '^upgrading ' | grep -v '^$' || true

  # Detecta symlink quebrado/auto-referente em ~/.local/bin (pipx avisa
  # "File exists at ... and points to <ele mesmo>, not <venv>"). Costuma
  # ocorrer quando a mesma ferramenta foi instalada via pip --user E pipx.
  # Não é erro do update; sinalizamos remediação sem falhar o step.
  local _selfln
  while IFS= read -r _selfln; do
    [[ -n "$_selfln" ]] || continue
    log "  ${C_YELLOW}Aviso: '${_selfln}' é um symlink auto-referente (pip --user vs pipx).${C_RESET}"
    log "  Remediação: pipx reinstall \$(basename '${_selfln}')   ou   rm '${_selfln}' && pipx ensurepath"
  done < <(
    printf '%s\n' "$output" \
      | grep -oE 'File exists at [^[:space:]]+' \
      | awk '{print $4}' \
      | sort -u
  )
  return "$rc"
}


update_uv_self() {
  local output rc
  output="$(uv self update 2>&1)"
  rc=$?
  printf '%s\n' "$output" | tee >(_strip_ansi >> "$LOG_FILE")
  return "$rc"
}


update_uv_python() {
  local -a managed=()
  local -a minor_versions=()
  local -a seen_minors=()
  local ver minor

  mapfile -t managed < <(
    uv python list --only-installed 2>/dev/null \
      | grep "uv/python" \
      | awk '{print $1}'
  )

  if (( ${#managed[@]} == 0 )); then
    log "  Sem versões Python gerenciadas pelo uv."
    return 0
  fi

  # Deduplica: pegar só a versão minor (3.13, 3.12, 3.11) para upgrade
  for ver in "${managed[@]}"; do
    # ver = cpython-3.13.12-linux-x86_64-gnu  →  3.13
    minor="$(printf '%s' "$ver" | grep -oP '(?<=cpython-)\d+\.\d+')"
    [[ -n "$minor" ]] || continue
    if ! printf '%s\n' "${seen_minors[@]}" | grep -qx "$minor"; then
      seen_minors+=("$minor")
      minor_versions+=("$minor")
    fi
  done

  log "  Versões Python uv instaladas: ${minor_versions[*]}"
  local output rc
  output="$(uv python upgrade "${minor_versions[@]}" 2>&1)"
  rc=$?
  printf '%s\n' "$output" | tee >(_strip_ansi >> "$LOG_FILE")
  return "$rc"
}


update_uv_tools() {
  local output rc

  output="$(uv tool upgrade --all 2>&1)"
  rc=$?
  printf '%s\n' "$output" | tee >(_strip_ansi >> "$LOG_FILE")

  if (( rc != 0 )); then
    if grep -qi 'no tools installed\|nothing to upgrade' <<<"$output"; then
      log "  Sem ferramentas uv para atualizar."
      return 0
    fi
    return "$rc"
  fi

  return 0
}


update_poetry() {
  local latest core_req
  latest="$(
    python -m pip list --user --outdated --format=json 2>/dev/null | python -c '
import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for pkg in data:
    if pkg.get("name") == "poetry":
        print(pkg.get("latest", ""))
'
  )"

  core_req="$(
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
  )"

  if [[ -z "${latest//[[:space:]]/}" ]]; then
    log "  Poetry ja está na versão mais recente (via pip --user)."
  else
    run_logged python -m pip install --user --break-system-packages --upgrade poetry || return $?
  fi

  if [[ -n "${core_req//[[:space:]]/}" ]]; then
    log "  Garantindo poetry-core compatível com Poetry: ${core_req}"
    run_logged python -m pip install --user --break-system-packages "$core_req"
  fi
}


