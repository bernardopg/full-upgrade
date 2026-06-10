#!/usr/bin/env bats
# tests/backup.bats — helpers puros de backup (F1). Sem mutação real.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/backup.sh"
  TMPDIR_BK="$(mktemp -d)"
}

teardown() {
  [[ -n "${TMPDIR_BK:-}" && -d "$TMPDIR_BK" ]] && rm -rf "$TMPDIR_BK"
}

# ── backup_existing_paths ───────────────────────────────────────────────────────

@test "backup_existing_paths: filtra só os paths que existem" {
  touch "${TMPDIR_BK}/a" "${TMPDIR_BK}/b"
  run backup_existing_paths "${TMPDIR_BK}/a ${TMPDIR_BK}/inexistente ${TMPDIR_BK}/b"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "${TMPDIR_BK}/a" ]
  [ "${lines[1]}" = "${TMPDIR_BK}/b" ]
}

@test "backup_existing_paths: nenhum existe não produz saída" {
  run backup_existing_paths "/nao/existe/x /nao/existe/y"
  [ -z "$output" ]
}

# ── backup_rotation_victims ─────────────────────────────────────────────────────

@test "backup_rotation_victims: mantém os N mais recentes, lista o resto" {
  # Nomes com timestamp crescente; sort lexical == cronológico.
  for ts in 20260101-000000 20260102-000000 20260103-000000 20260104-000000; do
    touch "${TMPDIR_BK}/configs-${ts}.tar.zst"
  done
  mapfile -t victims < <(backup_rotation_victims "$TMPDIR_BK" 2)
  [ "${#victims[@]}" -eq 2 ]
  [[ "${victims[0]}" == *"configs-20260101-000000.tar.zst" ]]
  [[ "${victims[1]}" == *"configs-20260102-000000.tar.zst" ]]
}

@test "backup_rotation_victims: dentro do limite não remove nada" {
  touch "${TMPDIR_BK}/configs-20260101-000000.tar.zst"
  touch "${TMPDIR_BK}/configs-20260102-000000.tar.zst"
  run backup_rotation_victims "$TMPDIR_BK" 5
  [ -z "$output" ]
}

@test "backup_rotation_victims: ignora arquivos que não são backup" {
  touch "${TMPDIR_BK}/configs-20260101-000000.tar.zst"
  touch "${TMPDIR_BK}/outro-arquivo.txt"
  touch "${TMPDIR_BK}/configs-20260102-000000.tar.zst"
  run backup_rotation_victims "$TMPDIR_BK" 1
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"configs-20260101-000000.tar.zst" ]]
}

@test "backup_rotation_victims: diretório inexistente não falha" {
  run backup_rotation_victims "/nao/existe" 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
