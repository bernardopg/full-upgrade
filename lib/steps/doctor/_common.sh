#!/usr/bin/env bash
# lib/steps/doctor/_common.sh — helpers compartilhados entre checks do doctor (sem side-effects de domínio).
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash


# Doctors são despachados sem gate de SUDO_READY em main.sh; os que precisam
# de privilégio checam aqui se há credencial SEM prompt. Sem isto, um run
# não-interativo sem sudo cacheado dispararia um prompt de senha que ninguém
# responde e cada step travaria até o timeout (#16).
_doctor_sudo_ok() {
  local priv="${PRIV_CMD:-sudo}"
  has "$priv" && "$priv" -n true >/dev/null 2>&1
}



# ── Helpers puros (testáveis isoladamente; sem side-effects) ──────────────────
# Classifica uso percentual de disco/inodes em severidade textual.
# >=95 => "todo"; >=90 => "warn"; senão "ok". Não-numérico => "ok".
usage_pct_severity() {
  local pct="${1%%%}"
  [[ "$pct" =~ ^[0-9]+$ ]] || { printf "ok"; return 0; }
  if   (( pct >= 95 )); then printf "todo"
  elif (( pct >= 90 )); then printf "warn"
  else                       printf "ok"
  fi
}


# Classifica código HTTP: 2xx/3xx => "ok"; resto/vazio => "fail".
http_code_class() {
  [[ "$1" =~ ^[23] ]] && printf "ok" || printf "fail"
}
