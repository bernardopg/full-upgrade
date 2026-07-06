#!/usr/bin/env bats
# tests/pacfiles.bats — detecção de .pacnew/.pacsave (I2).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  QUIET=0
  STEP_REASON=""
  FULL_UPGRADE_PACFILES_TODO_REPORTED=0
  RUN_ID="pacfiles-test-${BATS_TEST_NUMBER}"
  LOG_DIR="$BATS_TEST_TMPDIR"
}

@test "pacfiles_find: localiza .pacnew e .pacsave reais" {
  local d; d="$(mktemp -d)"
  : > "${d}/foo.conf.pacnew"
  : > "${d}/bar.conf.pacsave"
  : > "${d}/normal.conf"
  run pacfiles_find "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo.conf.pacnew"* ]]
  [[ "$output" == *"bar.conf.pacsave"* ]]
  [[ "$output" != *"normal.conf"$'\n'* ]]
  rm -rf "$d"
}

@test "doctor: sem pendências retorna 0" {
  pacfiles_find() { printf ''; }
  run doctor_pacfiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem arquivos .pacnew/.pacsave"* ]]
}

@test "doctor: pendências viram RC_TODO e listam arquivos" {
  pacfiles_find() { printf '%s\n' "/etc/a.conf.pacnew" "/etc/b.conf.pacsave"; }
  has() { return 0; }   # pacdiff presente
  run doctor_pacfiles
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"2 arquivo(s) .pacnew/.pacsave"* ]]
  [[ "$output" == *"/etc/a.conf.pacnew"* ]]
  [[ "$output" == *"pacdiff"* ]]
}

@test "doctor: não duplica TODO quando a verificação final já reportou pacfiles" {
  pacfiles_find() { printf '%s\n' "/etc/a.conf.pacnew"; }
  has() { return 0; }
  FULL_UPGRADE_PACFILES_TODO_REPORTED=1
  run doctor_pacfiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"já reportado"* ]]
}

@test "doctor: não duplica TODO após check_pacnew_files via run_step com timeout" {
  has() { [[ "$1" == pacdiff ]]; }
  sudo() {
    [[ "$1" == pacdiff && "$2" == --output ]] || return 1
    printf '%s\n' "/etc/a.conf.pacnew"
  }
  pacfiles_find() { printf '%s\n' "/etc/a.conf.pacnew"; }

  run run_step "Verificar arquivos .pacnew/.pacsave" check_pacnew_files
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/full-upgrade-${RUN_ID}.pacfiles-todo" ]

  run doctor_pacfiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"já reportado"* ]]
}

@test "doctor: sem pacdiff sugere instalar pacman-contrib" {
  pacfiles_find() { printf '%s\n' "/etc/a.conf.pacnew"; }
  has() { return 1; }   # pacdiff ausente
  run doctor_pacfiles
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"pacman-contrib"* ]]
}
