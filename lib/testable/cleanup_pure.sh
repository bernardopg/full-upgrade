#!/usr/bin/env bash
# lib/testable/cleanup_pure.sh — funções puras extraídas de lib/steps/cleanup.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# snapshot_keep_count — retorna quantos snapshots manter (default 5, valida inteiro > 0)
snapshot_keep_count() {
  local keep="${SNAPSHOT_KEEP:-5}"
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || keep=5
  printf '%s' "$keep"
}

# snapper_full_upgrade_ids_to_delete — IDs de snapshots full-upgrade antigos a remover (mantém os N mais recentes)
snapper_full_upgrade_ids_to_delete() {
  local keep="$1"
  local -a ids=()
  local id rest
  while IFS='|' read -r id rest; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    [[ "$rest" == *"full-upgrade pré-upgrade"* ]] || continue
    ids+=("$id")
  done
  local n=${#ids[@]} limit
  limit=$(( n - keep ))
  (( limit > 0 )) || return 0
  printf '%s\n' "${ids[@]:0:$limit}"
}

# timeshift_full_upgrade_names_to_delete — nomes de snapshots timeshift full-upgrade antigos a remover
timeshift_full_upgrade_names_to_delete() {
  local keep="$1"
  local -a names=()
  local line name
  while IFS= read -r line; do
    [[ "$line" == *"full-upgrade pré-upgrade"* ]] || continue
    if [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}) ]]; then
      name="${BASH_REMATCH[1]}"
      names+=("$name")
    fi
  done
  local n=${#names[@]} limit
  limit=$(( n - keep ))
  (( limit > 0 )) || return 0
  printf '%s\n' "${names[@]:0:$limit}"
}

# pending_is_held_cluster — verifica se pacote faz parte de cluster de rebuild upstream (Haskell/GHC)
pending_is_held_cluster() {
  local name="$1"
  [[ "$name" =~ ^(haskell-|ghc(-|$)|cabal-install$|stack$|hlint$|stylish-haskell$|happy$|alex$) ]]
}

# final_pending_reason — mensagem de razão final baseada em contagens
final_pending_reason() {
  local official="$1" aur="$2"
  if (( official > 0 )); then
    printf '%s pacote(s) oficial(is) pendente(s) após sincronização da base; rode sudo pacman -Syu' "$official"
  elif (( aur > 0 )); then
    printf '%s pacote(s) AUR pendente(s); rode paru -Syu' "$aur"
  else
    printf 'nenhuma atualização pendente'
  fi
}
