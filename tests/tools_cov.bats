#!/usr/bin/env bats
# tests/tools_cov.bats — falhas do updater do gk (arquiteturas, sem sudo,
# mktemp, unzip, zip sem binário, install), cua-driver (check falho, já atual,
# skills sem rede) e Herdr (alvos, manifests incompletos, download, pacote sem
# binário e troca do diretório que falha). PATH isolado; HOME descartável;
# curl/fetch servem fixtures locais.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/manual_apps.sh"
  source "${FU_LIB}/steps/tools.sh"
  stub_path_init
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR"; mkdir -p "$HOME"
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"
  export FIX LATEST_TAG="v3.2.0"
  stub uname 0 "x86_64"
  run_network_cmd() { "$@"; }
  stub_script curl 'dest=""; url=""; eff=0
while (( $# )); do case "$1" in -o) dest="$2"; shift 2 ;; -w) eff=1; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
[[ -n "${CURL_FAIL:-}" ]] && exit 6
if (( eff )); then echo "https://github.com/x/y/releases/tag/$LATEST_TAG"; exit 0; fi
f="$FIX/${url##*/}"; [[ -f "$f" ]] || exit 22
if [[ -n "$dest" ]]; then cp "$f" "$dest"; else cat "$f"; fi'
}

# ── gk ────────────────────────────────────────────────────────────────────────

_gk_fixture() {
  printf 'zip' > "$FIX/gk_3.2.0_linux_amd64.zip"
  (cd "$FIX" && sha256sum gk_3.2.0_linux_amd64.zip > gk_checksums.txt)
  stub gk 0 "Core 3.1.0"
}

@test "gk: arm64 e 386 resolvem o asset (versão já atual)" {
  stub gk 0 "Core 3.2.0"; stub unzip 0 ""
  stub uname 0 aarch64
  run update_gk
  [[ "$output" == *"gk já está na versão mais recente"* ]]
  stub uname 0 i686
  run update_gk
  [[ "$output" == *"gk já está na versão mais recente"* ]]
}

@test "gk: sem sudo para escrever e mktemp falho" {
  _gk_fixture; stub unzip 0 ""
  _manual_write_prefix() { return 1; }
  update_gk >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "atualize o gk com sudo disponível"* ]]
  _manual_write_prefix() { :; }
  mktemp() { return 1; }
  run update_gk
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"mktemp falhou"* ]]
}

@test "gk: unzip falho, zip sem binário e install falho" {
  _gk_fixture
  stub unzip 1 ""
  run update_gk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao descompactar"* ]]
  stub_script unzip 'while (( $# )); do case "$1" in -d) mkdir -p "$2"; shift 2 ;; *) shift ;; esac; done'
  run update_gk
  [[ "$output" == *"Binário gk não encontrado dentro do zip"* ]]
  stub_script unzip 'while (( $# )); do case "$1" in -d) d="$2"; shift 2 ;; *) shift ;; esac; done; mkdir -p "$d"; printf "x" > "$d/gk"'
  stub install 1 ""
  run update_gk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao instalar o binário gk"* ]]
}

# ── cua-driver ────────────────────────────────────────────────────────────────

@test "cua-driver: check falho; já atual com skills sem rede" {
  stub_script cua-driver 'case "$1" in --version) echo "cua-driver 0.28.2" ;; check-update) exit "${CHECK_RC:-0}" ;; skills) exit 1 ;; esac
echo "{\"update_available\": false}"'
  CHECK_RC=1 run update_cua_driver
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Não foi possível verificar atualização do cua-driver"* ]]
  run update_cua_driver
  [ "$status" -eq 0 ]
  [[ "$output" == *"cua-driver já está na versão mais recente (0.28.2)"* ]]
  [[ "$output" == *"não foi possível atualizar as skills"* ]]
}

# ── Herdr ─────────────────────────────────────────────────────────────────────

_herdr_app() {
  APPHOME="$HOME/.local/share/herdr-app"; mkdir -p "$APPHOME"
  printf '#!/bin/sh\necho "herdr-app 0.1.0"\n' > "$APPHOME/herdr-app"; chmod +x "$APPHOME/herdr-app"
}

@test "herdr_target: aarch64 e arquitetura sem build" {
  stub uname 0 aarch64
  [ "$(herdr_target)" = linux-aarch64 ]
  stub uname 0 riscv64
  run herdr_target
  [ "$status" -eq 1 ]
}

@test "herdr: manifests sem versão viram warn" {
  fetch_network_text() { echo '{"notes":"x"}'; }
  run _herdr_update_core /bin/true
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"herdr-core: manifest sem versão"* ]]
  _herdr_app
  run _herdr_update_app "$APPHOME"
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"herdr-app: manifest sem versão"* ]]
}

@test "herdr-app: sem build do alvo, sem ferramentas, download falho e pacote vazio" {
  _herdr_app
  fetch_network_text() { echo '{"version":"0.2.0","targets":{"linux-aarch64":{"url":"https://x/app.tar.gz","sha256":"abc"}}}'; }
  run _herdr_update_app "$APPHOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"manifest sem build linux-x86_64 ainda"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/pkg"; echo vazio > "$BATS_TEST_TMPDIR/pkg/leia"
  tar -czf "$FIX/app.tar.gz" -C "$BATS_TEST_TMPDIR/pkg" leia
  SHA="$(sha256sum "$FIX/app.tar.gz" | cut -d' ' -f1)"
  fetch_network_text() { echo "{\"version\":\"0.2.0\",\"targets\":{\"linux-x86_64\":{\"url\":\"https://x/app.tar.gz\",\"sha256\":\"$SHA\"}}}"; }
  mv "$STUB_SAFE/tar" "$STUB_SAFE/tar.x"; hash -r
  run _herdr_update_app "$APPHOME"
  mv "$STUB_SAFE/tar.x" "$STUB_SAFE/tar"; hash -r
  [[ "$output" == *"curl, tar e sha256sum são necessários"* ]]
  CURL_FAIL=1 run _herdr_update_app "$APPHOME"
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao baixar o herdr-app 0.2.0"* ]]
  run _herdr_update_app "$APPHOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pacote sem herdr-app/herdr-app"* ]]
}

@test "herdr-app: troca do diretório falha e mantém o atual" {
  _herdr_app
  mkdir -p "$BATS_TEST_TMPDIR/pkg/herdr-app"
  printf '#!/bin/sh\necho "herdr-app 0.2.0"\n' > "$BATS_TEST_TMPDIR/pkg/herdr-app/herdr-app"; chmod +x "$BATS_TEST_TMPDIR/pkg/herdr-app/herdr-app"
  tar -czf "$FIX/app.tar.gz" -C "$BATS_TEST_TMPDIR/pkg" herdr-app
  SHA="$(sha256sum "$FIX/app.tar.gz" | cut -d' ' -f1)"
  fetch_network_text() { echo "{\"version\":\"0.2.0\",\"targets\":{\"linux-x86_64\":{\"url\":\"https://x/app.tar.gz\",\"sha256\":\"$SHA\"}}}"; }
  chmod 555 "$HOME/.local/share"
  run _herdr_update_app "$APPHOME"
  chmod 755 "$HOME/.local/share"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao trocar"* ]]
  [ "$("$APPHOME/herdr-app")" = "herdr-app 0.1.0" ]
}

@test "update_herdr: sem nada instalado termina ok" {
  herdr_core_bin() { :; }
  run update_herdr
  [ "$status" -eq 0 ]
}
