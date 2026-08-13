#!/usr/bin/env bash
# extract-release-notes.sh — extrai do CHANGELOG a seção de uma versão.
#
# O gerador automático do GitHub privilegia PRs e omite commits enviados direto
# à main. Como push direto é o fluxo principal deste projeto, a fonte completa e
# autoritativa das notas de release precisa ser a seção versionada do CHANGELOG.
#
# Uso: scripts/extract-release-notes.sh <versão|tag> [CHANGELOG]
# Ex.: scripts/extract-release-notes.sh v3.34.0 > dist/release-notes.md
set -euo pipefail

VERSION="${1:-}"
CHANGELOG="${2:-CHANGELOG.md}"
VERSION="${VERSION#v}"

if [[ -z "$VERSION" || ! -f "$CHANGELOG" ]]; then
  echo "Uso: $0 <versão|tag> [CHANGELOG]" >&2
  exit 2
fi

python3 - "$VERSION" "$CHANGELOG" <<'PY'
import re
import sys

version, path = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    text = f.read()

# Cabeçalho esperado: ## [X.Y.Z] - YYYY-MM-DD. Captura o corpo até a próxima
# seção de nível 2 (ou EOF), sem depender dos subtítulos Adicionado/Corrigido.
pattern = re.compile(
    rf"^## \[{re.escape(version)}\] - [^\n]+\n(?P<body>.*?)(?=^## \[|\Z)",
    re.MULTILINE | re.DOTALL,
)
match = pattern.search(text)
if not match:
    print(f"release notes: seção [{version}] não encontrada em {path}", file=sys.stderr)
    raise SystemExit(1)

body = match.group("body").strip()
if not body:
    print(f"release notes: seção [{version}] está vazia em {path}", file=sys.stderr)
    raise SystemExit(1)

print(body)
PY
