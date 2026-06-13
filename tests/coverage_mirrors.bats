#!/usr/bin/env bats
# tests/coverage_mirrors.bats — regressões de mirrorlist/backup

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/coverage.sh"
}

@test "mirrorlist_has_server: aceita backup com Server ativo" {
  f="$BATS_TEST_TMPDIR/mirrorlist"
  printf '# comentário\nServer = https://mirror.example/$repo/os/$arch\n' >"$f"

  run mirrorlist_has_server "$f"
  [ "$status" -eq 0 ]
}

@test "mirrorlist_has_server: rejeita arquivo vazio/comentários" {
  f="$BATS_TEST_TMPDIR/mirrorlist"
  printf '# sem mirrors ativos\n# Server = https://old.example/$repo/os/$arch\n' >"$f"

  run mirrorlist_has_server "$f"
  [ "$status" -ne 0 ]
}
