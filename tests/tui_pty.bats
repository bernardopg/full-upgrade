#!/usr/bin/env bats
# tests/tui_pty.bats — o --config-tui num pseudo-terminal real (tests/tui_pty.py):
# laço principal, raw mode, prompt de valor, popup de detalhe, filtro, revisão,
# gravação e confirmação de descarte. O config é um arquivo descartável.

load test_helper

setup() {
  CFG="$BATS_TEST_TMPDIR/cfg/config"; mkdir -p "${CFG%/*}"
  PTY="${BATS_TEST_DIRNAME}/tui_pty.py"
}

_tui() { timeout 240 python3 -I "$PTY" "$CFG" "$@"; }

@test "tui pty: steps com toggle, detalhe, filtro e descarte confirmado" {
  run _tui 1 j ' ' d x / a '\x7f' '\x1b' '\x1b[B' '\x1b[6~' '\x1b[5~' '\x1b[H' '\x1b[F' '\x1b' q y
  [ "$status" -eq 0 ]
  [[ "$output" == *"categoria/efeito"* ]]
  [[ "$output" == *"Descartar 1 altera"* ]]
  [ ! -e "$CFG" ]
}

@test "tui pty: parâmetro com valor inválido e válido, revisão e gravação" {
  run _tui 2 j j j j '\r' 'abc\r' '\r' '5\r' '\r' '/tmp/artcraft\r' s j k '\r' q
  [ "$status" -eq 0 ]
  [[ "$output" == *"inteiro esperado"* ]]
  grep -q '^SNAPSHOT_MIN_FREE_GIB=5' "$CFG"
}

@test "tui pty: menu por número, ajuda, salvar sem pendência e Ctrl-D" {
  run _tui 4 3 '\r' '\x04'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a salvar"* ]]
}

# Ctrl-C chega como SIGINT: o TUI precisa restaurar o terminal E sair (130).
# Antes a trap só restaurava e o laço seguia rodando fora do raw mode.
@test "tui pty: Ctrl-C restaura o terminal e sai com 130" {
  run _tui 1 '\x03' 1
  [ "$status" -eq 130 ]
  [[ "$output" == *$'\e[?1049l'* ]]
}

@test "tui pty: sair com pendência pelo menu recusa e depois aceita o descarte" {
  run _tui 1 ' ' '\x1b' 5 n '\x1b[B' '\x1b[B' '\x1b[B' '\x1b[B' '\r' y
  [ "$status" -eq 0 ]
  [ ! -e "$CFG" ]
}

@test "tui pty: enum por Enter e por setas; Enter no item Salvar do menu" {
  run _tui 2 j j '\r' '\x1b[C' '\x1b[D' '\x1b' '\x1b[B' '\x1b[B' '\x1b[B' '\r' '\r' q
  [ "$status" -eq 0 ]
  [ -s "$CFG" ]
}
