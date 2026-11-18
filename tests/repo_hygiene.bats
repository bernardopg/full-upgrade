#!/usr/bin/env bats
# tests/repo_hygiene.bats — guarda contra teste que escreve no repositório real.
#
# Em set/2026 o GIT_DIR exportado pelo hook pre-push vazou para os testes: o
# `git -C <tmp> config user.email test@test.com` dos repositórios descartáveis
# gravou no .git/config do projeto, que passou a assinar commits como
# "Test <test@test.com>" e com commit.gpgsign=false por dois meses.

load test_helper

@test "o .git/config do projeto não carrega identidade nem assinatura de teste" {
  [[ -d "${FU_ROOT}/.git" ]] || skip "sem checkout git"
  run git -C "$FU_ROOT" config --local --get user.email
  [[ "$output" != *"@test.com"* && "$output" != *"@example."* ]]
  run git -C "$FU_ROOT" config --local --get user.name
  [ "$output" != "Test" ]
  run git -C "$FU_ROOT" config --local --get commit.gpgsign
  [ "$output" != "false" ]
}
