#!/usr/bin/env bats
# tests/notify.bats — notificação desktop ao fim do run (I4).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/notify.sh"
  STEP_RESULTS=()
  NOTIFY_ON_FINISH=1
}

@test "counts: conta status do STEP_RESULTS" {
  STEP_RESULTS=(ok ok warn todo fail skip skip)
  run _notify_counts
  [ "$output" = "2 1 1 1 2" ]
}

@test "body: formata a linha de resumo" {
  run notify_body 5 1 2 0 3
  [ "$output" = "5 ok · 1 warn · 2 todo · 0 fail · 3 skip" ]
}

@test "notify: off-switch não chama notify-send" {
  NOTIFY_ON_FINISH=0
  local marker="${BATS_TEST_TMPDIR}/called"
  has() { return 0; }
  notify-send() { : > "$marker"; }
  run notify_on_finish
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "notify: sem notify-send é no-op" {
  has() { return 1; }
  run notify_on_finish
  [ "$status" -eq 0 ]
}

@test "notify: fail => urgência critical" {
  STEP_RESULTS=(ok fail)
  has() { return 0; }
  local argf="${BATS_TEST_TMPDIR}/args"
  notify-send() { printf '%s\n' "$*" > "$argf"; }
  run notify_on_finish
  [ "$status" -eq 0 ]
  grep -q -- "-u critical" "$argf"
  grep -q "1 ok · 0 warn · 0 todo · 1 fail" "$argf"
}

@test "notify: só todo => urgência normal" {
  STEP_RESULTS=(ok todo)
  has() { return 0; }
  local argf="${BATS_TEST_TMPDIR}/args"
  notify-send() { printf '%s\n' "$*" > "$argf"; }
  run notify_on_finish
  grep -q -- "-u normal" "$argf"
}

@test "notify: tudo ok => urgência low" {
  STEP_RESULTS=(ok ok)
  has() { return 0; }
  local argf="${BATS_TEST_TMPDIR}/args"
  notify-send() { printf '%s\n' "$*" > "$argf"; }
  run notify_on_finish
  grep -q -- "-u low" "$argf"
}
