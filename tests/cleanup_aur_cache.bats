#!/usr/bin/env bats
# tests/cleanup_aur_cache.bats — regressão de cleanup_aur_cache (cache de build AUR)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"
  # `log` escreveria em terminal/log; silencioso nos testes.
  log() { :; }
  # Isola os diretórios de cache para não tocar em ~/.cache real.
  XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  PARU_CLONE_DIR="$BATS_TEST_TMPDIR/paru/clone"
  export XDG_CACHE_HOME PARU_CLONE_DIR
}

@test "cleanup_aur_cache: remove artefatos de build preservando PKGBUILD/.SRCINFO/.git" {
  local pkg="$PARU_CLONE_DIR/foo"
  mkdir -p "$pkg/src/sub" "$pkg/pkg" "$pkg/.git/objects"
  touch "$pkg/PKGBUILD" "$pkg/.SRCINFO" "$pkg/install.sh"
  # artefatos que devem sumir
  touch "$pkg/foo-1.0-1-x86_64.pkg.tar.zst" "$pkg/foo-1.0.tar.gz" "$pkg/foo.zip"
  touch "$pkg/src/build.o" "$pkg/pkg/install-layout.txt"
  # yay: estrutura similar
  local bar="$XDG_CACHE_HOME/yay/bar"
  mkdir -p "$bar/src"
  touch "$bar/PKGBUILD" "$bar/bar-2.0.pkg.tar.zst" "$bar/bar-2.0.tar.xz"

  run cleanup_aur_cache
  [ "$status" -eq 0 ]

  # preservados (git clone reutilizável)
  [ -f "$pkg/PKGBUILD" ]
  [ -f "$pkg/.SRCINFO" ]
  [ -f "$pkg/install.sh" ]
  [ -d "$pkg/.git" ]
  [ -f "$bar/PKGBUILD" ]

  # removidos (build + fontes baixadas)
  [ ! -e "$pkg/foo-1.0-1-x86_64.pkg.tar.zst" ]
  [ ! -e "$pkg/foo-1.0.tar.gz" ]
  [ ! -e "$pkg/foo.zip" ]
  [ ! -d "$pkg/src" ]
  [ ! -d "$pkg/pkg" ]
  [ ! -e "$bar/bar-2.0.pkg.tar.zst" ]
  [ ! -e "$bar/bar-2.0.tar.xz" ]
  [ ! -d "$bar/src" ]
}

@test "cleanup_aur_cache: não remove fontes baixadas com extensão incomum (.part/.sig)" {
  local pkg="$PARU_CLONE_DIR/qux"
  mkdir -p "$pkg"
  touch "$pkg/PKGBUILD" "$pkg/source.part" "$pkg/source.sig"
  run cleanup_aur_cache
  [ "$status" -eq 0 ]
  [ -f "$pkg/PKGBUILD" ]
  [ -f "$pkg/source.part" ]
  [ -f "$pkg/source.sig" ]
}

@test "cleanup_aur_cache: sem diretório de cache retorna ok sem erro" {
  run cleanup_aur_cache
  [ "$status" -eq 0 ]
}
