#!/usr/bin/env bats
# tests/orca_cov.bats — Orca IDE: binário por variável, checksum do release,
# instalação via AUR e via AppImage (download, sha256), ícone de fallback e o
# step completo. PATH isolado; HOME e raiz do sistema descartáveis.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/80-orca.sh"
  stub_path_init
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR" ORCA_SYSTEM_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$HOME" "$ORCA_SYSTEM_ROOT"
  unset ORCA_IDE_BIN
  run_network_cmd() { "$@"; }
}

@test "binário por variável e nome do AppImage de arquitetura desconhecida" {
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/orca"; chmod +x "$BATS_TEST_TMPDIR/orca"
  ORCA_IDE_BIN="$BATS_TEST_TMPDIR/orca" run orca_ide_bin
  [ "$output" = "$BATS_TEST_TMPDIR/orca" ]
  run orca_ide_release_appimage_name riscv64
  [ "$status" -eq 1 ]
}

@test "checksum: sem python, asset encontrado e ausente" {
  run orca_ide_release_appimage_sha256 x86_64
  [ "$status" -eq 1 ]
  stub_script python 'exec python3 "$@"'
  github_api_get() { echo '{"assets":[{"name":"orca-linux.AppImage","digest":"sha256:abc"}]}'; }
  [ "$(orca_ide_release_appimage_sha256 x86_64)" = abc ]
  run orca_ide_release_appimage_sha256 aarch64
  [ "$status" -eq 1 ]
}

@test "AUR: sem helper falha; com helper instala" {
  run install_orca_ide_aur
  [ "$status" -eq 1 ]
  stub paru 0 ""
  AUR_HELPER=paru run install_orca_ide_aur
  [ "$status" -eq 0 ]
  [ "$(stub_calls paru)" = "-S --needed --noconfirm stably-orca-bin" ]
}

@test "AppImage: sem curl, download falho, sem checksum, checksum divergente e sucesso" {
  run install_orca_ide_appimage
  [[ "$output" == *"curl ausente"* ]]
  stub curl 22 ""
  run install_orca_ide_appimage
  [ "$status" -eq "$RC_WARN" ]
  stub_script curl 'while (( $# )); do [[ "$1" == -o ]] && { echo appimage > "$2"; shift; }; shift; done'
  orca_ide_release_appimage_sha256() { return 1; }
  run install_orca_ide_appimage
  [ "$status" -eq 1 ]
  [[ "$output" == *"Não foi possível obter checksum"* ]]
  orca_ide_release_appimage_sha256() { printf '%064d\n' 0; }
  run install_orca_ide_appimage
  [[ "$output" == *"Checksum do AppImage do Orca IDE não confere"* ]]
  orca_ide_release_appimage_sha256() { sha256sum <<<"appimage" | awk '{print $1}'; }
  install_orca_ide_appimage >/dev/null
  [ -x "$HOME/.local/share/orca-ide/stably-orca" ]
  [ "$(readlink "$HOME/.local/bin/stably-orca")" = "$HOME/.local/share/orca-ide/stably-orca" ]
  [ "$ORCA_IDE_BIN" = "$HOME/.local/share/orca-ide/stably-orca" ]
}

@test "ícone: do sistema, sem curl, download falho e download ok" {
  mkdir -p "$ORCA_SYSTEM_ROOT/opt/stably-orca"; echo png > "$ORCA_SYSTEM_ROOT/opt/stably-orca/orca.png"
  run ensure_orca_ide_icon
  [ "$output" = "$HOME/.local/share/icons/hicolor/512x512/apps/stably-orca.png" ]
  rm -rf "$ORCA_SYSTEM_ROOT/opt" "$HOME/.local/share/icons"
  run ensure_orca_ide_icon
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"curl ausente"* ]]
  stub curl 6 ""
  run ensure_orca_ide_icon
  [[ "$output" == *"Falha ao baixar ícone fallback"* ]]
  stub_script curl 'while (( $# )); do [[ "$1" == -o ]] && { echo png > "$2"; shift; }; shift; done'
  run ensure_orca_ide_icon
  [ "$status" -eq 0 ]
}

@test "desktop: validação falha; reparo atualiza caches" {
  stub desktop-file-validate 1 ""
  run write_orca_ide_desktop /bin/orca stably-orca
  [ "$status" -eq 1 ]
  rm "$STUB_BIN/desktop-file-validate"; hash -r
  stub gtk-update-icon-cache 0 ""; stub update-desktop-database 0 ""
  ensure_orca_ide_icon() { echo /icone.png; }
  run repair_orca_ide_desktop
  [ "$status" -eq 0 ]
  [[ "$output" == *"Orca IDE desktop:"* ]]
  [[ "$output" == *"Exec"* || -f "$HOME/.local/share/applications/stably-orca.desktop" ]]
  grep -q '^Exec=/usr/bin/stably-orca %U' "$HOME/.local/share/applications/stably-orca.desktop"
  [ -n "$(stub_calls gtk-update-icon-cache)" ]
}

@test "ensure: ausente sem opt-in, instalação falha, instalado e reparo falho" {
  orca_ide_installed() { return 1; }
  run ensure_orca_ide
  [ "$status" -eq "$RC_TODO" ]
  install_orca_ide_aur() { return 1; }
  install_orca_ide_appimage() { return "$RC_WARN"; }
  ENABLE_CUSTOM_TOOLS=1 ensure_orca_ide >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "falha ao instalar Orca IDE" ]
  orca_ide_installed() { return 0; }
  repair_orca_ide_desktop() { return 1; }
  unset status
  ensure_orca_ide >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "falha ao reparar .desktop/ícone do Orca IDE" ]
  repair_orca_ide_desktop() { return 0; }
  run ensure_orca_ide
  [ "$status" -eq 0 ]
  [[ "$output" == *"Orca IDE já instalado"* ]]
}

@test "installed: pacote e AppImage em ~/.local/share contam" {
  stub pacman 0 ""
  run orca_ide_installed
  [ "$status" -eq 0 ]
  stub pacman 1 ""
  mkdir -p "$HOME/.local/share/orca-ide"; printf '#!/bin/sh\n' > "$HOME/.local/share/orca-ide/stably-orca"; chmod +x "$HOME/.local/share/orca-ide/stably-orca"
  run orca_ide_installed
  [ "$status" -eq 0 ]
}
