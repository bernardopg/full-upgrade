#!/usr/bin/env bash
# lib/steps/manual_apps.sh — helpers compartilhados pelos steps de programas
# instalados FORA de qualquer gerenciador de pacotes (sem pacman/AUR/flatpak/
# snap por trás). Os steps em si vivem no arquivo do seu domínio: CLIs de IA em
# ai.sh, segurança em security.sh, utilitários em tools.sh, e o inventário
# read-only em doctor/packages.sh (Série T4).
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

_manual_write_prefix() {
  local target="$1" dir
  dir="$(dirname "$target")"
  if [[ -w "$target" && -w "$dir" ]]; then
    printf ''
    return 0
  fi
  if has sudo && sudo -n true 2>/dev/null; then
    printf 'sudo'
    return 0
  fi
  return 1
}

# ── CLIs com update nativo que já checa sozinho ──────────────────────────────
# `pool update` (Poolside, ~/.local/bin/pool) e `purple update` comparam a versão
# instalada com a última release, verificam checksum e só baixam se houver
# novidade; atualizados, apenas dizem "already at vX". Não há --check separado,
# então chamar o update direto já é idempotente. rc: 0 ok · RC_WARN rede/falha.
_selfupdate_direct() {
  local label="$1" bin="$2"
  shift 2
  has "$bin" || { log "  ${label} não encontrado."; return 0; }
  local out rc
  out="$(run_network_cmd "$bin" update "$@")"
  rc=$?
  printf '%s\n' "$out" | log_out
  if ((rc != 0)); then
    log "  Falha ao atualizar o ${label}."
    STEP_REASON="${bin} update falhou (rc=${rc})"
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  return 0
}
