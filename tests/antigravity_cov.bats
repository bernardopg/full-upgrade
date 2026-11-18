#!/usr/bin/env bats
# tests/antigravity_cov.bats — ensure_antigravity e o reparo dos .desktop do
# Antigravity (hub e IDE). Os binários e o AUR são stubs; os .desktop vão para
# um HOME descartável. Nada é instalado.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/81-antigravity.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON="" ENABLE_CUSTOM_TOOLS=0
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.local/share/applications"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\n' > "$BIN/antigravity"; printf '#!/bin/sh\n' > "$BIN/antigravity-ide"
  chmod +x "$BIN/antigravity" "$BIN/antigravity-ide"
  antigravity_bin() { echo "$BIN/antigravity"; }
  antigravity_ide_bin() { echo "$BIN/antigravity-ide"; }
  # O original também olha /usr/share/applications: na máquina com o pacote
  # instalado o teste mudaria de resultado. Só o HOME descartável conta.
  antigravity_desktop_present() { [[ -f "${HOME}/.local/share/applications/$1" ]]; }
}

@test "repair_antigravity_desktops: cria os três .desktop e não reescreve os corretos" {
  run repair_antigravity_desktops
  [ "$status" -eq 0 ]
  [[ "$output" == *"Antigravity desktop:"* ]]
  [[ "$output" == *"Antigravity IDE desktop:"* ]]
  [[ "$output" == *"Antigravity IDE URL handler:"* ]]
  run repair_antigravity_desktops
  [ "$status" -eq 0 ]
  [[ "$output" != *"desktop:"* ]]
}

@test "repair_antigravity_desktops: Exec apontando para binário antigo é reescrito" {
  repair_antigravity_desktops >/dev/null
  f="$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID"
  sed -i 's|^Exec=.*|Exec=/opt/antigravity/antigravity %U|' "$f"
  run repair_antigravity_desktops
  [[ "$output" == *"Antigravity desktop:"* ]]
  grep -q "^Exec=$BIN/antigravity" "$f"
}

@test "ensure_antigravity: sem pacman e sem nada instalado viram TODO" {
  ensure_antigravity >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"requer pacman"* ]]
  stub pacman 1
  antigravity_hub_installed() { return 1; }
  antigravity_ide_installed() { return 1; }
  unset status
  ensure_antigravity >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"não instalado"* ]]
}

@test "ensure_antigravity: instala via AUR, repara e compara com o upstream" {
  stub pacman 1
  antigravity_hub_installed() { return 0; }
  antigravity_ide_installed() { return 0; }
  install_antigravity_aur() { echo "aur: $*" >> "$STUB_LOG"; return 0; }
  antigravity_package_version() { echo 1.0.0; }
  antigravity_latest_version() { echo 1.1.0; }
  run ensure_antigravity
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUR ainda não empacotou 1.1.0"* ]]
  grep -q "^aur: $ANTIGRAVITY_PACKAGE $ANTIGRAVITY_IDE_PACKAGE" "$STUB_LOG"
}

@test "ensure_antigravity: falha do AUR e manifest indisponível" {
  stub pacman 1
  antigravity_hub_installed() { return 0; }
  antigravity_ide_installed() { return 1; }
  install_antigravity_aur() { return 1; }
  run ensure_antigravity
  [ "$status" -eq 1 ]
  install_antigravity_aur() { return 0; }
  antigravity_package_version() { echo 1.0.0; }
  antigravity_latest_version() { return 1; }
  run ensure_antigravity
  [ "$status" -eq "$RC_WARN" ]
}
