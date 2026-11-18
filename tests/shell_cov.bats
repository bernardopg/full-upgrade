#!/usr/bin/env bats
# tests/shell_cov.bats — plugins do Oh My Zsh com pull que deixa conflito, com
# realinhamento ao upstream e com realinhamento recusado; hyprpm sem store, sem
# plugins e com update. Helpers git são funções falsas; PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/shell.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" ZSH="$BATS_TEST_TMPDIR/omz"
  PLUG="$ZSH/custom/plugins"
  for p in conflito realinha preso; do mkdir -p "$PLUG/$p/.git"; done
  stub_script git 'case "$*" in *rev-list*) echo 1 ;; esac'
  git_fetch_full() { return 0; }
  git_tracking_ref() { echo origin/HEAD; }
  git_pull_ff_only() { [[ "$1" == *conflito* ]] && touch "$1/.pulled"; [[ "$1" == *conflito* ]]; }
  git_has_unmerged() { [[ -e "$1/.pulled" ]]; }
  plugin_realign_to_upstream() { [[ "$1" == *realinha* ]]; }
}

@test "omz: conflito restaurado, realinhamento e modificações locais" {
  run update_omz_custom_plugins
  [[ "$output" == *"conflito: pull deixou conflito — restaurando árvore"* ]]
  [[ "$output" == *"pull falhou para plugin preso (modificações locais)"* ]]
  [[ "$output" != *"pull falhou para plugin realinha"* ]]
}

@test "hyprpm: sem store, sem plugins e update" {
  run update_hyprpm
  [[ "$output" == *"hyprpm sem repositórios registrados"* ]]
  mkdir -p "$HOME/.local/share/hyprpm"
  run update_hyprpm
  [[ "$output" == *"hyprpm: sem plugins instalados"* ]]
  mkdir -p "$HOME/.local/share/hyprpm/hyprland-plugins"
  stub hyprpm 0 ""
  run update_hyprpm
  [ "$status" -eq 0 ]
  [ "$(stub_calls hyprpm)" = update ]
}
