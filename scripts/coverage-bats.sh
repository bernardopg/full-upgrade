#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-coverage/bats}"
case "$OUT" in
  /*) ;;
  *) OUT="${ROOT}/${OUT}" ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"

include_pattern="${ROOT}/full-upgrade.sh"
include_pattern+=",${ROOT}/build.sh"
include_pattern+=",${ROOT}/install.sh"
include_pattern+=",${ROOT}/lib/"
include_pattern+=",${ROOT}/steps.d/"

KCOV_ROOT="$ROOT" kcov \
  --include-pattern="$include_pattern" \
  --bash-parse-files-in-dir="$ROOT" \
  "$OUT" \
  "${ROOT}/scripts/run-bats.sh" tests/

coverage_xml="$(find "$OUT" -mindepth 2 -name cobertura.xml -print -quit)"
test -n "$coverage_xml"
test -s "$coverage_xml"
cp "$coverage_xml" "$OUT/cobertura.xml"
printf 'Cobertura report: %s\n' "$OUT/cobertura.xml"
