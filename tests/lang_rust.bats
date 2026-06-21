#!/usr/bin/env bats
# tests/lang_rust.bats — helpers puros do audit de toolchain Rust (K3).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_rust.sh"
}

@test "rustup_check_has_update: detecta update disponível" {
  out='stable-x86_64-unknown-linux-gnu - Update available : 1.96.0 -> 1.97.0
rustup - Up to date : 1.29.0'
  run rustup_check_has_update "$out"
  [ "$status" -eq 0 ]
}

@test "rustup_check_has_update: tudo up to date => sem update" {
  out='stable-x86_64-unknown-linux-gnu - Up to date : 1.96.0
rustup - Up to date : 1.29.0'
  run rustup_check_has_update "$out"
  [ "$status" -ne 0 ]
}

@test "rustup_check_has_update: saída vazia => sem update" {
  run rustup_check_has_update ""
  [ "$status" -ne 0 ]
}
