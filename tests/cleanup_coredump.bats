#!/usr/bin/env bats
# tests/cleanup_coredump.bats — regressão de cleanup_old_coredumps (limpeza de coredumps)
#
# Dumps transitórios acumulam GB em /var/lib/systemd/coredump sem limite; o
# step remove só os mais antigos que COREDUMP_KEEP_DAYS e nunca falha o run
# por causa deles (falha operacional real vira warn, nunca todo/fail).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"
  # `log` escreveria em terminal/log; silencioso nos testes.
  log() { :; }
  # `sudo` real exigiria credencial: os arquivos de teste são do usuário.
  sudo() { "$@"; }
  # Isola o diretório de dumps para não tocar em /var/lib real.
  COREDUMP_DIR="$BATS_TEST_TMPDIR/coredump"
  export COREDUMP_DIR
  mkdir -p "$COREDUMP_DIR"
}

@test "coredump_files_to_delete: lista só arquivos mais antigos que keep" {
  touch -d "10 days ago" "$COREDUMP_DIR/core.ffmpeg.old"
  touch "$COREDUMP_DIR/core.ffmpeg.recent"
  mkdir -p "$COREDUMP_DIR/sub"
  touch -d "10 days ago" "$COREDUMP_DIR/sub/core.ffmpeg.nested"

  run coredump_files_to_delete "$COREDUMP_DIR" 7
  [ "$status" -eq 0 ]
  grep -q "core.ffmpeg.old" <<<"$output"
  ! grep -q "recent" <<<"$output"
  ! grep -q "nested" <<<"$output"
}

@test "coredump_files_to_delete: keep inválido usa default 7" {
  touch -d "10 days ago" "$COREDUMP_DIR/core.old"
  touch -d "3 days ago" "$COREDUMP_DIR/core.mid"

  run coredump_files_to_delete "$COREDUMP_DIR" "banana"
  [ "$status" -eq 0 ]
  grep -q "core.old" <<<"$output"
  ! grep -q "core.mid" <<<"$output"
}

@test "coredump_files_to_delete: diretório inexistente devolve vazio sem erro" {
  run coredump_files_to_delete "$BATS_TEST_TMPDIR/nao-existe" 7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cleanup_old_coredumps: remove velhos, preserva recentes, retorna ok" {
  touch -d "10 days ago" "$COREDUMP_DIR/core.ffmpeg.1"
  touch -d "10 days ago" "$COREDUMP_DIR/core.ffmpeg.2"
  touch "$COREDUMP_DIR/core.ffmpeg.recent"
  COREDUMP_KEEP_DAYS=7
  export COREDUMP_KEEP_DAYS

  run cleanup_old_coredumps
  [ "$status" -eq 0 ]
  [ ! -e "$COREDUMP_DIR/core.ffmpeg.1" ]
  [ ! -e "$COREDUMP_DIR/core.ffmpeg.2" ]
  [ -f "$COREDUMP_DIR/core.ffmpeg.recent" ]
}

@test "cleanup_old_coredumps: sem dumps velhos retorna ok sem remover nada" {
  touch "$COREDUMP_DIR/core.ffmpeg.recent"
  COREDUMP_KEEP_DAYS=7
  export COREDUMP_KEEP_DAYS

  run cleanup_old_coredumps
  [ "$status" -eq 0 ]
  [ -f "$COREDUMP_DIR/core.ffmpeg.recent" ]
}

@test "cleanup_old_coredumps: sem coredumpctl retorna ok sem ruído" {
  has() { return 1; }
  export -f has
  touch -d "10 days ago" "$COREDUMP_DIR/core.ffmpeg.1"

  run cleanup_old_coredumps
  [ "$status" -eq 0 ]
  [ -f "$COREDUMP_DIR/core.ffmpeg.1" ]
}

@test "cleanup_old_coredumps: falha na remoção vira warn, nunca fail" {
  sudo() { return 1; }
  export -f sudo
  touch -d "10 days ago" "$COREDUMP_DIR/core.ffmpeg.1"
  COREDUMP_KEEP_DAYS=7
  export COREDUMP_KEEP_DAYS

  run cleanup_old_coredumps
  [ "$status" -eq "$RC_WARN" ]
  [ -f "$COREDUMP_DIR/core.ffmpeg.1" ]
}
