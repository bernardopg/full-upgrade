#!/usr/bin/env bats
# tests/self_update_more_cov.bats — canal main na consulta de versão, reparo da
# unit do tray com escrita falha, aviso de versão nova em instalação do pacman,
# --update sem tar, confirmação no terminal, canal main (download, pacote sem
# install.sh, instalador falho) e o standalone sem verificador nem destino
# gravável. curl serve fixtures; HOME descartável.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/self_update.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 ASSUME_YES=1 SCRIPT_VERSION=4.0.0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/home/.config"; mkdir -p "$HOME"
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"; export FIX
  printf '#!/usr/bin/env bash\necho novo\n' > "$FIX/full-upgrade-standalone.sh"
  (cd "$FIX" && sha256sum full-upgrade-standalone.sh > full-upgrade-standalone.sh.sha256)
  stub_script curl 'dest=""; url=""
while (( $# )); do case "$1" in -o) dest="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
f="$FIX/${url##*/}"; [[ -f "$f" ]] || exit 22; cp "$f" "$dest"'
  self_pacman_managed_bin() { return 1; }
  self_latest_version() { echo 4.1.0; }
}

@test "canal main na consulta da última versão" {
  unset -f self_latest_version; source "${FU_LIB}/steps/self_update.sh"
  FULL_UPGRADE_UPDATE_CHANNEL=main run self_latest_version
  [ "$output" = main ]
}

@test "unit do tray: falha ao gravar a unit reparada não troca o arquivo" {
  self_pacman_managed_bin() { echo /usr/bin/full-upgrade; }
  unit="$XDG_CONFIG_HOME/systemd/user/full-upgrade-tray.service"; mkdir -p "${unit%/*}"
  printf '[Service]\nExecStart=%s/.local/bin/full-upgrade --tray\n' "$HOME" > "$unit"
  chmod 555 "${unit%/*}"
  run repair_full_upgrade_tray_unit
  chmod 755 "${unit%/*}"
  [ "$status" -eq 1 ]
  grep -q '.local/bin/full-upgrade --tray' "$unit"
}

@test "aviso de versão nova: instalação do pacman aponta o AUR" {
  self_pacman_managed_bin() { echo /usr/bin/full-upgrade; }
  run self_update_notice
  [[ "$output" == *"Nova versão disponível: v4.0.0 → v4.1.0"* ]]
  [[ "$output" == *"atualize via pacote AUR"* ]]
}

@test "--update: sem tar vira warn" {
  stub curl 0 ""
  mv "$STUB_SAFE/tar" "$STUB_SAFE/tar.x"; hash -r
  run self_perform_update
  mv "$STUB_SAFE/tar.x" "$STUB_SAFE/tar"; hash -r
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"tar é necessário para atualizar"* ]]
}

@test "--update: confirmação recusada e aceita no terminal" {
  local defs="ASSUME_YES=0 SCRIPT_VERSION=4.0.0 HOME='$HOME' FIX='$FIX'
self_pacman_managed_bin() { return 1; }
self_latest_version() { echo 4.1.0; }
self_perform_update; echo \"rc=\$?\""
  pty_call "steps/self_update.sh" "$defs" 'n\r'
  [[ "$output" == *"Baixar e instalar v4.1.0 agora?"* ]]
  [[ "$output" == *"Atualização cancelada"* ]]
  pty_call "steps/self_update.sh" "$defs" 's\r'
  [[ "$output" == *"standalone verificado"* ]]
  [[ "$output" == *"rc=0"* ]]
}

@test "canal main: download falho, pacote sem install.sh e instalador falho" {
  FULL_UPGRADE_UPDATE_CHANNEL=main
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  mkdir -p "$BATS_TEST_TMPDIR/src/full-upgrade-main"; echo x > "$BATS_TEST_TMPDIR/src/full-upgrade-main/README"
  tar -czf "$FIX/main.tar.gz" -C "$BATS_TEST_TMPDIR/src" full-upgrade-main
  run self_perform_update
  [[ "$output" == *"Pacote inválido: install.sh não encontrado"* ]]
  printf '#!/usr/bin/env bash\nexit 3\n' > "$BATS_TEST_TMPDIR/src/full-upgrade-main/install.sh"
  chmod +x "$BATS_TEST_TMPDIR/src/full-upgrade-main/install.sh"
  tar -czf "$FIX/main.tar.gz" -C "$BATS_TEST_TMPDIR/src" full-upgrade-main
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao executar o instalador"* ]]
}

@test "standalone: sem verificador de sha256 e destino sem escrita" {
  has() { [[ "$1" != sha256sum && "$1" != shasum ]] && command -v "$1" >/dev/null 2>&1; }
  run self_install_verified_standalone bernardopg/full-upgrade 4.1.0 v4.1.0 "$BATS_TEST_TMPDIR"
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Sem sha256sum/shasum"* ]]
  unset -f has; source "${FU_LIB}/core.sh"
  mkdir -p "$HOME/.local/bin"; chmod 555 "$HOME/.local/bin"
  run self_install_verified_standalone bernardopg/full-upgrade 4.1.0 v4.1.0 "$BATS_TEST_TMPDIR"
  chmod 755 "$HOME/.local/bin"
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao instalar o standalone"* ]]
}

@test "binário do pacote: dono pacman e sem dono" {
  unset -f self_pacman_managed_bin; source "${FU_LIB}/steps/self_update.sh"
  export FULL_UPGRADE_SYSTEM_BIN="$BATS_TEST_TMPDIR/full-upgrade"; touch "$FULL_UPGRADE_SYSTEM_BIN"
  load stub_helper
  stub pacman 0 ""
  [ "$(self_pacman_managed_bin)" = "$FULL_UPGRADE_SYSTEM_BIN" ]
  stub pacman 1 ""
  run self_pacman_managed_bin
  [ "$status" -eq 1 ]
}
