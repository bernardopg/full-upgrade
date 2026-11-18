#!/usr/bin/env bats
# tests/obs_cov.bats — diretório de config nativo/padrão, OBS via Flatpak ou
# ausente, pull que deixa conflito ou falha, fetch sem rede e o Doctor sem log
# de sessão. PATH isolado; os helpers git são funções falsas.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/85-obs.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  unset OBS_CONFIG_DIR
}

@test "config: nativo pelo pacote e padrão sem nada instalado" {
  stub pacman 0 "obs-studio 32.1.2-7"
  [ "$(_obs_config_dir)" = "$HOME/.config/obs-studio" ]
  stub pacman 1 ""
  [ "$(_obs_config_dir)" = "$HOME/.config/obs-studio" ]
}

@test "instalação: Flatpak e ausente" {
  stub pacman 1 ""
  stub flatpak 0 "        Version: 32.0.4"
  [ "$(_obs_install_kind)" = "flatpak 32.0.4" ]
  rm "$STUB_BIN/flatpak"; hash -r
  run _obs_install_kind
  [ "$status" -eq 1 ]
  run update_obs_plugins
  [[ "$output" == *"OBS Studio não instalado"* ]]
  run doctor_obs_modules
  [[ "$output" == *"OBS Studio não instalado"* ]]
}

@test "plugins: pull com conflito, pull falho e fetch sem rede" {
  stub_script pacman 'case "$1" in -Q) echo "obs-studio 32.1.2-7" ;; esac'
  export OBS_CONFIG_DIR="$BATS_TEST_TMPDIR/obs"
  for p in conflito falho semrede; do mkdir -p "$OBS_CONFIG_DIR/plugins/$p/.git"; done
  stub_script git 'case "$*" in *rev-list*) echo 2 ;; esac'
  git_fetch_full() { [[ "$1" == *semrede* ]] && { echo "Could not resolve host: github.com"; return 1; }; return 0; }
  git_pull_ff_only() { [[ "$1" == *conflito* ]] && touch "$1/.pulled"; [[ "$1" == *conflito* ]]; }
  git_has_unmerged() { [[ -e "$1/.pulled" ]]; }
  update_obs_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "rede indisponível ao buscar plugins OBS (3 afetados)" ]]
  rm -f "$OBS_CONFIG_DIR/plugins/conflito/.pulled"
  run update_obs_plugins
  [[ "$output" == *"conflito: pull deixou conflito — restaurando árvore"* ]]
  [[ "$output" == *"pull falhou para plugin OBS falho"* ]]
}

@test "doctor: diretório de logs sem sessão" {
  stub pacman 0 "obs-studio 32.1.2-7"
  export OBS_CONFIG_DIR="$BATS_TEST_TMPDIR/obs"; mkdir -p "$OBS_CONFIG_DIR/logs"
  run doctor_obs_modules
  [[ "$output" == *"Nenhum log de sessão do OBS encontrado"* ]]
}
