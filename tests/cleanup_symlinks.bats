#!/usr/bin/env bats
# tests/cleanup_symlinks.bats — cleanup_broken_symlinks_local_bin com um
# ~/.local/bin falso em $BATS_TEST_TMPDIR. Usa o find real: o bug que estes
# testes cobrem era justamente um predicado que o find rejeitava.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"
  log() { printf '%s\n' "$*"; }
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$HOME/.local/bin"
  mkdir -p "$BIN"
}

@test "symlinks: remove o quebrado e mantém o válido e o arquivo comum" {
  : >"$BIN/real"
  ln -s "$BIN/real" "$BIN/ok"
  ln -s "$BIN/sumiu" "$BIN/cr"
  run cleanup_broken_symlinks_local_bin
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removendo symlink quebrado: $BIN/cr"* ]]
  [[ "$output" == *"removidos de ~/.local/bin: 1"* ]]
  [ ! -L "$BIN/cr" ]
  [ -L "$BIN/ok" ]
  [ -f "$BIN/real" ]
}

@test "symlinks: sem quebrados não remove nada" {
  : >"$BIN/real"
  ln -s "$BIN/real" "$BIN/ok"
  run cleanup_broken_symlinks_local_bin
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem symlinks quebrados"* ]]
  [ -L "$BIN/ok" ]
}

@test "symlinks: symlink relativo quebrado também é removido" {
  ln -s ../nada/bin "$BIN/rel"
  run cleanup_broken_symlinks_local_bin
  [ "$status" -eq 0 ]
  [ ! -L "$BIN/rel" ]
}

@test "symlinks: não desce para subdiretórios" {
  mkdir -p "$BIN/sub"
  ln -s "$BIN/sumiu" "$BIN/sub/quebrado"
  run cleanup_broken_symlinks_local_bin
  [ "$status" -eq 0 ]
  [ -L "$BIN/sub/quebrado" ]
}

@test "symlinks: ~/.local/bin ausente => 0" {
  rm -rf "$BIN"
  run cleanup_broken_symlinks_local_bin
  [ "$status" -eq 0 ]
}
