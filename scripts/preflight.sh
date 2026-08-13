#!/usr/bin/env bash
# preflight.sh — portão local completo, equivalente ao que o CI reprova.
#
# Existe porque a main deixou de exigir PR: sem um portão antes do `git push`,
# uma regressão só apareceria depois, com a main já quebrada. Roda a suíte
# INTEIRA — o que importa é que ela não passe despercebida, e em paralelo ela
# custa ~35s (contra ~1m50 sequencial), bem abaixo do ciclo de PR + espera de CI
# que este projeto abandonou.
#
# Uso:
#   scripts/preflight.sh          # sintaxe + shellcheck + build + bats (~45s)
#   scripts/preflight.sh --fast   # sem a suíte bats (~13s), p/ iteração rápida
#   BATS_JOBS=4 scripts/preflight.sh   # força o paralelismo
#
# Instale como hook de pre-push com: scripts/install-hooks.sh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
shopt -s nullglob

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

FILES=(full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh scripts/*.sh)

# Defesa em profundidade: o commit-msg dá feedback ao criar o commit, mas pode
# ter sido pulado com --no-verify ou o commit pode ter vindo de cherry-pick. No
# pre-push, valida todos os commits ainda ausentes no upstream antes do portão
# mais caro. Sem upstream (primeiro push), valida pelo menos o HEAD.
echo "▶ conventional commits"
if upstream="$(git rev-parse --verify '@{upstream}' 2>/dev/null)"; then
  range="${upstream}..HEAD"
else
  range="HEAD^..HEAD"
fi
mapfile -t pending_commits < <(git rev-list --reverse "$range" 2>/dev/null || git rev-list -1 HEAD)
if (( ${#pending_commits[@]} == 0 )); then
  echo "  nenhum commit pendente"
else
  msg_tmp="$(mktemp)"
  trap 'rm -f -- "$msg_tmp"' EXIT
  for sha in "${pending_commits[@]}"; do
    git show -s --format=%B "$sha" > "$msg_tmp"
    if ! scripts/validate-commit-msg.sh "$msg_tmp"; then
      echo "  commit: $sha" >&2
      exit 1
    fi
  done
  rm -f -- "$msg_tmp"
  trap - EXIT
  echo "  ${#pending_commits[@]} commit(s) válido(s)"
fi

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
./dist/full-upgrade-standalone.sh --list-steps >/dev/null

if (( FAST )); then
  echo "✔ preflight ok (--fast: suíte bats NÃO executada)"
  exit 0
fi

# `bats --jobs` precisa de GNU parallel (ou flock) para serializar a saída TAP;
# sem eles, cai para execução sequencial em vez de falhar.
jobs="${BATS_JOBS:-}"
if [[ -z "$jobs" ]]; then
  if command -v parallel >/dev/null 2>&1 || command -v flock >/dev/null 2>&1; then
    jobs="$(nproc 2>/dev/null || echo 1)"
  else
    jobs=1
  fi
fi

if (( jobs > 1 )); then
  echo "▶ bats tests/ (--jobs ${jobs})"
  bats --jobs "$jobs" tests/
else
  echo "▶ bats tests/ (sequencial: GNU parallel/flock ausente)"
  bats tests/
fi

echo "✔ preflight ok"
