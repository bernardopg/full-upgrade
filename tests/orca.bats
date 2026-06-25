#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2034

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/80-orca.sh"
  TMP_HOME="$(mktemp -d)"
  export HOME="$TMP_HOME"
  LOG_FILE="/dev/null"
}

teardown() {
  rm -rf "$TMP_HOME"
}

@test "orca: escolhe AppImage certo por arquitetura" {
  [ "$(orca_ide_release_appimage_name x86_64)" = "orca-linux.AppImage" ]
  [ "$(orca_ide_release_appimage_name aarch64)" = "orca-linux-arm64.AppImage" ]
  [ "$(orca_ide_release_appimage_url x86_64)" = "https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage" ]
  [ "$(orca_ide_release_appimage_url aarch64)" = "https://github.com/stablyai/orca/releases/latest/download/orca-linux-arm64.AppImage" ]

  run orca_ide_release_appimage_url riscv64
  [ "$status" -eq 1 ]
}

@test "orca: escreve desktop entry com Icon=stably-orca" {
  mkdir -p "$HOME/.local/bin"
  touch "$HOME/.local/bin/stably-orca"
  chmod +x "$HOME/.local/bin/stably-orca"

  desktop_file="$(write_orca_ide_desktop "$HOME/.local/bin/stably-orca" stably-orca)"

  [ -f "$desktop_file" ]
  grep -qxF "Name=Orca" "$desktop_file"
  grep -qxF "Exec=${HOME}/.local/bin/stably-orca %U" "$desktop_file"
  grep -qxF "Icon=stably-orca" "$desktop_file"
}

@test "orca: copia icone local para hicolor de usuario" {
  src="$HOME/source-icon.png"
  printf 'png' >"$src"

  orca_ide_icon_source() { printf '%s\n' "$src"; }
  icon_target="$(ensure_orca_ide_icon)"

  [ "$icon_target" = "$HOME/.local/share/icons/hicolor/512x512/apps/stably-orca.png" ]
  [ "$(cat "$icon_target")" = "png" ]
}
