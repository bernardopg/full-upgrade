#!/usr/bin/env bats
# tests/burp_more_cov.bats — busca do Java e da release, falhas de download e de
# instalação do pacote do fallback, e a escolha do helper (paru/yay/pacman) no
# install/upgrade do Burp. PATH isolado; nada é baixado nem instalado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/51-burp-suite.sh"
  stub_path_init
  stub_privilege
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR" BURPSUITE_JVM_ROOT="$BATS_TEST_TMPDIR/jvm"
  mkdir -p "$HOME/Downloads"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"
}

@test "release info passa o script ao python; Java ausente e Java por variável" {
  stub_script python 'cat >/dev/null; printf "2026.11.1\tabc\thttps://x\n"'
  [ "$(burpsuite_desktop_release_info)" = $'2026.11.1\tabc\thttps://x' ]
  unset JAVA_BIN BURPSUITE_JAVA_BIN
  run burpsuite_java_bin
  [ "$status" -eq 1 ]
  mkdir -p "$BURPSUITE_JVM_ROOT/java-21-openjdk/bin"
  printf '#!/bin/sh\n' > "$BURPSUITE_JVM_ROOT/java-21-openjdk/bin/java"; chmod +x "$BURPSUITE_JVM_ROOT/java-21-openjdk/bin/java"
  [ "$(burpsuite_java_bin)" = "$BURPSUITE_JVM_ROOT/java-21-openjdk/bin/java" ]
}

_fallback_env() {
  printf 'jar' > "$BATS_TEST_TMPDIR/burp.jar"
  SHA="$(sha256sum "$BATS_TEST_TMPDIR/burp.jar" | awk '{print $1}')"
  burpsuite_java_bin() { echo /usr/bin/java; }
  burpsuite_desktop_release_info() { printf '2026.11.1\t%s\thttps://x/burp.jar\n' "$SHA"; }
  stub python 0
  stub_script makepkg 'touch "burpsuite-2026.11.1-1-any.pkg.tar.zst"'
}

@test "fallback: download falho e pacman -U falho limpam o diretório temporário" {
  _fallback_env
  stub curl 22 ""
  stub_script pacman 'case "$1" in -Q) echo "burpsuite 2026.10.1-1" ;; -U) exit 1 ;; esac'
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 1 ]
  stub_script curl 'while (( $# )); do case "$1" in -o) d="$2"; shift 2 ;; *) shift ;; esac; done; cp "$BATS_TEST_TMPDIR/burp.jar" "$d"'
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 1 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'burpsuite-pkg.*')" ]
}

@test "install: já instalado e instalação via pacman sem helper AUR" {
  stub pacman 0 "burpsuite 1-1"
  run install_arch_package burpsuite
  [[ "$output" == *"burpsuite ja instalado"* ]]
  stub_script pacman 'case "$1" in -Q) exit 1 ;; -S) exit 0 ;; esac'
  run install_arch_package wireshark-qt
  [ "$status" -eq 0 ]
  stub_calls pacman | grep -q -- "-S --needed --noconfirm wireshark-qt"
}

@test "upgrade: já na mais recente e versão nova via paru" {
  stub_script pacman 'case "$1" in -Q) echo "burpsuite 2026.11.1-1" ;; esac'
  stub_script paru 'case "$1" in -Si) echo "Version         : ${AVAIL:-2026.11.1-1}" ;; -S) exit 0 ;; esac'
  run upgrade_arch_package burpsuite
  [[ "$output" == *"já na versão mais recente"* ]]
  AVAIL=2026.12.1-1 run upgrade_arch_package burpsuite
  [ "$status" -eq 0 ]
  [[ "$output" == *"burpsuite: 2026.11.1-1 → 2026.12.1-1"* ]]
}

@test "helper: paru e yay falhando caem no fallback do burp; outro pacote falha" {
  install_burpsuite_desktop_fallback() { echo fallback; return 0; }
  stub paru 1 ""
  run _install_arch_package_via_helper burpsuite
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback"* ]]
  run _install_arch_package_via_helper outro
  [ "$status" -eq 1 ]
  rm "$STUB_BIN/paru"; hash -r
  stub yay 1 ""
  run _install_arch_package_via_helper burpsuite
  [[ "$output" == *"AUR burpsuite falhou"* ]]
  run _install_arch_package_via_helper outro
  [ "$status" -eq 1 ]
  stub yay 0 ""
  run _install_arch_package_via_helper outro
  [ "$status" -eq 0 ]
}

@test "ensure: falha ao garantir e instalação nova com fallback falho" {
  stub_script pacman 'exit 1'
  install_arch_package() { return 1; }
  run ensure_burpsuite
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao garantir burpsuite"* ]]
  install_arch_package() { return 0; }
  install_burpsuite_desktop_fallback() { return 1; }
  run ensure_burpsuite
  [ "$status" -eq 0 ]
  [[ "$output" == *"Não foi possivel verificar/atualizar Burp"* ]]
}
