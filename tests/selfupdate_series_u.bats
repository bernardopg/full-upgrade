#!/usr/bin/env bats
# tests/selfupdate_series_u.bats — steps da Série U para programas instalados
# por script próprio (vite-plus, qodo, ori, spawn, Herdr). Todo binário é stub
# em $BATS_TEST_TMPDIR e a rede é simulada; nada toca ~/.local nem a internet.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/manual_apps.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/tools.sh"
  log() { printf '%s\n' "$*"; }
  log_raw() { :; }
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_DATA_HOME VITE_PLUS_HOME
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  run_network_cmd() { "$@"; }
  PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
}

# Cria um executável $1 com corpo $2 (script bash).
_stub() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"
  chmod +x "$1"
}

# ── manual_bin_path ───────────────────────────────────────────────────────────
@test "manual_bin_path: prefere o binário do PATH" {
  _stub "$BATS_TEST_TMPDIR/bin/qodo" 'exit 0'
  _stub "$HOME/.qodo/bin/qodo" 'exit 0'
  run manual_bin_path qodo "$HOME/.qodo/bin/qodo"
  [ "$output" = "$BATS_TEST_TMPDIR/bin/qodo" ]
}

@test "manual_bin_path: cai para o caminho alternativo executável" {
  _stub "$HOME/.qodo/bin/qodo" 'exit 0'
  run manual_bin_path qodo "$HOME/nada" "$HOME/.qodo/bin/qodo"
  [ "$output" = "$HOME/.qodo/bin/qodo" ]
}

@test "manual_bin_path: ignora função de shell com o mesmo nome" {
  vp() { :; }
  run manual_bin_path vp "$HOME/nada"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ── vite-plus ─────────────────────────────────────────────────────────────────
_stub_vp() {
  _stub "$HOME/.local/share/vite-plus/bin/vp" "
case \"\$1 \${2:-}\" in
  '--version '*) echo 'vp v1.3.0' ;;
  'upgrade --check') printf '%s\n' \"\$VP_CHECK\"; exit \${VP_CHECK_RC:-0} ;;
  'upgrade ') echo upgrade >>\"$CALLS\"; exit \${VP_APPLY_RC:-0} ;;
esac"
}

@test "vite_plus_bin: acha o vp em ~/.local/share/vite-plus fora do PATH" {
  _stub_vp
  run vite_plus_bin
  [ "$output" = "$HOME/.local/share/vite-plus/bin/vp" ]
}

@test "update_vite_plus: ausente => 0" {
  run update_vite_plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "update_vite_plus: sem versão nova não aplica" {
  _stub_vp
  export VP_CHECK="info: vite-plus is up to date (1.7.0)"
  run update_vite_plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"já na versão mais recente"* ]]
  [ ! -s "$CALLS" ]
}

@test "update_vite_plus: versão nova aplica o vp upgrade" {
  _stub_vp
  export VP_CHECK="Update available: 1.3.0 → 1.7.0"
  run update_vite_plus
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "upgrade" ]
}

@test "update_vite_plus: check falhando vira RC_WARN" {
  _stub_vp
  export VP_CHECK="erro" VP_CHECK_RC=1
  run update_vite_plus
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_vite_plus: upgrade falhando vira RC_WARN" {
  _stub_vp
  export VP_CHECK="Update available: 1.3.0 → 1.7.0" VP_APPLY_RC=1
  run update_vite_plus
  [ "$status" -eq "$RC_WARN" ]
}

# ── qodo ──────────────────────────────────────────────────────────────────────
@test "update_qodo: usa o binário de ~/.qodo/bin e aplica quando há versão nova" {
  _stub "$HOME/.qodo/bin/qodo" "
case \"\$1 \${2:-}\" in
  '--version '*) echo '2.3.0' ;;
  'update --check') echo 'qodo 2.3.3 is available (you have 2.3.0; latest-2). Run qodo update.' ;;
  'update ') echo apply >>\"$CALLS\" ;;
esac"
  run update_qodo
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "apply" ]
}

@test "update_qodo: atualizado não aplica" {
  _stub "$HOME/.qodo/bin/qodo" "
case \"\$1 \${2:-}\" in
  '--version '*) echo '2.3.3' ;;
  'update --check') echo 'qodo is up to date (2.3.3)' ;;
  'update ') echo apply >>\"$CALLS\" ;;
esac"
  run update_qodo
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "update_qodo: ausente => 0" {
  run update_qodo
  [ "$status" -eq 0 ]
}

# ── ori ───────────────────────────────────────────────────────────────────────
@test "ori_update_available: true, false e sem campo" {
  run ori_update_available '{"data":{"release":{"updateAvailable":true}}}'
  [ "$status" -eq 0 ]
  run ori_update_available '{"data":{"release":{"updateAvailable": false}}}'
  [ "$status" -eq 1 ]
  run ori_update_available '{"ok":false}'
  [ "$status" -eq 2 ]
}

_stub_ori() {
  _stub "$BATS_TEST_TMPDIR/bin/ori" "
case \"\$1 \${2:-}\" in
  '--version '*) echo 'ori 0.17.1' ;;
  'update --check') printf '%s\n' \"\$ORI_CHECK\"; exit \${ORI_CHECK_RC:-0} ;;
  'update ') echo apply >>\"$CALLS\"; exit \${ORI_APPLY_RC:-0} ;;
esac"
}

@test "update_ori: atualizado não aplica" {
  _stub_ori
  export ORI_CHECK='{"ok":true,"data":{"release":{"currentVersion":"0.17.1","latestVersion":"0.17.1","updateAvailable":false}}}'
  run update_ori
  [ "$status" -eq 0 ]
  [[ "$output" == *"ori já na versão mais recente (0.17.1)"* ]]
  [ ! -s "$CALLS" ]
}

@test "update_ori: versão nova aplica o ori update" {
  _stub_ori
  export ORI_CHECK='{"ok":true,"data":{"release":{"currentVersion":"0.17.0","latestVersion":"0.17.1","updateAvailable":true}}}'
  run update_ori
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando ori: 0.17.0 → 0.17.1"* ]]
  [ "$(cat "$CALLS")" = "apply" ]
}

@test "update_ori: resposta sem o campo vira RC_WARN e não aplica" {
  _stub_ori
  export ORI_CHECK='{"ok":false,"error":"x"}'
  run update_ori
  [ "$status" -eq "$RC_WARN" ]
  [ ! -s "$CALLS" ]
}

@test "update_ori: falha do check e do update viram RC_WARN" {
  _stub_ori
  export ORI_CHECK='x' ORI_CHECK_RC=1
  run update_ori
  [ "$status" -eq "$RC_WARN" ]
  export ORI_CHECK='{"updateAvailable":true}' ORI_CHECK_RC=0 ORI_APPLY_RC=3
  run update_ori
  [ "$status" -eq "$RC_WARN" ]
}

# ── spawn ─────────────────────────────────────────────────────────────────────
@test "spawn_is_openrouter: reconhece só o spawn da OpenRouter" {
  _stub "$BATS_TEST_TMPDIR/bin/spawn" 'printf "spawn v1.1.1\n  https://github.com/OpenRouterLabs/spawn\n"'
  run spawn_is_openrouter
  [ "$status" -eq 0 ]
  _stub "$BATS_TEST_TMPDIR/bin/spawn" 'echo "spawn 2.0 (outro projeto)"'
  run spawn_is_openrouter
  [ "$status" -ne 0 ]
}

@test "update_spawn: chama spawn update e propaga falha como RC_WARN" {
  _stub "$BATS_TEST_TMPDIR/bin/spawn" "echo \"\$*\" >>\"$CALLS\"; exit \${SPAWN_RC:-0}"
  run update_spawn
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "update" ]
  export SPAWN_RC=1
  run update_spawn
  [ "$status" -eq "$RC_WARN" ]
}

# ── Herdr ─────────────────────────────────────────────────────────────────────
CORE_JSON='{
  "version": "0.1.22",
  "generation": 1,
  "notes": "**Notas** com espaços"
}'

_app_json() {
  printf '{\n  "version": "0.1.16",\n  "core_min": "0.1.11",\n  "targets": {\n    "linux-aarch64": { "url": "https://r/app/0.1.16/a.tar.gz", "sha256": "aaa" },\n    "linux-x86_64": {\n      "url": "https://r/app/0.1.16/herdr-app-linux-x86_64.tar.gz",\n      "sha256": "%s"\n    }\n  }\n}\n' "$1"
}

@test "herdr_manifest_field: lê a versão do topo" {
  run herdr_manifest_field "$CORE_JSON" version
  [ "$output" = "0.1.22" ]
  run herdr_manifest_field "$(_app_json abc)" core_min
  [ "$output" = "0.1.11" ]
}

@test "herdr_manifest_target_field: url e sha256 do alvo certo" {
  run herdr_manifest_target_field "$(_app_json abc)" linux-x86_64 url
  [ "$output" = "https://r/app/0.1.16/herdr-app-linux-x86_64.tar.gz" ]
  run herdr_manifest_target_field "$(_app_json abc)" linux-x86_64 sha256
  [ "$output" = "abc" ]
  run herdr_manifest_target_field "$(_app_json abc)" linux-aarch64 sha256
  [ "$output" = "aaa" ]
  run herdr_manifest_target_field "$(_app_json abc)" windows-x86_64 url
  [ "$output" = "" ]
}

_stub_core() {
  _stub "$HOME/.local/bin/herdr-core" "
case \"\$1\" in
  --version) echo \"hc \${HC_VER:-0.1.21}\" ;;
  update) echo \"\$*\" >>\"$CALLS\" ;;
esac"
}

@test "herdr_installed: core ou app presentes" {
  run herdr_installed
  [ "$status" -ne 0 ]
  _stub_core
  run herdr_installed
  [ "$status" -eq 0 ]
}

@test "_herdr_update_core: versão nova chama update --version" {
  _stub_core
  fetch_network_text() { printf '%s\n' "$CORE_JSON"; }
  run _herdr_update_core "$HOME/.local/bin/herdr-core"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "update --version 0.1.22" ]
}

@test "_herdr_update_core: já na última não reinicia o servidor" {
  _stub_core
  export HC_VER=0.1.22
  fetch_network_text() { printf '%s\n' "$CORE_JSON"; }
  run _herdr_update_core "$HOME/.local/bin/herdr-core"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "_herdr_update_core: manifest indisponível vira RC_WARN" {
  _stub_core
  fetch_network_text() { return "$RC_WARN"; }
  run _herdr_update_core "$HOME/.local/bin/herdr-core"
  [ "$status" -eq "$RC_WARN" ]
}

# Monta um tar.gz com herdr-app/herdr-app que imprime a versão $1.
_app_tarball() {
  local d="$BATS_TEST_TMPDIR/pkg"
  rm -rf "$d"; mkdir -p "$d/herdr-app"
  printf '#!/usr/bin/env bash\necho "herdr-app %s"\n' "$1" >"$d/herdr-app/herdr-app"
  chmod +x "$d/herdr-app/herdr-app"
  tar -czf "$BATS_TEST_TMPDIR/app.tar.gz" -C "$d" herdr-app
  sha256sum "$BATS_TEST_TMPDIR/app.tar.gz" | cut -d' ' -f1
}

_install_app() {
  mkdir -p "$HOME/.local/share/herdr-app"
  printf '#!/usr/bin/env bash\necho "herdr-app 0.1.15"\n' >"$HOME/.local/share/herdr-app/herdr-app"
  chmod +x "$HOME/.local/share/herdr-app/herdr-app"
  : >"$HOME/.local/share/herdr-app/antigo.txt"
}

@test "_herdr_update_app: sha256 confere => troca o diretório inteiro" {
  [[ "$(uname -m)" == x86_64 ]] || skip "fixture do alvo linux-x86_64"
  _install_app
  local sum; sum="$(_app_tarball 0.1.16)"
  APP_JSON="$(_app_json "$sum")"
  fetch_network_text() { printf '%s\n' "$APP_JSON"; }
  curl() { local o; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done; cp "$BATS_TEST_TMPDIR/app.tar.gz" "$o"; }
  run _herdr_update_app "$HOME/.local/share/herdr-app"
  [ "$status" -eq 0 ]
  run "$HOME/.local/share/herdr-app/herdr-app" --version
  [ "$output" = "herdr-app 0.1.16" ]
  [ ! -e "$HOME/.local/share/herdr-app/antigo.txt" ]
  [ ! -e "$HOME/.local/share/herdr-app.old" ]
}

@test "_herdr_update_app: sha256 divergente mantém a versão atual e falha" {
  [[ "$(uname -m)" == x86_64 ]] || skip "fixture do alvo linux-x86_64"
  _install_app
  _app_tarball 0.1.16 >/dev/null
  APP_JSON="$(_app_json deadbeef)"
  fetch_network_text() { printf '%s\n' "$APP_JSON"; }
  curl() { local o; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done; cp "$BATS_TEST_TMPDIR/app.tar.gz" "$o"; }
  run _herdr_update_app "$HOME/.local/share/herdr-app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 não confere"* ]]
  run "$HOME/.local/share/herdr-app/herdr-app" --version
  [ "$output" = "herdr-app 0.1.15" ]
}

@test "_herdr_update_app: já na última não baixa nada" {
  _install_app
  APP_JSON="$(_app_json x | sed 's/0.1.16/0.1.15/')"
  fetch_network_text() { printf '%s\n' "$APP_JSON"; }
  curl() { echo baixou >>"$CALLS"; }
  run _herdr_update_app "$HOME/.local/share/herdr-app"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "update_herdr: falha do app tem precedência sobre aviso do core" {
  _stub_core
  _install_app
  _herdr_update_core() { return "$RC_WARN"; }
  _herdr_update_app() { return 1; }
  run update_herdr
  [ "$status" -eq 1 ]
}

@test "update_herdr: aviso de rede do core vira RC_WARN" {
  _stub_core
  _herdr_update_core() { return "$RC_WARN"; }
  run update_herdr
  [ "$status" -eq "$RC_WARN" ]
}
