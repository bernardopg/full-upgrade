#!/usr/bin/env bats
# tests/self_update_cov.bats — --update: instalação via pacman, ferramentas
# ausentes, versão atual, confirmação, canal release (standalone verificado por
# SHA-256) e canal main (tarball + install.sh). `curl` é stub que copia
# fixtures; a instalação vai para um HOME descartável.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/self_update.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 ASSUME_YES=1 SCRIPT_VERSION=4.0.0
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"
  printf '#!/usr/bin/env bash\necho novo\n' > "$FIX/full-upgrade-standalone.sh"
  (cd "$FIX" && sha256sum full-upgrade-standalone.sh > full-upgrade-standalone.sh.sha256)
  export FIX
  # curl -fsSL --max-time N -o DEST URL => copia o fixture homônimo.
  stub_script curl 'dest=""; url=""
while (( $# )); do case "$1" in -o) dest="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
f="$FIX/${url##*/}"; [[ -f "$f" ]] || exit 22; cp "$f" "$dest"'
  self_pacman_managed_bin() { return 1; }
  self_latest_version() { echo 4.1.0; }
}

@test "self_perform_update: instalação do pacman redireciona para o AUR" {
  self_pacman_managed_bin() { echo /usr/bin/full-upgrade; }
  repair_full_upgrade_shadow() { :; }
  run self_perform_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualize via pacote AUR"* ]]
}

@test "self_perform_update: sem curl ou tar vira warn" {
  rm "$STUB_BIN/curl"; hash -r
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"curl é necessário"* ]]
}

@test "self_perform_update: API indisponível e versão já atual" {
  self_latest_version() { return 1; }
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  self_latest_version() { echo 4.0.0; }
  run self_perform_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Já está na versão mais recente"* ]]
}

@test "self_perform_update: sem --yes e sem TTY não instala" {
  ASSUME_YES=0
  run self_perform_update </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulando atualização"* ]]
}

@test "self_perform_update: release instala o standalone verificado com backup" {
  mkdir -p "$HOME/.local/bin"; echo velho > "$HOME/.local/bin/full-upgrade"
  run self_perform_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checksum verificado"* ]]
  [ "$(cat "$HOME/.local/bin/full-upgrade.bak")" = velho ]
  [ -x "$HOME/.local/bin/full-upgrade" ]
}

@test "self_install_verified_standalone: checksum divergente aborta sem instalar" {
  echo "0000000000000000000000000000000000000000000000000000000000000000  full-upgrade-standalone.sh" \
    > "$FIX/full-upgrade-standalone.sh.sha256"
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"NÃO confere"* ]]
  [ ! -e "$HOME/.local/bin/full-upgrade" ]
}

@test "self_install_verified_standalone: sem .sha256, checksum vazio ou bash inválido aborta" {
  rm "$FIX/full-upgrade-standalone.sh.sha256"
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"abortando por segurança"* ]]
  : > "$FIX/full-upgrade-standalone.sh.sha256"
  run self_perform_update
  [[ "$output" == *"checksum inválido"* ]]
  printf 'if then\n' > "$FIX/full-upgrade-standalone.sh"
  (cd "$FIX" && sha256sum full-upgrade-standalone.sh > full-upgrade-standalone.sh.sha256)
  run self_perform_update
  [[ "$output" == *"falhou no bash -n"* ]]
  rm "$FIX/full-upgrade-standalone.sh"
  run self_perform_update
  [[ "$output" == *"Falha ao baixar o standalone"* ]]
}

@test "self_perform_update: canal main extrai o tarball e roda o install.sh" {
  FULL_UPGRADE_UPDATE_CHANNEL=main
  src="$BATS_TEST_TMPDIR/src/full-upgrade-main"; mkdir -p "$src"
  printf '#!/usr/bin/env bash\ntouch "$HOME/instalado"\n' > "$src/install.sh"; chmod +x "$src/install.sh"
  tar -czf "$FIX/main.tar.gz" -C "$BATS_TEST_TMPDIR/src" full-upgrade-main
  run self_perform_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"integridade não verificada"* ]]
  [ -e "$HOME/instalado" ]
}

@test "self_perform_update: canal main com pacote inválido vira warn" {
  FULL_UPGRADE_UPDATE_CHANNEL=main
  printf 'lixo' > "$FIX/main.tar.gz"
  run self_perform_update
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao extrair"* ]]
}
