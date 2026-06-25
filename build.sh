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
  lib/config.sh lib/catalog.sh lib/cli.sh lib/report.sh lib/history.sh lib/notify.sh lib/tray.sh
  lib/steps/pacman.sh lib/steps/repair.sh lib/steps/containers.sh
  lib/steps/lang_js.sh lib/steps/lang_py.sh lib/steps/lang_rust.sh
  lib/steps/lang_other.sh lib/steps/firmware.sh lib/steps/editor_shell.sh lib/steps/ide.sh

  lib/steps/ai.sh lib/steps/coverage.sh lib/steps/cleanup.sh lib/steps/doctor.sh
  lib/steps/backup.sh lib/steps/self_update.sh lib/steps/audit.sh lib/steps/mcp.sh
  lib/main.sh
)

# Guarda anti-regressão: garante que todo lib/steps/*.sh foi listado em ORDER.
# steps/*.sh só definem funções (ordem entre eles é irrelevante), mas esquecer
# um arquivo quebra o standalone silenciosamente. Falha o build se faltar algum.
_missing=()
for _f in lib/steps/*.sh; do
  case " ${ORDER[*]} " in
    *" $_f "*) ;;
    *) _missing+=("$_f") ;;
  esac
done
if (( ${#_missing[@]} > 0 )); then
  printf 'build.sh: arquivos de step ausentes em ORDER: %s\n' "${_missing[*]}" >&2
  exit 1
fi
unset _missing _f

{
  printf '#!/usr/bin/env bash\n'
  printf '# full-upgrade — standalone (gerado por build.sh; NÃO edite à mão)\n'
  printf 'set -uo pipefail\n\n'
  # Metadados (sem resolução de lib/ — é single-file).
  # Prioridade da versão embutida:
  #   1. git describe SOMENTE se o repo git for ESTE projeto (toplevel contém
  #      full-upgrade.sh + build.sh) — dá o estado de dev (vX.Y.Z-N-gHASH);
  #   2. arquivo VERSION (fonte autoritativa em releases/tarballs);
  #   3. fallback embutido.
  # A checagem do toplevel é essencial: buildar a partir de um tarball extraído
  # dentro de OUTRO repo git (ex.: makepkg no clone do AUR) pegaria a versão
  # errada do repo pai — por isso git describe não é usado nesse caso.
  _build_ver=""
  _git_top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$_git_top" && -f "${_git_top}/full-upgrade.sh" && -f "${_git_top}/build.sh" ]]; then
    _build_ver="$(git -C "$ROOT" describe --tags --always 2>/dev/null || true)"
  fi
  if [[ -z "$_build_ver" && -r "${ROOT}/VERSION" ]]; then
    _build_ver="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
  fi
  [[ -z "$_build_ver" ]] && _build_ver="3.13.2"
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

  # Integrações empacotadas (steps.d/*.sh): inlinadas SEMPRE, como as libs. Só
  # definem funções; o dispatch em main.sh decide rodar por presença da ferramenta
  # (nenhuma roda sem o binário correspondente). Plugins do USUÁRIO continuam
  # carregados em runtime de ~/.config/full-upgrade/steps.d sob ENABLE_CUSTOM_TOOLS.
  for f in "${ROOT}"/steps.d/*.sh; do
    [[ -e "$f" ]] || continue
    printf '# ===== steps.d/%s =====\n' "$(basename -- "$f")"
    grep -vE '^#!/usr/bin/env bash$|^# shellcheck shell=bash$' "$f"
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
