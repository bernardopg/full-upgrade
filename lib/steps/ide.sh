#!/usr/bin/env bash
# lib/steps/ide.sh — atualização de extensões de IDEs da família VSCode (H3).
# Sourced por full-upgrade.sh (glob de steps). Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Helper puro: conta quantas extensões foram atualizadas a partir da saída de
# `<cli> --update-extensions`. Lê stdin, emite (stdout) o número. A linha de
# sucesso do VSCode é "Extension '...' vX was successfully updated.".
count_ext_updates() {
  grep -ciE 'successfully updated' || true
}

# Lista os CLIs de IDE a tratar: IDE_EXT_CLIS (separado por espaço) ou, sem ele,
# o conjunto conhecido (code, cursor, codium, code-insiders, vscodium).
_ide_ext_clis() {
  if [[ -n "${IDE_EXT_CLIS:-}" ]]; then
    printf '%s\n' $IDE_EXT_CLIS
  else
    printf '%s\n' code cursor codium code-insiders vscodium
  fi
}

# H3 — atualiza as extensões instaladas de cada IDE da família VSCode presente.
# Usa `<cli> --update-extensions` (VSCode 1.86+, suportado também por cursor/
# codium). Read/rede: falha de rede vira RC_WARN; nenhum CLI presente → 0 (o
# main.sh já pula via has). Best-effort: erro num CLI não impede os demais, mas
# o step termina em RC_WARN se algum falhar.
update_ide_extensions() {
  local -a clis=()
  mapfile -t clis < <(_ide_ext_clis)

  local cli found=0 status=0 out rc updated total=0
  for cli in "${clis[@]}"; do
    has "$cli" || continue
    found=1
    log "  Atualizando extensões de ${cli}..."
    out="$(run_network_cmd "$cli" --update-extensions)"
    rc=$?
    if (( rc == RC_WARN )); then
      log "  ${cli}: falha de rede ao atualizar extensões."
      (( status == 0 )) && status="$RC_WARN"
      continue
    fi
    if (( rc != 0 )); then
      log "  ${cli}: erro ao atualizar extensões (rc=${rc})."
      (( status == 0 )) && status="$RC_WARN"
      continue
    fi
    updated="$(printf '%s\n' "$out" | count_ext_updates)"
    total=$(( total + updated ))
    log "  ${cli}: ${updated} extensão(ões) atualizada(s)."
  done

  if (( found == 0 )); then
    log "  Nenhum IDE da família VSCode encontrado."
    return 0
  fi
  log "  Total de extensões atualizadas: ${total}."
  (( status == RC_WARN )) && STEP_REASON="falha de rede ao atualizar extensões de IDE"
  return "$status"
}
