#!/usr/bin/env bats
# tests/omz_plugins_cov.bats — update_omz_custom_plugins com repositórios git
# descartáveis: plugin atualizado, já em dia, sem .git, com conflito pendente e
# com upstream inalcançável. Tudo vive em $BATS_TEST_TMPDIR, com a config
# global do git isolada.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/shell.sh"
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email t@t; git config --global user.name t
  git config --global init.defaultBranch main
  export ZSH="$BATS_TEST_TMPDIR/omz"
  PLUG="$ZSH/custom/plugins"; mkdir -p "$PLUG/example" "$PLUG/semgit"
}

# Cria upstream/<nome> com um commit e clona em plugins/<nome>.
_plugin() {
  local name="$1"
  git init -q "$BATS_TEST_TMPDIR/up/$name"
  git -C "$BATS_TEST_TMPDIR/up/$name" commit -q --allow-empty -m one
  git clone -q "$BATS_TEST_TMPDIR/up/$name" "$PLUG/$name"
}

@test "omz_plugins: sem diretório de plugins não faz nada" {
  ZSH="$BATS_TEST_TMPDIR/nada" run update_omz_custom_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "omz_plugins: atualiza o atrasado, mantém o em dia e lista os sem git" {
  _plugin atrasado; _plugin emdia
  git -C "$BATS_TEST_TMPDIR/up/atrasado" commit -q --allow-empty -m two
  run update_omz_custom_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"atrasado: 1 commit(s) atrás"* ]]
  [[ "$output" == *"emdia: já atualizado"* ]]
  [[ "$output" == *"Não são repositórios git (ignorados): semgit"* ]]
  [ "$(git -C "$PLUG/atrasado" log -1 --format=%s)" = two ]
}

@test "omz_plugins: upstream removido conta como falha" {
  _plugin orfao
  rm -rf "$BATS_TEST_TMPDIR/up/orfao"
  run update_omz_custom_plugins
  [ "$status" -eq 1 ]
  [[ "$output" == *"fetch falhou para plugin orfao"* ]]
}

@test "omz_plugins: conflito pendente adia o update e vira TODO" {
  _plugin conflito
  git_has_unmerged() { [[ "$1" == *conflito* ]]; }
  update_omz_custom_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "plugin(s) com modificações locais: conflito" ]
}

@test "omz_plugins: queda de rede no fetch vira warn" {
  _plugin rede
  git_fetch_full() { echo "fatal: unable to access: Could not resolve host: github.com"; return 128; }
  update_omz_custom_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "rede indisponível ao buscar plugins (1 afetados)" ]]
}
