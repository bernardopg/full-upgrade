#!/usr/bin/env bats
# tests/cleanup_codex_tmp.bats — regressão de cleanup_codex_plugin_tmp
#
# O Codex vaza um clone bare git-* em ~/.codex/.tmp a cada tentativa de refresh
# de marketplace de plugins (medido: ~9,5 mil dirs / 23 GiB). O step remove só
# os mais antigos que CODEX_TMP_KEEP_DAYS e nunca falha o run por causa deles
# (falha operacional real vira warn, nunca todo/fail).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"
  # `log` escreveria em terminal/log; silencioso nos testes.
  log() { :; }
  log_stream() { cat >/dev/null; }
  # Isola o diretório temporário para não tocar no ~/.codex/.tmp real.
  CODEX_TMP_DIR="$BATS_TEST_TMPDIR/codex-tmp"
  export CODEX_TMP_DIR
  mkdir -p "$CODEX_TMP_DIR"
}

mk_git_tmp() { # mk_git_tmp <nome> [idade em dias]
  local d="$CODEX_TMP_DIR/$1"
  mkdir -p "$d/objects" "$d/refs"
  touch "$d/HEAD"
  if [[ -n "${2:-}" ]]; then
    touch -d "$2 days ago" "$d"
  fi
}

@test "codex_tmp_dirs_to_delete: lista só git-* mais antigos que keep" {
  mk_git_tmp git-old 10
  mk_git_tmp git-recent
  mk_git_tmp outro-dir 10   # nome fora do padrão: ignorado
  touch -d "10 days ago" "$CODEX_TMP_DIR/git-file"  # arquivo, não dir: ignorado

  run codex_tmp_dirs_to_delete "$CODEX_TMP_DIR" 1
  [ "$status" -eq 0 ]
  grep -q "git-old" <<<"$output"
  ! grep -q "git-recent" <<<"$output"
  ! grep -q "outro-dir" <<<"$output"
  ! grep -q "git-file" <<<"$output"
}

@test "codex_tmp_dirs_to_delete: keep inválido usa default 1" {
  mk_git_tmp git-old 5
  mk_git_tmp git-today

  run codex_tmp_dirs_to_delete "$CODEX_TMP_DIR" "banana"
  [ "$status" -eq 0 ]
  grep -q "git-old" <<<"$output"
  ! grep -q "git-today" <<<"$output"
}

@test "codex_tmp_dirs_to_delete: diretório inexistente devolve vazio sem erro" {
  run codex_tmp_dirs_to_delete "$BATS_TEST_TMPDIR/nao-existe" 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cleanup_codex_plugin_tmp: remove velhos, preserva recentes, retorna ok" {
  mk_git_tmp git-velho1 10
  mk_git_tmp git-velho2 3
  mk_git_tmp git-recente
  mkdir -p "$CODEX_TMP_DIR/marketplaces"  # conteúdo real: intocado
  CODEX_TMP_KEEP_DAYS=1
  export CODEX_TMP_KEEP_DAYS

  run cleanup_codex_plugin_tmp
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_TMP_DIR/git-velho1" ]
  [ ! -e "$CODEX_TMP_DIR/git-velho2" ]
  [ -d "$CODEX_TMP_DIR/git-recente" ]
  [ -d "$CODEX_TMP_DIR/marketplaces" ]
}

@test "cleanup_codex_plugin_tmp: sem temp dirs velhos retorna ok sem remover nada" {
  mk_git_tmp git-recente
  CODEX_TMP_KEEP_DAYS=7
  export CODEX_TMP_KEEP_DAYS

  run cleanup_codex_plugin_tmp
  [ "$status" -eq 0 ]
  [ -d "$CODEX_TMP_DIR/git-recente" ]
}

@test "cleanup_codex_plugin_tmp: diretório ausente retorna ok sem ruído" {
  CODEX_TMP_DIR="$BATS_TEST_TMPDIR/nao-existe"
  export CODEX_TMP_DIR

  run cleanup_codex_plugin_tmp
  [ "$status" -eq 0 ]
}

@test "cleanup_codex_plugin_tmp: falha de remoção vira warn, nunca fail" {
  mk_git_tmp git-velho 10
  CODEX_TMP_KEEP_DAYS=1
  export CODEX_TMP_KEEP_DAYS
  # Mockar `rm` envenenaria a limpeza do BATS_TEST_TMPDIR; a falha entra um
  # nível acima, no wrapper que o step usa para a remoção.
  run_logged() { return 1; }
  export -f run_logged

  run cleanup_codex_plugin_tmp
  [ "$status" -eq "$RC_WARN" ]
  [ -d "$CODEX_TMP_DIR/git-velho" ]
}
