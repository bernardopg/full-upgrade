#!/usr/bin/env bats
# tests/final_checks_cov.bats — IgnorePkg lido do pacman.conf, motivo sem
# pendência, AUR via yay (remediação e retry), aviso de out-of-date do
# mantenedor, gems do usuário pendentes e a remediação oficial que falha.
# PATH isolado; sudo só executa o stub.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/cleanup.sh"
  source "${FU_LIB}/steps/final_checks.sh"
  source "${FU_LIB}/steps/lang_other.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export LOG_DIR="$BATS_TEST_TMPDIR/logs" RUN_ID=t; mkdir -p "$LOG_DIR"
  AUTO_FIX_FINAL_PENDING=1
}

@test "IgnorePkg do pacman.conf quando não há pacman-conf; motivo sem pendência" {
  export PACMAN_CONF_FILE="$BATS_TEST_TMPDIR/pacman.conf"
  printf '[options]\nIgnorePkg = python-aiostream, vdirsyncer\n' > "$PACMAN_CONF_FILE"
  [ "$(pacman_ignored_packages)" = $'python-aiostream\nvdirsyncer' ]
  [ "$(final_pending_reason 0 0)" = "nenhuma atualização pendente" ]
}

@test "pendência AUR via yay, out-of-date informativo e nada pendente" {
  stub yay 0 "foo-git 1-1 -> 2-1"
  run final_check_pending
  [[ "$output" == *"Pendencias no AUR"* ]]
  [[ "$output" == *"Remediação: yay -Syu"* ]]
  stub yay 0 ""
  printf 'bar\nbar\n' > "$LOG_DIR/full-upgrade-t.aur-out-of-date"
  run final_check_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 pacote(s) AUR marcados como out-of-date"* ]]
  [[ "$output" == *"Nenhuma atualização pendente em pacman/AUR"* ]]
}

@test "gems do usuário desatualizadas entram nas pendências finais" {
  stub_script gem 'case "$1" in outdated) echo "rake (13.0.0 < 13.2.1)" ;; list) : ;; esac'
  run final_check_managers
  [[ "$output" == *"Gems de usuário ainda desatualizadas: rake"* ]]
  [[ "$output" == *"gem update --user-install"* ]]
}

@test "autofix: oficial acionável com pacman -Syu falho" {
  stub checkupdates 0 "linux 7.3.4-1 -> 7.3.5-1"
  stub pacman 1 ""
  _autofix_npm_global_names() { :; }
  autofix_final_pending >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "pacman -Syu de remediação falhou" ]
}

@test "autofix: pendência AUR via yay com retry que falha" {
  stub yay 1 "foo-git 1-1 -> 2-1"
  stub_script yay 'case "$1" in -Qua) echo "foo-git 1-1 -> 2-1" ;; -Sua) exit 1 ;; esac'
  _autofix_npm_global_names() { :; }
  AUR_HELPER=yay autofix_final_pending >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "pendências AUR persistem após retry" ]
  stub_calls yay | grep -q -- "-Sua --noconfirm --answerclean None"
}
