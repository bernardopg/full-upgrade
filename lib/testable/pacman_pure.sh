#!/usr/bin/env bash
# lib/testable/pacman_pure.sh — funções puras extraídas de steps/pacman.sh

# _AUR_NETWORK_RE — regex de erros de rede transitórios
_AUR_NETWORK_RE='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect|temporary failure'

# _AUR_TRANSIENT_SRC_RE — regex de falhas de download/integridade de fontes AUR
_AUR_TRANSIENT_SRC_RE='não passaram na verificação de validade|did not pass the validity check|FALHOU|one or more files did not pass|falha ao baixar fontes|failure while downloading|error downloading sources'
# aur_ignore_args — gera args --ignore para cada pacote em FULL_UPGRADE_AUR_IGNORE
# NOTA: versão original em lib/core.sh — duplicada aqui para isolamento de teste
aur_ignore_args() {
  local item
  [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]] || return 0
  for item in $FULL_UPGRADE_AUR_IGNORE; do
    [[ -n "$item" ]] || continue
    printf '%s\n' "--ignore=${item}"
  done
}

# pending_is_held_cluster — pacotes segurados por rebuild upstream (Haskell/GHC)
pending_is_held_cluster() {
  local name="$1"
  [[ "$name" =~ ^(haskell-|ghc(-|$)|cabal-install$|stack$|hlint$|stylish-haskell$|happy$|alex$) ]]
}

# final_pending_reason — razão textual para pacotes pendentes
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

# _purge_aur_partial_sources — lista de padrões de arquivos a remover (puro, testável)
_purge_aur_partial_sources_patterns() {
  printf '%s\n' '*.part' '*.tar.*' '*.tgz' '*.zip' '*.deb' '*.rpm' '*.AppImage' '*.appimage' '*.gz' '*.xz' '*.bz2' '*.zst'
}