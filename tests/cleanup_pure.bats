#!/usr/bin/env bats
# tests/cleanup_pure.bats — testes para funções puras de lib/testable/cleanup_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/cleanup_pure.sh"
}

@test "snapshot_keep_count: default é 5" {
  unset SNAPSHOT_KEEP
  run snapshot_keep_count
  [ "$output" = "5" ]
}

@test "snapshot_keep_count: valor válido é preservado" {
  SNAPSHOT_KEEP=3
  run snapshot_keep_count
  [ "$output" = "3" ]
}

@test "snapshot_keep_count: zero cai para 5" {
  SNAPSHOT_KEEP=0
  run snapshot_keep_count
  [ "$output" = "5" ]
}

@test "snapshot_keep_count: não-numérico cai para 5" {
  SNAPSHOT_KEEP=abc
  run snapshot_keep_count
  [ "$output" = "5" ]
}

@test "snapper_full_upgrade_ids_to_delete: mantém N mais recentes" {
  input=$'1|manual\n2|full-upgrade pré-upgrade 2026-01-01\n3|full-upgrade pré-upgrade 2026-01-02\n4|full-upgrade pré-upgrade 2026-01-03\n5|full-upgrade pré-upgrade 2026-01-04'
  run bash -c 'source '"${FU_LIB}"'/testable/cleanup_pure.sh; snapper_full_upgrade_ids_to_delete 2 <<< "$1"' _ "$input"
  [ "$status" -eq 0 ]
  [ "$output" = "2"$'\n'"3" ]
}

@test "snapper_full_upgrade_ids_to_delete: ignora linhas não-full-upgrade" {
  input=$'1|manual snapshot\n2|full-upgrade pré-upgrade 2026-01-01\n3|outro\n4|full-upgrade pré-upgrade 2026-01-02'
  run bash -c 'source '"${FU_LIB}"'/testable/cleanup_pure.sh; snapper_full_upgrade_ids_to_delete 1 <<< "$1"' _ "$input"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "timeshift_full_upgrade_names_to_delete: mantém N mais recentes" {
  input=$'snap1 2026-01-01\nfull-upgrade pré-upgrade 2026-01-02\nfull-upgrade pré-upgrade 2026-01-03\nfull-upgrade pré-upgrade 2026-01-04'
  run bash -c 'source '"${FU_LIB}"'/testable/cleanup_pure.sh; timeshift_full_upgrade_names_to_delete 2 <<< "$1"' _ "$input"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "pending_is_held_cluster: haskell-* é cluster" {
  run pending_is_held_cluster "haskell-lens"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: ghc é cluster" {
  run pending_is_held_cluster "ghc"
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

@test "final_pending_reason: nenhum pendente" {
  run final_pending_reason 0 0
  [ "$output" = "nenhuma atualização pendente" ]
}