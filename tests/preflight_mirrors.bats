#!/usr/bin/env bats
# tests/coverage_mirrors.bats — regressões de mirrorlist/backup

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  # mirrors migraram para pacman.sh na Série T4
  source "${FU_LIB}/steps/pacman.sh"
}

@test "mirrors: restauração preserva mtime e não marca backup velho como fresco" {
  local backup="$BATS_TEST_TMPDIR/backup" target="$BATS_TEST_TMPDIR/target" old
  printf 'Server = https://mirror.example/$repo/os/$arch\n' > "$backup"
  touch -d '10 days ago' "$backup"
  old="$(stat -c %Y "$backup")"
  sudo() { "$@"; }
  _restore_mirror_backup "$backup" "$target"
  [ "$(stat -c %Y "$target")" -eq "$old" ]
  cmp "$backup" "$target"
  run mirror_is_fresh "$(stat -c %Y "$target")" "$(date +%s)" 7
  [ "$status" -ne 0 ]
}

@test "mirrors: falha na restauração não é ocultada" {
  local backup="$BATS_TEST_TMPDIR/backup"
  printf 'Server = https://mirror.example/\n' > "$backup"
  sudo() { return 1; }
  run _restore_mirror_backup "$backup" "$BATS_TEST_TMPDIR/target"
  [ "$status" -ne 0 ]
}

@test "pacman: lock respeita DBPath configurado e nunca é removido" {
  pacman-conf() { printf '%s/\n' "$BATS_TEST_TMPDIR"; }
  run pacman_db_is_locked
  [ "$status" -ne 0 ]
  touch "$BATS_TEST_TMPDIR/db.lck"
  run pacman_db_is_locked
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/db.lck" ]
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
