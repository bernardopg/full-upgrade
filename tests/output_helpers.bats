#!/usr/bin/env bats
# tests/output_helpers.bats — helpers de saída/resumo (lib/core.sh, lib/ui.sh)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
}

@test "fmt_mib: abaixo de 1 GiB fica em MiB (não vira '0GiB')" {
  run fmt_mib 756
  [ "$output" = "756MiB" ]
  run fmt_mib 200
  [ "$output" = "200MiB" ]
  run fmt_mib 1023
  [ "$output" = "1023MiB" ]
}

@test "fmt_mib: a partir de 1 GiB vira GiB com uma casa" {
  run fmt_mib 1024
  [ "$output" = "1.0GiB" ]
  run fmt_mib 1536
  [ "$output" = "1.5GiB" ]
  run fmt_mib 300264
  [ "$output" = "293.2GiB" ]
}

@test "fmt_mib: entrada não numérica passa adiante sem quebrar" {
  run fmt_mib "n/a"
  [ "$output" = "n/a" ]
}

@test "log_stream: indenta a saída do comando no terminal" {
  QUIET=0 NO_COLOR=1 LOG_FILE=/dev/null
  _emit() { printf "linha um\nlinha dois\n" | log_stream; }
  run _emit
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  linha um" ]
  [ "${lines[1]}" = "  linha dois" ]
}

@test "log_stream: em --quiet não escreve no terminal" {
  local lf="${BATS_TEST_TMPDIR}/log"
  QUIET=1 LOG_FILE="$lf"
  _emit() { printf "segredo\n" | log_stream; }
  run _emit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q segredo "$lf"
}

@test "log_out: indenta sem gravar no arquivo (log_raw já gravou)" {
  local lf="${BATS_TEST_TMPDIR}/log"
  QUIET=0 NO_COLOR=1 LOG_FILE="$lf"
  : > "$lf"
  _emit() { printf "so terminal\n" | log_out; }
  run _emit
  [ "$status" -eq 0 ]
  [ "$output" = "  so terminal" ]
  [ ! -s "$lf" ]
}

@test "log_out: em --quiet não escreve nada" {
  QUIET=1 LOG_FILE=/dev/null
  _emit() { printf "so terminal\n" | log_out; }
  run _emit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "summary_action_items: lista fail, todo e warn nessa ordem, com motivo" {
  STEP_NAMES=("A" "B" "C" "D")
  STEP_RESULTS=("ok" "todo" "fail" "warn")
  STEP_REASONS=("" "merge pendente" "" "rede instável")
  run summary_action_items
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = $'fail\tC\t' ]
  [ "${lines[1]}" = $'todo\tB\tmerge pendente' ]
  [ "${lines[2]}" = $'warn\tD\trede instável' ]
}

@test "summary_action_items: run limpo não emite nada" {
  STEP_NAMES=("A" "B")
  STEP_RESULTS=("ok" "skip")
  STEP_REASONS=("" "")
  run summary_action_items
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
