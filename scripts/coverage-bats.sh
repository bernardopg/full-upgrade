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

# Programas awk/Python embutidos (o applet AppIndicator, os geradores do
# relatório) não são Bash: o kcov não os instrumenta e os contaria como linhas
# nunca executadas. Ficam entre "# kcov-excl-start" e "# kcov-excl-stop" (válido
# como comentário em awk e Python) e são testados por tests/report.bats e
# tests/tray_appindicator.py.
#
# "done < <(" fica fora pelo mesmo motivo: o fecho de um laço alimentado por
# process substitution nunca recebe hit no kcov, mesmo com o laço executando (o
# corpo é medido normalmente). Verificado num script mínimo: a linha fica em 0
# e a alternativa `done <<< "$(cmd)"` muda a semântica com saída vazia.
KCOV_ROOT="$ROOT" kcov \
  --include-pattern="$include_pattern" \
  --exclude-region="# kcov-excl-start:# kcov-excl-stop" \
  --exclude-line="done < <(" \
  --bash-parse-files-in-dir="$ROOT" \
  "$OUT" \
  "${ROOT}/scripts/run-bats.sh" tests/

coverage_xml="$(find "$OUT" -mindepth 2 -name cobertura.xml -print -quit)"
test -n "$coverage_xml"
test -s "$coverage_xml"
cp "$coverage_xml" "$OUT/cobertura.xml"
printf 'Cobertura report: %s\n' "$OUT/cobertura.xml"
