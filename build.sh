#!/usr/bin/env bash
# build.sh — concatena lib/* num único arquivo dist/full-upgrade-standalone.sh.
# Para quem prefere instalar/curl um arquivo só. A forma canônica é modular.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/dist/full-upgrade-standalone.sh"
mkdir -p "${ROOT}/dist"

# Ordem de dependência (igual ao entrypoint).
ORDER=(
  lib/globals.sh lib/ui.sh lib/core.sh lib/json.sh lib/sudo.sh
  lib/config.sh lib/catalog.sh lib/cli.sh
  lib/steps/pacman.sh lib/steps/repair.sh lib/steps/containers.sh
  lib/steps/lang_js.sh lib/steps/lang_py.sh lib/steps/lang_rust.sh
  lib/steps/lang_other.sh lib/steps/firmware.sh lib/steps/editor_shell.sh
  lib/steps/ai.sh lib/steps/coverage.sh lib/steps/cleanup.sh lib/steps/doctor.sh
  lib/steps/self_update.sh
  lib/main.sh
)

{
  printf '#!/usr/bin/env bash\n'
  printf '# full-upgrade — standalone (gerado por build.sh; NÃO edite à mão)\n'
  printf 'set -uo pipefail\n\n'
  # Metadados (sem resolução de lib/ — é single-file).
  _build_ver="$(git -C "$ROOT" describe --tags --always 2>/dev/null || true)"
  [[ -z "$_build_ver" && -r "${ROOT}/VERSION" ]] && _build_ver="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
  [[ -z "$_build_ver" ]] && _build_ver="3.0.4"
  printf 'SCRIPT_VERSION="%s"\n' "${_build_ver#v}"
  printf 'SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf %%s "${BASH_SOURCE[0]}")"\n'
  printf 'SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '"'"'{print $1}'"'"' || printf unknown)"\n'
  printf 'FU_ROOT="$(dirname -- "$SCRIPT_PATH")"\n\n'

  for f in "${ORDER[@]}"; do
    printf '# ===== %s =====\n' "$f"
    # remove shebang e diretivas de shell duplicadas de cada módulo
    grep -vE '^#!/usr/bin/env bash$|^# shellcheck shell=bash$' "${ROOT}/${f}"
    printf '\n'
  done

  # Fluxo principal (espelha o entrypoint).
  cat <<'MAIN'
load_config
parse_args "$@"
apply_mode_and_early_exits
if (( ${ENABLE_CUSTOM_TOOLS:-0} )); then
  for _p in "${FU_CONFIG_DIR}"/steps.d/*.sh; do
    [[ -e "$_p" ]] || continue
    # shellcheck source=/dev/null
    source "$_p"
  done
fi
TOTAL_STEPS="$(count_effective_steps)"; export TOTAL_STEPS
setup_logging
print_banner
run_all_steps
finalize
MAIN
} > "$OUT"

chmod +x "$OUT"
echo "Gerado: $OUT"
bash -n "$OUT" && echo "Sintaxe OK"
