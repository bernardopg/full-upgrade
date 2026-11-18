#!/usr/bin/env bats
# tests/manual_bins_more_cov.bats — RTK e o updater genérico de releases do
# GitHub (gitleaks/trufflehog) nos ramos de ferramenta ausente, arquitetura,
# versão indisponível, sem sudo, mktemp, tar sem binário e troca falha.
# PATH isolado; curl é stub.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/manual_apps.sh"
  source "${FU_ROOT}/steps.d/70-rtk.sh"
  stub_path_init
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"; export FIX LATEST_TAG=""
  stub uname 0 x86_64
  run_network_cmd() { "$@"; }
  stub_script curl 'dest=""; url=""; eff=0
while (( $# )); do case "$1" in -o) dest="$2"; shift 2 ;; -w) eff=1; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
if (( eff )); then [[ -n "$LATEST_TAG" ]] && echo "https://github.com/x/y/releases/tag/$LATEST_TAG"; exit 0; fi
f="$FIX/${url##*/}"; [[ -f "$f" ]] || exit 22
if [[ -n "$dest" ]]; then cp "$f" "$dest"; else cat "$f"; fi'
  RTKBIN="$BATS_TEST_TMPDIR/bin/rtk"; mkdir -p "${RTKBIN%/*}"
  printf '#!/bin/sh\necho "rtk 0.40.0"\n' > "$RTKBIN"; chmod +x "$RTKBIN"
  export RTK_BIN="$RTKBIN"
}

_rtk_release() {
  LATEST_TAG=v0.43.0
  local d="$BATS_TEST_TMPDIR/pkg"; mkdir -p "$d"
  if [[ "${1:-}" == vazio ]]; then echo x > "$d/LEIA"; tar -czf "$FIX/rtk-$2.tar.gz" -C "$d" LEIA
  else printf '#!/bin/sh\necho "rtk 0.43.0"\n' > "$d/rtk"; chmod +x "$d/rtk"; tar -czf "$FIX/rtk-$2.tar.gz" -C "$d" rtk; fi
  (cd "$FIX" && sha256sum "rtk-$2.tar.gz" > checksums.txt)
}

@test "rtk: sem curl, aarch64 e mktemp falho" {
  mv "$STUB_BIN/curl" "$STUB_BIN/curl.x"; hash -r
  run update_rtk
  [[ "$output" == *"curl ausente"* ]]
  mv "$STUB_BIN/curl.x" "$STUB_BIN/curl"; hash -r
  stub uname 0 aarch64
  _rtk_release ok aarch64-unknown-linux-gnu
  mktemp() { return 1; }
  run update_rtk
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"mktemp falhou"* ]]
}

@test "rtk: tarball sem binário e troca que falha" {
  _rtk_release vazio x86_64-unknown-linux-musl
  run update_rtk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao extrair o binário rtk"* ]]
  _rtk_release ok x86_64-unknown-linux-musl
  chmod 555 "$RTKBIN" "${RTKBIN%/*}"
  run update_rtk
  chmod 755 "$RTKBIN" "${RTKBIN%/*}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao instalar o binário rtk"* ]]
}

@test "release genérico: sem tar, arquitetura, versão indisponível e sem sudo" {
  stub gitleaks 0 "gitleaks version 1.0.0"
  mv "$STUB_SAFE/tar" "$STUB_SAFE/tar.x"; hash -r
  run _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64
  mv "$STUB_SAFE/tar.x" "$STUB_SAFE/tar"; hash -r
  [[ "$output" == *"curl, tar e sha256sum são necessários"* ]]
  stub uname 0 riscv64
  run _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64
  [[ "$output" == *"não suportada pelo atualizador do gitleaks"* ]]
  stub uname 0 aarch64
  _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64 >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "última versão do gitleaks indisponível" ]
  LATEST_TAG=v2.0.0
  _manual_write_prefix() { return 1; }
  unset status
  _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64 >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "atualize o gitleaks com sudo disponível"* ]]
}
