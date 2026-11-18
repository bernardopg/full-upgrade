#!/usr/bin/env bats
# tests/antigravity_more_cov.bats — versões (pacote e upstream), validação dos
# .desktop, cache de desktop e os reparos de shadowing em /usr/local/bin e do
# diretório legado em /opt, com os caminhos do sistema trocados por diretórios
# descartáveis. PATH isolado; nada fora de $BATS_TEST_TMPDIR é tocado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/81-antigravity.sh"
  stub_path_init
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.local/share/applications"
  export ANTIGRAVITY_LOCAL_BIN_DIR="$BATS_TEST_TMPDIR/usr-local-bin"
  export ANTIGRAVITY_SYSTEM_BIN_DIR="$BATS_TEST_TMPDIR/usr-bin"
  export ANTIGRAVITY_OPT_DIR="$BATS_TEST_TMPDIR/opt"
  export ANTIGRAVITY_SYSTEM_APPS_DIR="$BATS_TEST_TMPDIR/apps"
  mkdir -p "$ANTIGRAVITY_LOCAL_BIN_DIR" "$ANTIGRAVITY_SYSTEM_BIN_DIR" "$ANTIGRAVITY_OPT_DIR" "$ANTIGRAVITY_SYSTEM_APPS_DIR"
}

_exe() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod +x "$1"; }

@test "versões: pacote instalado, ausente e manifest do upstream" {
  stub pacman 0 "antigravity 1.2.3-1"
  [ "$(antigravity_package_version antigravity)" = "1.2.3-1" ]
  stub pacman 1 ""
  run antigravity_package_version antigravity
  [ "$status" -eq 1 ]
  run antigravity_latest_version https://x
  [ "$status" -eq "$RC_WARN" ]
  stub curl 0 ""
  fetch_network_text() { return 7; }
  run antigravity_latest_version https://x
  [ "$status" -eq 7 ]
  fetch_network_text() { echo '[{"version":"1.3.0"},{"version":"1.2.0"}]'; }
  [ "$(antigravity_latest_version https://x)" = "1.3.0" ]
}

@test "desktops: validação falha nos três e entrada do sistema conta como presente" {
  stub desktop-file-validate 1 ""
  run write_antigravity_desktop /bin/a
  [ "$status" -eq 1 ]
  run write_antigravity_ide_desktop /bin/a
  [ "$status" -eq 1 ]
  run write_antigravity_ide_url_desktop /bin/a
  [ "$status" -eq 1 ]
  touch "$ANTIGRAVITY_SYSTEM_APPS_DIR/x.desktop"
  run antigravity_desktop_present x.desktop
  [ "$status" -eq 0 ]
  run antigravity_desktop_present y.desktop
  [ "$status" -eq 1 ]
}

@test "desktops: reparo atualiza o cache de desktop" {
  _exe "$BATS_TEST_TMPDIR/bin/antigravity"
  antigravity_bin() { echo "$BATS_TEST_TMPDIR/bin/antigravity"; }
  antigravity_ide_bin() { :; }
  stub update-desktop-database 0 ""
  run repair_antigravity_desktops
  [ "$status" -eq 0 ]
  [ "$(stub_calls update-desktop-database)" = "$HOME/.local/share/applications" ]
}

@test "shadowing: move a cópia manual; sem escrita e sem sudo vira TODO" {
  _exe "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity"; _exe "$ANTIGRAVITY_SYSTEM_BIN_DIR/antigravity"
  stub pacman 1 ""
  run repair_antigravity_command_shadowing
  [ "$status" -eq 0 ]
  [[ "$output" == *"Shadowing removido"* ]]
  [ ! -e "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity" ]
  _exe "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity-ide"; _exe "$ANTIGRAVITY_SYSTEM_BIN_DIR/antigravity-ide"
  chmod 555 "$ANTIGRAVITY_LOCAL_BIN_DIR"
  repair_antigravity_command_shadowing >/dev/null || status=$?
  chmod 755 "$ANTIGRAVITY_LOCAL_BIN_DIR"
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "remova "*"antigravity-ide ou rode com sudo pronto" ]]
}

@test "shadowing: sudo pronto mas mv falha vira TODO; arquivo do pacote fica" {
  _exe "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity"; _exe "$ANTIGRAVITY_SYSTEM_BIN_DIR/antigravity"
  stub pacman 0 ""
  run repair_antigravity_command_shadowing
  [ -e "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity" ]
  stub pacman 1 ""
  stub_script sudo '[[ "$1" == -n ]] && exit 0; exit 1'
  chmod 555 "$ANTIGRAVITY_LOCAL_BIN_DIR"
  repair_antigravity_command_shadowing >/dev/null || status=$?
  chmod 755 "$ANTIGRAVITY_LOCAL_BIN_DIR"
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "falha ao remover shadowing de "* ]]
}

@test "legado em /opt: do pacote fica; sem sudo vira TODO; move e religa os backups" {
  mkdir -p "$ANTIGRAVITY_OPT_DIR/antigravity"; _exe "$ANTIGRAVITY_OPT_DIR/Antigravity/antigravity"
  stub pacman 0 ""
  run repair_antigravity_legacy_opt_dir
  [ -d "$ANTIGRAVITY_OPT_DIR/antigravity" ]
  stub pacman 1 ""
  chmod 555 "$ANTIGRAVITY_OPT_DIR"
  repair_antigravity_legacy_opt_dir >/dev/null || status=$?
  chmod 755 "$ANTIGRAVITY_OPT_DIR"
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "mova "*" com sudo ou rode com sudo pronto" ]]
  ln -s "$ANTIGRAVITY_OPT_DIR/antigravity/antigravity" "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity.manual-backup-1"
  ln -s /outro "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity.manual-backup-2"
  touch "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity.manual-backup-3"
  run repair_antigravity_legacy_opt_dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"Diretório legado movido"* ]]
  [ ! -e "$ANTIGRAVITY_OPT_DIR/antigravity" ]
  [[ "$(readlink "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity.manual-backup-1")" == "$ANTIGRAVITY_OPT_DIR/antigravity.manual-backup-"*/antigravity ]]
  [ "$(readlink "$ANTIGRAVITY_LOCAL_BIN_DIR/antigravity.manual-backup-2")" = /outro ]
}

@test "legado em /opt: sudo pronto mas mv falha vira TODO" {
  mkdir -p "$ANTIGRAVITY_OPT_DIR/antigravity"; _exe "$ANTIGRAVITY_OPT_DIR/Antigravity/antigravity"
  stub pacman 1 ""
  stub_script sudo '[[ "$1" == -n ]] && exit 0; exit 1'
  chmod 555 "$ANTIGRAVITY_OPT_DIR"
  repair_antigravity_legacy_opt_dir >/dev/null || status=$?
  chmod 755 "$ANTIGRAVITY_OPT_DIR"
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "falha ao mover "* ]]
}

@test "binários: nenhum candidato e instalação detectada só pelo binário" {
  unset ANTIGRAVITY_BIN ANTIGRAVITY_IDE_BIN
  stub pacman 1 ""
  run antigravity_bin
  [ "$status" -eq 1 ]
  run antigravity_ide_bin
  [ "$status" -eq 1 ]
  _exe "$ANTIGRAVITY_SYSTEM_BIN_DIR/antigravity"; _exe "$ANTIGRAVITY_SYSTEM_BIN_DIR/antigravity-ide"
  antigravity_hub_installed
  antigravity_ide_installed
}
