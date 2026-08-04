#!/usr/bin/env bats
# tests/editor_shell_plugins.bats — realinhamento de plugins Zsh após force-push
# upstream. Usa repositórios git de verdade em $BATS_TEST_TMPDIR (nada fora dele).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/editor_shell.sh"

  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.email "test@example.com"
  git config --global user.name "Test"
  git config --global init.defaultBranch main

  UPSTREAM="${BATS_TEST_TMPDIR}/upstream"
  CLONE="${BATS_TEST_TMPDIR}/clone"

  git init --quiet --bare "$UPSTREAM"
  git clone --quiet "$UPSTREAM" "${BATS_TEST_TMPDIR}/seed"
  echo "v1" > "${BATS_TEST_TMPDIR}/seed/file"
  git -C "${BATS_TEST_TMPDIR}/seed" add file
  git -C "${BATS_TEST_TMPDIR}/seed" commit --quiet -m "v1"
  git -C "${BATS_TEST_TMPDIR}/seed" push --quiet origin main

  git clone --quiet "$UPSTREAM" "$CLONE"
  git -C "$CLONE" remote set-head origin main
}

# Reescreve o histórico do upstream, deixando o clone divergente (o cenário do
# force-push que fazia `pull --ff-only` falhar e o step inteiro virar fail).
force_push_upstream() {
  echo "v2" > "${BATS_TEST_TMPDIR}/seed/file"
  git -C "${BATS_TEST_TMPDIR}/seed" add file
  git -C "${BATS_TEST_TMPDIR}/seed" commit --quiet --amend -m "v2"
  git -C "${BATS_TEST_TMPDIR}/seed" push --quiet --force origin main
  git -C "$CLONE" fetch --quiet --force origin
}

@test "plugin_realign_to_upstream: árvore limpa é realinhada em origin/HEAD" {
  force_push_upstream

  run plugin_realign_to_upstream "$CLONE" "plugin-teste"
  [ "$status" -eq 0 ]

  [ "$(cat "${CLONE}/file")" = "v2" ]
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse origin/main)" ]
}

@test "plugin_realign_to_upstream: HEAD anterior fica guardado numa ref de resgate" {
  local before
  before="$(git -C "$CLONE" rev-parse HEAD)"
  force_push_upstream

  run plugin_realign_to_upstream "$CLONE" "plugin-teste"
  [ "$status" -eq 0 ]

  run git -C "$CLONE" for-each-ref --format='%(objectname)' refs/full-upgrade/pre-realign
  [ "$output" = "$before" ]
}

@test "plugin_realign_to_upstream: modificação local não é descartada" {
  force_push_upstream
  echo "trabalho local" >> "${CLONE}/file"

  run plugin_realign_to_upstream "$CLONE" "plugin-teste"
  [ "$status" -ne 0 ]

  run grep -q "trabalho local" "${CLONE}/file"
  [ "$status" -eq 0 ]
}

@test "plugin_realign_to_upstream: arquivo novo não commitado não é descartado" {
  force_push_upstream
  echo "rascunho" > "${CLONE}/novo.zsh"

  run plugin_realign_to_upstream "$CLONE" "plugin-teste"
  [ "$status" -ne 0 ]
  [ -f "${CLONE}/novo.zsh" ]
}
