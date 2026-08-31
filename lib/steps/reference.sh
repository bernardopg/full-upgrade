#!/usr/bin/env bash
# lib/steps/reference.sh — atualização de caches de ferramentas de referência.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module

# Atualiza o cache local do Tealdeer (`tldr`). A operação baixa apenas páginas
# de referência configuradas pelo próprio usuário; não atualiza o pacote nem
# altera arquivos do sistema. Falhas da rede ou do cliente são não bloqueantes,
# pois um cache anterior continua utilizável offline.
update_tldr_cache() {
  has tldr || { log "  tldr não encontrado."; return 0; }

  log "  Atualizando cache local do tldr…"
  local out rc
  out="$(run_network_cmd tldr --update 2>&1)"
  rc=$?
  [[ -n "$out" ]] && log "  ${out//$'\n'/ }"

  if (( rc == 0 )); then
    log "  Cache local do tldr atualizado."
    return 0
  fi

  # O portão de conectividade já classifica DNS/conectividade como RC_WARN.
  # Erros locais do cliente também não podem derrubar todo o upgrade: o cache
  # existente segue disponível e a correção não é automaticamente segura.
  log "  Não foi possível atualizar o cache do tldr; o cache atual foi preservado."
  return "$RC_WARN"
}
