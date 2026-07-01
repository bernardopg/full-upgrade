#!/usr/bin/env bats
# tests/pacman_pure.bats — testes para funções puras de lib/testable/pacman_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/pacman_pure.sh"
}

@test "_AUR_NETWORK_RE: contém padrões de rede" {
  [[ "$_AUR_NETWORK_RE" == *"name or service not known"* ]]
  [[ "$_AUR_NETWORK_RE" == *"connection timed out"* ]]
  [[ "$_AUR_NETWORK_RE" == *"connection refused"* ]]
}

@test "_AUR_TRANSIENT_SRC_RE: contém padrões de checksum/download" {
  [[ "$_AUR_TRANSIENT_SRC_RE" == *"did not pass the validity check"* ]]
  [[ "$_AUR_TRANSIENT_SRC_RE" == *"error downloading sources"* ]]
}

@test "aur_ignore_args: lista vazia não produz saída" {
  FULL_UPGRADE_AUR_IGNORE=""
  run aur_ignore_args
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "aur_ignore_args: um pacote gera --ignore" {
  FULL_UPGRADE_AUR_IGNORE="foo"
  run aur_ignore_args
  [ "$output" = "--ignore=foo" ]
}

@test "aur_ignore_args: múltiplos pacotes geram múltiplos --ignore" {
  FULL_UPGRADE_AUR_IGNORE="foo bar baz"
  run aur_ignore_args
  [ "${lines[0]}" = "--ignore=foo" ]
  [ "${lines[1]}" = "--ignore=bar" ]
  [ "${lines[2]}" = "--ignore=baz" ]
}

@test "aur_out_of_date_pkgs: extrai saída PT-BR do paru" {
  out=$':: marcado como desatualizado: apple-fonts  github-desktop  quickshell-git\nRepositorio (1) tmux'
  run aur_out_of_date_pkgs <<<"$out"
  [ "${lines[0]}" = "apple-fonts" ]
  [ "${lines[1]}" = "github-desktop" ]
  [ "${lines[2]}" = "quickshell-git" ]
}

@test "aur_out_of_date_pkgs: extrai formatos em inglês" {
  out=$':: marked out-of-date: foo bar\n:: flagged out-of-date: baz'
  run aur_out_of_date_pkgs <<<"$out"
  [ "${lines[0]}" = "bar" ]
  [ "${lines[1]}" = "baz" ]
  [ "${lines[2]}" = "foo" ]
}

@test "aur_out_of_date_pkgs: sem marcador não emite nada" {
  run aur_out_of_date_pkgs <<<"nada para fazer"
  [ -z "$output" ]
}

@test "pending_is_held_cluster: haskell-* é cluster" {
  run pending_is_held_cluster "haskell-lens"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: ghc* é cluster" {
  run pending_is_held_cluster "ghc"
  [ "$status" -eq 0 ]
  run pending_is_held_cluster "ghc-libs"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: cabal-install é cluster" {
  run pending_is_held_cluster "cabal-install"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: stack é cluster" {
  run pending_is_held_cluster "stack"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: hlint é cluster" {
  run pending_is_held_cluster "hlint"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: pacote normal não é cluster" {
  run pending_is_held_cluster "linux"
  [ "$status" -ne 0 ]
}

@test "final_pending_reason: apenas oficiais" {
  run final_pending_reason 3 0
  [ "$output" = "3 pacote(s) oficial(is) pendente(s) após sincronização da base; rode sudo pacman -Syu" ]
}

@test "final_pending_reason: apenas AUR" {
  run final_pending_reason 0 2
  [ "$output" = "2 pacote(s) AUR pendente(s); rode paru -Syu" ]
}

@test "final_pending_reason: nenhum" {
  run final_pending_reason 0 0
  [ "$output" = "nenhuma atualização pendente" ]
}

@test "_purge_aur_partial_sources_patterns: lista extensões esperadas" {
  run _purge_aur_partial_sources_patterns
  [[ "$output" == *"*.part"* ]]
  [[ "$output" == *"*.tar.*"* ]]
  [[ "$output" == *"*.AppImage"* ]]
  [[ "$output" == *"*.zip"* ]]
}
