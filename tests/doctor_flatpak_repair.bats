#!/usr/bin/env bats
# tests/doctor_flatpak_repair.bats — o repair do Flatpak confere todo o repo
# (40–70s com runtimes do Flathub); só repete quando os refs mudaram ou a
# verificação limpa expirou. `flatpak` é sempre stub.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  QUIET=0 LOG_FILE=/dev/null
  FLATPAK_USER_REPO="$BATS_TEST_TMPDIR/repo"
  FLATPAK_REPAIR_STAMP="$BATS_TEST_TMPDIR/flatpak-repair-ok"
  FLATPAK_REPAIR_MAX_AGE_DAYS=7
  mkdir -p "$FLATPAK_USER_REPO/refs/remotes/flathub/app"
  echo abc > "$FLATPAK_USER_REPO/refs/remotes/flathub/app/x"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  has() { [[ "$1" == flatpak ]]; }
  flatpak() { printf '%s\n' "$*" >> "$CALLS"; printf '%s\n' "${FLATPAK_OUT:-}"; return "${FLATPAK_RC:-0}"; }
}

@test "flatpak_user_repo_fingerprint: muda quando um ref muda; sem repo => rc 1" {
  a="$(flatpak_user_repo_fingerprint)"
  [ -n "$a" ]
  touch -d '2020-01-01' "$FLATPAK_USER_REPO/refs/remotes/flathub/app/x"
  b="$(flatpak_user_repo_fingerprint)"
  [ "$a" != "$b" ]
  FLATPAK_USER_REPO="$BATS_TEST_TMPDIR/nao-existe"
  run flatpak_user_repo_fingerprint
  [ "$status" -eq 1 ]
}

@test "flatpak_repair_recent: vale só com o mesmo fingerprint e dentro do prazo" {
  echo fp1 > "$FLATPAK_REPAIR_STAMP"
  flatpak_repair_recent fp1
  ! flatpak_repair_recent fp2
  ! flatpak_repair_recent ""
  touch -d '10 days ago' "$FLATPAK_REPAIR_STAMP"
  ! flatpak_repair_recent fp1
}

@test "doctor_flatpak_repair_dry_run: verificação limpa grava o stamp; a seguinte não chama o flatpak" {
  doctor_flatpak_repair_dry_run
  [ "$(grep -c 'repair --user --dry-run' "$CALLS")" -eq 1 ]
  [ "$(<"$FLATPAK_REPAIR_STAMP")" = "$(flatpak_user_repo_fingerprint)" ]
  run doctor_flatpak_repair_dry_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"sem mudança desde a última verificação limpa"* ]]
  [ "$(grep -c 'repair --user --dry-run' "$CALLS")" -eq 1 ]
}

@test "doctor_flatpak_repair_dry_run: ref novo força a verificação completa" {
  doctor_flatpak_repair_dry_run
  echo def > "$FLATPAK_USER_REPO/refs/remotes/flathub/app/y"
  doctor_flatpak_repair_dry_run
  [ "$(grep -c 'repair --user --dry-run' "$CALLS")" -eq 2 ]
}

@test "doctor_flatpak_repair_dry_run: saída com problema não vale como verificação limpa" {
  FLATPAK_OUT="Object missing: abc.file"
  doctor_flatpak_repair_dry_run
  [ ! -e "$FLATPAK_REPAIR_STAMP" ]
}

@test "doctor_flatpak_repair_dry_run: rc != 0 vira RC_WARN e não grava stamp" {
  FLATPAK_RC=1 FLATPAK_OUT="error: boom"
  run doctor_flatpak_repair_dry_run
  [ "$status" -eq "$RC_WARN" ]
  [ ! -e "$FLATPAK_REPAIR_STAMP" ]
}
