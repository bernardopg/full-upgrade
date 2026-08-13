#!/usr/bin/env bash
# install-hooks.sh — instala o hook de pre-push que roda scripts/preflight.sh.
#
# A main aceita push direto (sem PR), então este hook é a única barreira antes
# de um commit quebrado virar o HEAD público. Roda o portão completo (sintaxe,
# lint, build e a suíte bats inteira) em ~45s, graças à execução paralela do bats.
#
# Pular pontualmente:  git push --no-verify
# Desinstalar:         rm .git/hooks/pre-push
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="$(git -C "$ROOT" rev-parse --git-path hooks)"
mkdir -p "$HOOK_DIR"

cat > "${HOOK_DIR}/pre-push" <<'HOOK'
#!/usr/bin/env bash
# Gerado por scripts/install-hooks.sh. Pule com: git push --no-verify
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
exec "${ROOT}/scripts/preflight.sh"
HOOK

chmod +x "${HOOK_DIR}/pre-push"
echo "✔ pre-push instalado em ${HOOK_DIR}/pre-push"
echo "  Roda scripts/preflight.sh (~45s, suíte completa em paralelo)."
echo "  Pule com: git push --no-verify"
