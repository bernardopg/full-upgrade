#!/usr/bin/env bash
# preflight.sh — portão local rápido, equivalente ao que o CI reprova.
#
# Existe porque a main deixou de exigir PR: sem um portão antes do `git push`,
# um erro de sintaxe ou de lint só apareceria depois, com a main já quebrada.
# Roda em ~13s (o `bats tests/` completo leva ~1m50 e fica para o CI, que segue
# rodando a cada push na main).
#
# Uso:
#   scripts/preflight.sh          # sintaxe + shellcheck + build (~13s)
#   scripts/preflight.sh --full   # o acima + a suíte bats completa (~2min)
#
# Instale como hook de pre-push com: scripts/install-hooks.sh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
shopt -s nullglob

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

FILES=(full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh scripts/*.sh)

echo "▶ sintaxe (bash -n)"
for f in "${FILES[@]}"; do bash -n "$f"; done

echo "▶ shellcheck ($(shellcheck --version | awk '/^version:/{print $2}'))"
if ! shellcheck -S warning -x "${FILES[@]}"; then
  echo "✘ shellcheck reprovou." >&2
  echo "  Dica: o CI usa a versão pinada em scripts/install-shellcheck.sh." >&2
  exit 1
fi

echo "▶ build standalone"
./build.sh >/dev/null
bash -n dist/full-upgrade-standalone.sh
./dist/full-upgrade-standalone.sh --list-steps >/dev/null

if (( FULL )); then
  echo "▶ bats tests/"
  bats tests/
fi

echo "✔ preflight ok"
