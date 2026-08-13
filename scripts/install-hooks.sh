#!/usr/bin/env bash
# install-hooks.sh — instala os portões locais para o fluxo de push direto.
#
# - commit-msg: valida Conventional Commits imediatamente (~0,03s);
# - pre-push: valida commits pendentes + sintaxe + lint + build + bats (~45s).
#
# Hooks customizados preexistentes nunca são sobrescritos silenciosamente. Hooks
# gerados por versões anteriores deste instalador são reconhecidos e atualizados.
#
# Pular pontualmente: git commit/push --no-verify
# Desinstalar:        rm .git/hooks/commit-msg .git/hooks/pre-push
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Override apenas para testes; no uso normal resolve worktrees corretamente por
# `git rev-parse --git-path hooks` em vez de assumir .git/hooks.
HOOK_DIR="${FULL_UPGRADE_HOOK_DIR:-$(git -C "$ROOT" rev-parse --git-path hooks)}"
MARKER="full-upgrade managed hook"
mkdir -p "$HOOK_DIR"

_can_replace() {
  local hook="$1"
  [[ ! -e "$hook" ]] && return 0
  grep -qE "${MARKER}|Gerado por scripts/install-hooks.sh" "$hook" 2>/dev/null && return 0
  printf '✘ hook customizado já existe: %s\n' "$hook" >&2
  printf '  Preserve/mova esse arquivo antes de rodar o instalador; nada foi sobrescrito.\n' >&2
  return 1
}

# Valida os dois antes de tocar em qualquer um: instalação atômica do ponto de
# vista do usuário (não deixa metade dos portões atualizada).
_can_replace "${HOOK_DIR}/commit-msg"
_can_replace "${HOOK_DIR}/pre-push"

cat > "${HOOK_DIR}/commit-msg" <<'HOOK'
#!/usr/bin/env bash
# full-upgrade managed hook — gerado por scripts/install-hooks.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
exec "${ROOT}/scripts/validate-commit-msg.sh" "$1"
HOOK

cat > "${HOOK_DIR}/pre-push" <<'HOOK'
#!/usr/bin/env bash
# full-upgrade managed hook — gerado por scripts/install-hooks.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
exec "${ROOT}/scripts/preflight.sh"
HOOK

chmod +x "${HOOK_DIR}/commit-msg" "${HOOK_DIR}/pre-push"
echo "✔ commit-msg instalado em ${HOOK_DIR}/commit-msg"
echo "  Valida Conventional Commits ao criar o commit."
echo "✔ pre-push instalado em ${HOOK_DIR}/pre-push"
echo "  Valida commits pendentes e roda o portão completo (~45s)."
echo "  Pule pontualmente com: git commit/push --no-verify"
