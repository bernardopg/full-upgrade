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

@test "update_rustup: falha de rede no check não vira falso up-to-date" {
  run_network_cmd() { printf '%s\n' 'Network is unreachable'; return "$RC_WARN"; }

  run update_rustup

  [ "$status" -eq "$RC_WARN" ]
}

@test "update_rustup: check bem-sucedido e sem update retorna ok" {
  run_network_cmd() { printf '%s\n' 'rustup - Up to date : 1.29.0'; }

  run update_rustup

  [ "$status" -eq 0 ]
}

@test "K4: bin com memo nofix fresco => conhecido (rc 0)" {
  install_list='cargo-outdated v0.19.0:
    cargo-outdated
cargo-audit v0.22.2:
    cargo-audit'
  memo='cargo-outdated	0.19.0	1000'
  run cargo_cve_bins_all_memo_known "cargo-outdated" "$install_list" "$memo" 1001 7
  [ "$status" -eq 0 ]
}

@test "K4: versão nova sem memo => desconhecido (rc 1)" {
  install_list='cargo-outdated v0.20.0:
    cargo-outdated'
  memo='cargo-outdated	0.19.0	1000'
  run cargo_cve_bins_all_memo_known "cargo-outdated" "$install_list" "$memo" 1001 7
  [ "$status" -ne 0 ]
}

@test "K4: memo expirado => desconhecido (rc 1)" {
  install_list='cargo-outdated v0.19.0:
    cargo-outdated'
  memo='cargo-outdated	0.19.0	1000'
  run cargo_cve_bins_all_memo_known "cargo-outdated" "$install_list" "$memo" $((1000 + 8 * 86400)) 7
  [ "$status" -ne 0 ]
}

@test "K4: bin sem crate correspondente => desconhecido (rc 1)" {
  install_list='cargo-audit v0.22.2:
    cargo-audit'
  memo='cargo-outdated	0.19.0	1000'
  run cargo_cve_bins_all_memo_known "cargo-outdated" "$install_list" "$memo" 1001 7
  [ "$status" -ne 0 ]
}

@test "K4: lista vazia => conhecido (rc 0)" {
  run cargo_cve_bins_all_memo_known "" "" "" 1001 7
  [ "$status" -eq 0 ]
}
