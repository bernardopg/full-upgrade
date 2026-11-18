#!/usr/bin/env bats
# tests/burp_fallback_cov.bats — fallback PortSwigger do Burp Suite: requisitos,
# versão já instalada, JAR em cache, download com sha256 conferido, build do
# PKGBUILD e instalação. makepkg, pacman, sudo e curl são stubs.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/51-burp-suite.sh"
  stub_path_init
  stub_privilege
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME/Downloads"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"; export FIX
  printf 'jar' > "$FIX/burp.jar"
  SHA="$(sha256sum "$FIX/burp.jar" | awk '{print $1}')"
  burpsuite_java_bin() { echo /usr/bin/java; }
  burpsuite_desktop_release_info() { printf '2026.11.1\t%s\thttps://x/burp.jar\n' "$SHA"; }
  stub python 0
  stub_script curl 'while (( $# )); do case "$1" in -o) d="$2"; shift 2 ;; -*) shift ;; *) u="$1"; shift ;; esac; done
cp "$FIX/${u##*/}" "$d"'
  stub_script makepkg 'touch "burpsuite-2026.11.1-1-any.pkg.tar.zst"'
  stub_script pacman 'case "$1" in -Q) echo "burpsuite ${BURP_INSTALLED:-2026.10.1-1}" ;; -U) exit 0 ;; esac'
}

@test "burp fallback: sem requisitos, sem Java e release indisponível" {
  rm "$STUB_BIN/makepkg"; hash -r
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 1 ]
  [[ "$output" == *"requer curl, makepkg e python"* ]]
  stub makepkg 0
  burpsuite_java_bin() { return 1; }
  run install_burpsuite_desktop_fallback
  [[ "$output" == *"requer Java 21+"* ]]
  burpsuite_java_bin() { echo /usr/bin/java; }
  burpsuite_desktop_release_info() { echo "sem rede"; return 1; }
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 1 ]
}

@test "burp fallback: versão já instalada não baixa nada" {
  BURP_INSTALLED=2026.11.1-1 run install_burpsuite_desktop_fallback
  [ "$status" -eq 0 ]
  [[ "$output" == *"ja instalado"* ]]
}

@test "burp fallback: baixa, confere o sha256, constrói o pacote e instala" {
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 0 ]
  [[ "$output" == *"Baixando Burp Suite Desktop 2026.11.1"* ]]
  grep -q "^pacman -U --noconfirm .*burpsuite-2026.11.1-1-any.pkg.tar.zst" "$STUB_LOG"
  [ -f "$LOG_DIR/burpsuite/burpsuite_desktop_v2026.11.1.jar" ]
  run install_burpsuite_desktop_fallback
  [[ "$output" == *"Reutilizando JAR oficial em cache"* ]]
}

@test "burp fallback: JAR em Downloads, sha divergente e falha do makepkg" {
  cp "$FIX/burp.jar" "$HOME/Downloads/burpsuite_desktop_v2026.11.1.jar"
  run install_burpsuite_desktop_fallback
  [[ "$output" == *"Reutilizando JAR oficial ja baixado"* ]]
  rm -rf "$LOG_DIR/burpsuite" "$HOME/Downloads"/*
  burpsuite_desktop_release_info() { printf '2026.11.1\t%064d\thttps://x/burp.jar\n' 0; }
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 1 ]
  burpsuite_desktop_release_info() { printf '2026.11.1\t%s\thttps://x/burp.jar\n' "$SHA"; }
  stub makepkg 1
  run install_burpsuite_desktop_fallback
  [ "$status" -eq 1 ]
}
