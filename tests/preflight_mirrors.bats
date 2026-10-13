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

@test "mirrors: ciclo backup, reflector falhado e rollback mantém idade original" {
  MIRROR_TOOL=reflector MIRROR_MAX_AGE_DAYS=0
  local original="$BATS_TEST_TMPDIR/mirrorlist" old
  printf 'Server = https://mirror.example/$repo/os/$arch\n' > "$original"
  touch -d '10 days ago' "$original"
  old="$(stat -c %Y "$original")"
  has() { [[ "$1" == pacman || "$1" == reflector ]]; }
  timeout() { [ "$1" -eq 90 ] || return 99; shift; "$@"; }
  mirrorlist_has_server() { grep -Eq '^Server =' "$BATS_TEST_TMPDIR/backup"; }
  sudo() {
    if [[ "$1" == cp ]]; then
      local src dst
      case "$3:$4" in
        /etc/pacman.d/mirrorlist:/etc/pacman.d/mirrorlist.full-upgrade.bak)
          src="$BATS_TEST_TMPDIR/mirrorlist"; dst="$BATS_TEST_TMPDIR/backup" ;;
        /etc/pacman.d/mirrorlist.full-upgrade.bak:/etc/pacman.d/mirrorlist)
          src="$BATS_TEST_TMPDIR/backup"; dst="$BATS_TEST_TMPDIR/mirrorlist" ;;
        *) return 99 ;;
      esac
      command cp "$2" "$src" "$dst"
    elif [[ "$1" == reflector ]]; then
      printf 'partial write\n' > "$BATS_TEST_TMPDIR/mirrorlist"
      return 1
    else
      return 99
    fi
  }
  run refresh_mirrors
  [ "$status" -eq "$RC_WARN" ]
  [ "$(stat -c %Y "$original")" -eq "$old" ]
  [ "$(stat -c %Y "$BATS_TEST_TMPDIR/backup")" -eq "$old" ]
  grep -q '^Server =' "$original"
  run mirror_is_fresh "$(stat -c %Y "$original")" "$(date +%s)" 7
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
