#!/usr/bin/env bash
# validate-commit-msg.sh — valida uma mensagem conforme .commitlintrc.json.
#
# Implementação local leve do subconjunto de regras usado pelo projeto. Não
# instala Node/npx no caminho de cada commit: lê os tipos e o limite diretamente
# do JSON, evitando duplicar esses valores. O workflow continua usando o
# commitlint oficial como verificação independente no GitHub.
#
# Uso: scripts/validate-commit-msg.sh <arquivo-da-mensagem>
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${COMMITLINT_CONFIG:-${ROOT}/.commitlintrc.json}"
MSG_FILE="${1:-}"

if [[ -z "$MSG_FILE" || ! -f "$MSG_FILE" ]]; then
  echo "Uso: $0 <arquivo-da-mensagem>" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "commitlint local: python3 é necessário para ler ${CONFIG}." >&2
  exit 2
fi

# Process substitution esconderia o rc do Python (`mapfile` retornaria 0 mesmo
# com JSON quebrado). Capture primeiro para uma configuração inválida falhar de
# forma explícita em vez de produzir uma lista de tipos vazia e enganosa.
if ! cfg_raw="$(python3 - "$CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rules = json.load(f)["rules"]
print(rules["header-max-length"][2])
for value in rules["type-enum"][2]:
    print(value)
PY
)"; then
  echo "commitlint local: não foi possível ler ${CONFIG}." >&2
  exit 2
fi
mapfile -t _cfg <<< "$cfg_raw"

max_length="${_cfg[0]:-100}"
types=("${_cfg[@]:1}")
(( ${#types[@]} > 0 )) || {
  echo "commitlint local: type-enum vazio em ${CONFIG}." >&2
  exit 2
}
header="$(head -n 1 "$MSG_FILE" | tr -d '\r')"

# Mesma família de mensagens geradas pelo Git que o commitlint ignora por
# padrão. Commits autorais continuam obrigados ao formato convencional.
case "$header" in
  Merge\ * | Revert\ \"* | fixup\!\ * | squash\!\ *) exit 0 ;;
esac

_error() {
  printf '✘ commit inválido: %s\n' "$1" >&2
  printf '  recebido: %s\n' "${header:-<vazio>}" >&2
  printf '  esperado: tipo(escopo opcional): descrição\n' >&2
  printf '  tipos: %s\n' "${types[*]}" >&2
  return 1
}

[[ -n "${header//[[:space:]]/}" ]] || _error "mensagem vazia"
(( ${#header} <= max_length )) || _error "cabeçalho excede ${max_length} caracteres (${#header})"

# Conventional Commits aceito pelo parser do commitlint: tipo, escopo opcional,
# marcador opcional de breaking change e assunto não-vazio após `: `.
if [[ ! "$header" =~ ^([a-z]+)(\([^()]+\))?(!)?:[[:space:]]+(.+)$ ]]; then
  _error "formato não convencional"
fi

type="${BASH_REMATCH[1]}"
subject="${BASH_REMATCH[4]}"
[[ -n "${subject//[[:space:]]/}" ]] || _error "descrição vazia"

valid_type=0
for allowed in "${types[@]}"; do
  if [[ "$type" == "$allowed" ]]; then
    valid_type=1
    break
  fi
done
(( valid_type )) || _error "tipo '${type}' não permitido"
