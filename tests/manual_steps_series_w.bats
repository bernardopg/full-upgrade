#!/usr/bin/env bats
# tests/manual_steps_series_w.bats — steps da Série W para componentes que
# nenhum gerenciador atualiza: CLIProxyAPI, extensões do gh, assinaturas do
# ClamAV, ferramentas do mise e plugins Zsh avulsos. Todo binário (curl,
# systemctl, gh, sudo/freshclam, mise) é stub em $BATS_TEST_TMPDIR; os tarballs
# e repositórios git são descartáveis. Nada toca ~/.local, a rede nem o sistema.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/manual_apps.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/tools.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/security.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_other.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/shell.sh"
  log() { printf '%s\n' "$*"; }
  log_raw() { :; }
  log_stream() { cat; }
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_DATA_HOME XDG_CONFIG_HOME ZDOTDIR ZSH ZSH_STANDALONE_PLUGIN_DIRS
  unset CLIPROXYAPI_BIN CLIPROXYAPI_KEEP_VERSIONS CLIPROXYAPI_RESTART_SERVICE CLIPROXYAPI_SERVICE
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export CALLS="$BATS_TEST_TMPDIR/calls" SRV="$BATS_TEST_TMPDIR/srv"
  mkdir -p "$SRV"
  : >"$CALLS"
  STEP_REASON=""
  CLIPROXYAPI_RESTART_SETTLE_S=0
  run_network_cmd() { "$@" 2>&1; }
  PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
}

# Cria um executável $1 com corpo $2 (script bash).
_stub() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"
  chmod +x "$1"
}

# ── github_latest_release_tag ─────────────────────────────────────────────────
# curl falso: o redirect de /releases/latest termina em $LATEST_TAG; os assets
# saem de $SRV pelo último segmento da URL; HEAD devolve $HEAD_CODE.
_stub_curl() {
  _stub "$BATS_TEST_TMPDIR/bin/curl" '
out="" url="" w=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "curl $url" >>"$CALLS"
if [[ "$w" == "%{url_effective}" ]]; then
  [[ -n "${LATEST_TAG:-}" ]] || exit 6
  printf "https://github.com/o/r/releases/tag/%s" "$LATEST_TAG"
  exit 0
fi
[[ "$w" == "%{http_code}" ]] && { printf "%s" "${HEAD_CODE:-000}"; exit 0; }
f="$SRV/${url##*/}"
[[ -f "$f" && "${CURL_FAIL:-}" != *"${url##*/}"* ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$f" "$out"'
}

@test "github_latest_release_tag: tag do redirect" {
  _stub_curl
  LATEST_TAG=v8.0.78 run github_latest_release_tag o/r
  [ "$status" -eq 0 ]
  [ "$output" = "v8.0.78" ]
}

@test "github_latest_release_tag: redirect sem tag de versão vira RC_WARN" {
  _stub_curl
  LATEST_TAG=nightly run github_latest_release_tag o/r
  [ "$status" -eq "$RC_WARN" ]
  run github_latest_release_tag o/r
  [ "$status" -eq "$RC_WARN" ]
}

# ── CLIProxyAPI: helpers puros ────────────────────────────────────────────────
# Binário falso que, como o real, imprime a versão na 1ª linha em qualquer flag.
_fake_cpa() {
  _stub "$1" "echo 'CLIProxyAPI Version: $2, Commit: abc, BuiltAt: 2026-11-18T00:00:00Z'
echo 'Usage of cli-proxy-api'
exit 0"
}

@test "cliproxyapi_version_of: lê a versão da 1ª linha" {
  _fake_cpa "$BATS_TEST_TMPDIR/cpa" 8.0.77
  run cliproxyapi_version_of "$BATS_TEST_TMPDIR/cpa"
  [ "$output" = "8.0.77" ]
}

@test "cliproxyapi_bin: CLIPROXYAPI_BIN, PATH e ~/.local/bin" {
  run cliproxyapi_bin
  [ -z "$output" ]
  _fake_cpa "$HOME/.local/bin/cli-proxy-api" 1.0.0
  run cliproxyapi_bin
  [ "$output" = "$HOME/.local/bin/cli-proxy-api" ]
  _fake_cpa "$BATS_TEST_TMPDIR/outro/cpa" 1.0.0
  CLIPROXYAPI_BIN="$BATS_TEST_TMPDIR/outro/cpa" run cliproxyapi_bin
  [ "$output" = "$BATS_TEST_TMPDIR/outro/cpa" ]
}

@test "cliproxyapi_asset_arch: amd64, aarch64 e sem build" {
  uname() { echo x86_64; }
  run cliproxyapi_asset_arch
  [ "$output" = amd64 ]
  uname() { echo aarch64; }
  run cliproxyapi_asset_arch
  [ "$output" = aarch64 ]
  uname() { echo riscv64; }
  run cliproxyapi_asset_arch
  [ "$status" -ne 0 ]
}

@test "cliproxyapi_versions_root: só no layout versionado" {
  run cliproxyapi_versions_root /h/.local/share/cliproxyapi/versions/8.0.77/cli-proxy-api
  [ "$output" = /h/.local/share/cliproxyapi ]
  run cliproxyapi_versions_root /usr/local/bin/cli-proxy-api
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cliproxyapi_prune_list: mantém as N mais novas e nunca a em uso" {
  local d="$BATS_TEST_TMPDIR/versions"
  mkdir -p "$d"/{8.0.9,8.0.10,8.0.77,8.0.78}
  run cliproxyapi_prune_list "$d" 2 8.0.78
  [ "$output" = "$(printf '%s\n' 8.0.10 8.0.9)" ]
  # keep inválido vale 1; a em uso (antiga) fica mesmo fora da janela
  run cliproxyapi_prune_list "$d" x 8.0.9
  [ "$output" = "$(printf '%s\n' 8.0.77 8.0.10)" ]
  run cliproxyapi_prune_list "$BATS_TEST_TMPDIR/nada" 2 1.0
  [ -z "$output" ]
}

# ── CLIProxyAPI: update ───────────────────────────────────────────────────────
# Instalação no layout versionado (como a da máquina de referência), release
# 8.0.78 publicado em $SRV com checksums.txt e systemctl falso: o serviço só
# fica ativo se o symlink NÃO aponta para uma versão em $BAD_VERSION.
_cpa_setup() {
  local root="$HOME/.local/share/cliproxyapi"
  CPA_ROOT="$root"
  _fake_cpa "$root/versions/8.0.77/cli-proxy-api" 8.0.77
  mkdir -p "$HOME/.local/bin"
  ln -s "$root/versions/8.0.77/cli-proxy-api" "$HOME/.local/bin/cli-proxy-api"
  _stub_curl
  export LATEST_TAG=v8.0.78
  _cpa_release 8.0.78 8.0.78
  mkdir -p "$BATS_TEST_TMPDIR/state"
  touch "$BATS_TEST_TMPDIR/state/active"
  _stub "$BATS_TEST_TMPDIR/bin/systemctl" "
echo \"systemctl \$*\" >>\"$CALLS\"
case \"\$*\" in
  '--user is-active --quiet '*) [[ -f '$BATS_TEST_TMPDIR/state/active' ]] ;;
  '--user restart '*)
    if [[ -n \"\${BAD_VERSION:-}\" && \"\$(readlink '$HOME/.local/bin/cli-proxy-api')\" == *\"\$BAD_VERSION\"* ]]; then
      rm -f '$BATS_TEST_TMPDIR/state/active'
    else
      touch '$BATS_TEST_TMPDIR/state/active'
    fi ;;
esac"
}

# Publica em $SRV o tarball da versão $1 cujo binário diz ser $2.
_cpa_release() {
  local stage="$BATS_TEST_TMPDIR/stage-$1" asset="CLIProxyAPI_$1_linux_amd64.tar.gz"
  _fake_cpa "$stage/cli-proxy-api" "$2"
  tar -czf "$SRV/$asset" -C "$stage" cli-proxy-api
  (cd "$SRV" && sha256sum "$asset" >checksums.txt)
}

@test "update_cliproxyapi: ausente => 0" {
  run update_cliproxyapi
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "update_cliproxyapi: arquitetura sem build pula" {
  _cpa_setup
  uname() { echo riscv64; }
  run update_cliproxyapi
  [ "$status" -eq 0 ]
  [[ "$output" == *"sem build"* ]]
}

@test "update_cliproxyapi: última versão indisponível vira RC_WARN" {
  _cpa_setup
  unset LATEST_TAG
  update_cliproxyapi >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "última versão do CLIProxyAPI indisponível" ]
}

@test "update_cliproxyapi: já na última não baixa nada" {
  _cpa_setup
  LATEST_TAG=v8.0.77 run update_cliproxyapi
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está na versão mais recente (8.0.77)"* ]]
  ! grep -q 'tar.gz' "$CALLS"
}

@test "update_cliproxyapi: versão nova troca o symlink, reinicia o serviço e poda" {
  _cpa_setup
  mkdir -p "$CPA_ROOT/versions/8.0.70"
  run update_cliproxyapi
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/cli-proxy-api")" = "$CPA_ROOT/versions/8.0.78/cli-proxy-api" ]
  [ "$(cliproxyapi_version_of "$HOME/.local/bin/cli-proxy-api")" = 8.0.78 ]
  grep -q 'systemctl --user restart cliproxyapi.service' "$CALLS"
  [[ "$output" == *"reiniciado com a versão 8.0.78"* ]]
  # KEEP=2: fica a nova e a anterior (rollback); a 8.0.70 sai
  [ -d "$CPA_ROOT/versions/8.0.77" ]
  [ ! -d "$CPA_ROOT/versions/8.0.70" ]
  [[ "$output" == *"Versão antiga removida: 8.0.70"* ]]
}

@test "update_cliproxyapi: serviço que não sobe volta o binário anterior" {
  _cpa_setup
  BAD_VERSION=8.0.78 update_cliproxyapi >"$BATS_TEST_TMPDIR/out" || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$(readlink "$HOME/.local/bin/cli-proxy-api")" = "$CPA_ROOT/versions/8.0.77/cli-proxy-api" ]
  [ ! -d "$CPA_ROOT/versions/8.0.78" ]
  [ -f "$BATS_TEST_TMPDIR/state/active" ]
  [[ "$STEP_REASON" == *"revertido para 8.0.77"* ]]
}

@test "update_cliproxyapi: rollback sem o serviço voltar avisa o journalctl" {
  _cpa_setup
  BAD_VERSION=cli-proxy-api run update_cliproxyapi
  [ "$status" -eq 1 ]
  [[ "$output" == *"journalctl --user -u cliproxyapi.service"* ]]
}

@test "update_cliproxyapi: CLIPROXYAPI_RESTART_SERVICE=0 só troca o binário" {
  _cpa_setup
  CLIPROXYAPI_RESTART_SERVICE=0 run update_cliproxyapi
  [ "$status" -eq 0 ]
  ! grep -q 'restart' "$CALLS"
  [[ "$output" == *"até reiniciar (CLIPROXYAPI_RESTART_SERVICE=0)"* ]]
}

@test "update_cliproxyapi: binário avulso é trocado no lugar, sem serviço ativo" {
  _cpa_setup
  rm -f "$HOME/.local/bin/cli-proxy-api" "$BATS_TEST_TMPDIR/state/active"
  _fake_cpa "$HOME/.local/bin/cli-proxy-api" 8.0.77
  run update_cliproxyapi
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.local/bin/cli-proxy-api" ]
  [ "$(cliproxyapi_version_of "$HOME/.local/bin/cli-proxy-api")" = 8.0.78 ]
  [ ! -e "$HOME/.local/bin/cli-proxy-api.old" ]
  ! grep -q 'restart' "$CALLS"
}

@test "update_cliproxyapi: binário avulso com serviço que não sobe restaura o .old" {
  _cpa_setup
  rm -f "$HOME/.local/bin/cli-proxy-api"
  _fake_cpa "$HOME/.local/bin/cli-proxy-api" 8.0.77
  # sem symlink, o systemctl falso olha o readlink vazio: força a falha
  BAD_VERSION="" _stub "$BATS_TEST_TMPDIR/bin/systemctl" "
case \"\$*\" in
  '--user is-active --quiet '*) [[ -f '$BATS_TEST_TMPDIR/state/active' ]] ;;
  '--user restart '*) rm -f '$BATS_TEST_TMPDIR/state/active' ;;
esac"
  run update_cliproxyapi
  [ "$status" -eq 1 ]
  [ "$(cliproxyapi_version_of "$HOME/.local/bin/cli-proxy-api")" = 8.0.77 ]
}

@test "update_cliproxyapi: sem escrita no diretório vira RC_TODO" {
  _cpa_setup
  chmod 555 "$HOME/.local/bin"
  update_cliproxyapi >/dev/null || status=$?
  chmod 755 "$HOME/.local/bin"
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"sem permissão de escrita em $HOME/.local/bin"* ]]
}

@test "update_cliproxyapi: asset ainda não publicado (404) mantém a versão" {
  _cpa_setup
  rm -f "$SRV"/CLIProxyAPI_*
  HEAD_CODE=404 run update_cliproxyapi
  [ "$status" -eq 0 ]
  [[ "$output" == *"ainda sem o asset"* ]]
  [ "$(readlink "$HOME/.local/bin/cli-proxy-api")" = "$CPA_ROOT/versions/8.0.77/cli-proxy-api" ]
}

@test "update_cliproxyapi: download falhando sem 404 vira RC_WARN" {
  _cpa_setup
  CURL_FAIL=checksums.txt HEAD_CODE=000 update_cliproxyapi >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "download do CLIProxyAPI 8.0.78 falhou" ]
}

@test "update_cliproxyapi: sha256 divergente falha e mantém o binário" {
  _cpa_setup
  printf '%064d  CLIProxyAPI_8.0.78_linux_amd64.tar.gz\n' 0 >"$SRV/checksums.txt"
  update_cliproxyapi >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "CLIProxyAPI 8.0.78 não verificado" ]
  [ ! -d "$CPA_ROOT/versions/8.0.78" ]
}

@test "update_cliproxyapi: binário do release com outra versão é recusado" {
  _cpa_setup
  _cpa_release 8.0.78 8.0.70
  update_cliproxyapi >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "CLIProxyAPI 8.0.78: versão do binário não confere" ]
}

@test "update_cliproxyapi: falha na instalação mantém o binário" {
  _cpa_setup
  _cliproxyapi_install() { return 1; }
  update_cliproxyapi >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "instalação do CLIProxyAPI 8.0.78 falhou" ]
  [ "$(readlink "$HOME/.local/bin/cli-proxy-api")" = "$CPA_ROOT/versions/8.0.77/cli-proxy-api" ]
}

@test "_cliproxyapi_install: falha no layout versionado não deixa .new" {
  _cpa_setup
  install() { return 1; }
  run _cliproxyapi_install "$HOME/.local/bin/cli-proxy-api" /nada 9.9.9 \
    "$CPA_ROOT/versions/8.0.77/cli-proxy-api" "$CPA_ROOT"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/cli-proxy-api.new" ]
}

@test "_cliproxyapi_install: falha no binário avulso não deixa .new" {
  _fake_cpa "$BATS_TEST_TMPDIR/b/cpa" 1.0.0
  install() { return 1; }
  run _cliproxyapi_install "$BATS_TEST_TMPDIR/b/cpa" /nada 2.0.0 "$BATS_TEST_TMPDIR/b/cpa" ""
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/b/cpa.new" ]
}

@test "_cliproxyapi_restart_ok: restart recusado pelo systemctl é falha" {
  _stub "$BATS_TEST_TMPDIR/bin/systemctl" 'exit 1'
  run _cliproxyapi_restart_ok cliproxyapi.service
  [ "$status" -eq 1 ]
}

# ── Extensões do gh ───────────────────────────────────────────────────────────
_stub_gh() {
  _stub "$BATS_TEST_TMPDIR/bin/gh" "
case \"\$1 \$2\" in
  'extension list') printf '%b' \"\${GH_LIST:-}\" ;;
  'extension upgrade') echo \"gh \$*\" >>\"$CALLS\"; printf '%b\n' \"\${GH_UP_OUT:-}\"; exit \${GH_UP_RC:-0} ;;
esac"
}

@test "gh_extension_names: tira o prefixo 'gh ' da coluna 1" {
  run gh_extension_names "$(printf 'gh dash\tdlvhdr/gh-dash\tv4.7.0\ngh copilot\tgithub/gh-copilot\tv1.0\n')"
  [ "$output" = "$(printf '%s\n' dash copilot)" ]
}

@test "update_gh_extensions: nenhuma extensão não chama upgrade" {
  _stub_gh
  run update_gh_extensions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma extensão"* ]]
  ! grep -q upgrade "$CALLS"
}

@test "update_gh_extensions: upgrade --all sem prompt" {
  _stub_gh
  GH_LIST='gh dash\tdlvhdr/gh-dash\tv4.7.0\n' GH_UP_OUT='[dash]: upgraded from v4.7.0 to v4.8.0' run update_gh_extensions
  [ "$status" -eq 0 ]
  grep -q 'gh extension upgrade --all' "$CALLS"
  [[ "$output" == *"1 extensão(ões) do gh: dash"* ]]
  [[ "$output" == *"upgraded from v4.7.0 to v4.8.0"* ]]
}

@test "update_gh_extensions: limite da API vira RC_WARN" {
  _stub_gh
  export GH_LIST='gh dash\tdlvhdr/gh-dash\tv4.7.0\n' GH_UP_OUT='HTTP 403: API rate limit exceeded' GH_UP_RC=1
  update_gh_extensions >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "update_gh_extensions: rede (RC_WARN do run_network_cmd) vira RC_WARN" {
  _stub_gh
  export GH_LIST='gh dash\tdlvhdr/gh-dash\tv4.7.0\n'
  run_network_cmd() { return "$RC_WARN"; }
  update_gh_extensions >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "update_gh_extensions: repositório sumido vira RC_TODO" {
  _stub_gh
  export GH_LIST='gh velha\tfulano/gh-velha\tv1\n' GH_UP_OUT='[velha]: HTTP 404: Not Found' GH_UP_RC=1
  update_gh_extensions >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"repositório inacessível"* ]]
}

@test "update_gh_extensions: outra falha é fail" {
  _stub_gh
  export GH_LIST='gh dash\tdlvhdr/gh-dash\tv4.7.0\n' GH_UP_OUT='erro qualquer' GH_UP_RC=1
  update_gh_extensions >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "gh extension upgrade --all falhou (rc=1)" ]
}

# ── ClamAV (freshclam) ────────────────────────────────────────────────────────
# `sudo` falso executa o comando direto; freshclam falso responde por env.
_stub_freshclam() {
  _stub "$BATS_TEST_TMPDIR/bin/sudo" 'exec "$@"'
  _stub "$BATS_TEST_TMPDIR/bin/freshclam" "echo \"freshclam \$*\" >>\"$CALLS\"; printf '%b\n' \"\${FC_OUT:-}\"; exit \${FC_RC:-0}"
  _stub "$BATS_TEST_TMPDIR/bin/systemctl" "[[ -n \"\${3:-}\" && \" \${ACTIVE_UNITS:-} \" == *\" \$3 \"* ]]"
}

@test "freshclam_summary: atualizada e em dia" {
  run freshclam_summary "$(printf '%s\n' \
    'daily.cvd updated (version: 27830, sigs: 2070000, f-level: 90, builder: raynman)' \
    'main.cvd database is up-to-date (version: 62, sigs: 6647427, f-level: 90, builder: sigmgr)' \
    'Testing database: xyz' 'bytecode.cld updated (version: 339, sigs: 80)')"
  [ "$output" = "$(printf '%s\n' 'daily 27830 (atualizada)' 'main 62 (em dia)' 'bytecode 339 (atualizada)')" ]
}

@test "freshclam_auto_unit: serviço ou timer ativos" {
  _stub_freshclam
  ACTIVE_UNITS=clamav-freshclam-once.timer run freshclam_auto_unit
  [ "$output" = clamav-freshclam-once.timer ]
  run freshclam_auto_unit
  [ "$status" -eq 1 ]
}

@test "update_clamav_signatures: unit ativa => não concorre com ela" {
  _stub_freshclam
  ACTIVE_UNITS=clamav-freshclam.service run update_clamav_signatures
  [ "$status" -eq 0 ]
  [[ "$output" == *"mantidas por clamav-freshclam.service"* ]]
  ! grep -q freshclam "$CALLS"
}

@test "update_clamav_signatures: sem unit roda o freshclam e resume as bases" {
  _stub_freshclam
  FC_OUT='daily.cvd updated (version: 27830, sigs: 1)\nmain.cvd updated (version: 62, sigs: 1)' run update_clamav_signatures
  [ "$status" -eq 0 ]
  grep -q 'freshclam --stdout' "$CALLS"
  [[ "$output" == *"daily 27830 (atualizada)"* ]]
}

@test "update_clamav_signatures: rc 1 com base em dia é ok" {
  _stub_freshclam
  FC_OUT='daily.cld database is up-to-date (version: 27830, sigs: 1)' FC_RC=1 run update_clamav_signatures
  [ "$status" -eq 0 ]
}

@test "update_clamav_signatures: cool-down do CDN vira RC_WARN" {
  _stub_freshclam
  export FC_OUT='WARNING: You are on cool-down until after: 2026-11-19 12:00:00' FC_RC=1
  update_clamav_signatures >"$BATS_TEST_TMPDIR/out" || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  grep -q 'cool-down' "$BATS_TEST_TMPDIR/out"
}

@test "update_clamav_signatures: rede (RC_WARN) vira RC_WARN" {
  _stub_freshclam
  run_network_cmd() { return "$RC_WARN"; }
  update_clamav_signatures >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "update_clamav_signatures: erro de config é fail" {
  _stub_freshclam
  export FC_OUT='ERROR: Failed to load config file' FC_RC=56
  update_clamav_signatures >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "freshclam falhou (rc=56); veja o log" ]
}

# ── mise ──────────────────────────────────────────────────────────────────────
# mise falso: confere que roda a partir do $HOME e responde por env.
_stub_mise() {
  _stub "$BATS_TEST_TMPDIR/bin/mise" "
echo \"mise \$* (cwd=\$PWD yes=\${MISE_YES:-})\" >>\"$CALLS\"
case \"\$1 \${2:-}\" in
  'plugins ls') printf '%b' \"\${MISE_PLUGINS:-}\" ;;
  'plugins update') exit \${MISE_PLUG_RC:-0} ;;
  'outdated --json') printf '%s\n' \"\${MISE_OUTDATED-{\}}\"; [[ -n \"\${MISE_OUT_ERR:-}\" ]] && echo \"\$MISE_OUT_ERR\" >&2; exit \${MISE_OUT_RC:-0} ;;
  'upgrade '*) echo 'mise node@24.22.3 ✓ installed'; exit \${MISE_UP_RC:-0} ;;
esac"
}

@test "mise_outdated_summary: lista, vazio e inválido" {
  run mise_outdated_summary '{"node":{"current":"24.21.0","latest":"24.22.3"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "node 24.21.0 → 24.22.3" ]
  run mise_outdated_summary '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run mise_outdated_summary 'lixo'
  [ "$status" -ne 0 ]
}

@test "update_mise_tools: nada desatualizado não chama upgrade" {
  _stub_mise
  run update_mise_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"já estão nas últimas versões"* ]]
  ! grep -q 'mise upgrade' "$CALLS"
  ! grep -q 'plugins update' "$CALLS"
}

@test "update_mise_tools: desatualizado roda mise upgrade no \$HOME sem prompt" {
  _stub_mise
  MISE_OUTDATED='{"node":{"current":"24.21.0","latest":"24.22.3"}}' run update_mise_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"node 24.21.0 → 24.22.3"* ]]
  grep -q "mise upgrade (cwd=$HOME yes=1)" "$CALLS"
  grep -q "mise outdated --json (cwd=$HOME" "$CALLS"
}

@test "update_mise_tools: plugins não-core são renovados antes; falha só avisa" {
  _stub_mise
  MISE_PLUGINS='flutter\n' MISE_PLUG_RC=1 run update_mise_tools
  [ "$status" -eq 0 ]
  grep -q 'mise plugins update' "$CALLS"
  [[ "$output" == *"mise plugins update falhou"* ]]
}

@test "update_mise_tools: outdated sem rede vira RC_WARN" {
  _stub_mise
  export MISE_OUTDATED='' MISE_OUT_RC=1 MISE_OUT_ERR='error sending request: Could not resolve host: nodejs.org'
  update_mise_tools >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  ! grep -q 'mise upgrade' "$CALLS"
}

@test "update_mise_tools: outdated ilegível cai para o upgrade completo" {
  _stub_mise
  MISE_OUTDATED='lixo' MISE_OUT_RC=1 MISE_OUT_ERR='erro estranho' run update_mise_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"rodando o upgrade completo"* ]]
  grep -q 'mise upgrade' "$CALLS"
}

@test "update_mise_tools: upgrade sem rede vira RC_WARN; outra falha é fail" {
  _stub_mise
  export MISE_OUTDATED='{"node":{"current":"1","latest":"2"}}'
  run_network_cmd() { [[ "$*" == *upgrade* ]] && return "$RC_WARN"; "$@"; }
  update_mise_tools >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  run_network_cmd() { "$@" 2>&1; }
  status=0
  MISE_UP_RC=3 update_mise_tools >/dev/null || status=$?
  [ "$status" -eq 1 ]
  [ "$STEP_REASON" = "mise upgrade falhou (rc=3)" ]
}

# ── Plugins Zsh avulsos ───────────────────────────────────────────────────────
_git_setup() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email t@t
  git config --global user.name t
  git config --global init.defaultBranch main
}

# Cria upstream/<nome> com um commit e clona em $2.
_clone() {
  git init -q "$BATS_TEST_TMPDIR/up/$1"
  git -C "$BATS_TEST_TMPDIR/up/$1" commit -q --allow-empty -m one
  git clone -q "$BATS_TEST_TMPDIR/up/$1" "$2"
}

@test "zsh_standalone_plugin_dirs: detecta ~/.local/share/zsh-* e \$ZDOTDIR/plugins, ignora sem git e o OMZ" {
  _git_setup
  _clone zsh-defer "$HOME/.local/share/zsh-defer"
  mkdir -p "$HOME/.local/share/zsh-semgit"
  export ZDOTDIR="$HOME/zdot"
  _clone fzf-tab "$ZDOTDIR/plugins/fzf-tab"
  export ZSH="$HOME/.local/share/zsh-omz"
  _clone omz "$ZSH"
  run zsh_standalone_plugin_dirs
  [ "$output" = "$(printf '%s\n' "$HOME/.local/share/zsh-defer" "$ZDOTDIR/plugins/fzf-tab")" ]
}

@test "zsh_standalone_plugin_dirs: ZSH_STANDALONE_PLUGIN_DIRS com ~, vírgula e duplicata" {
  _git_setup
  _clone p1 "$HOME/plugs/p1"
  _clone p2 "$HOME/plugs/p2"
  ZSH_STANDALONE_PLUGIN_DIRS='~/plugs/p1,~/plugs/*' run zsh_standalone_plugin_dirs
  [ "$output" = "$(printf '%s\n' "$HOME/plugs/p1" "$HOME/plugs/p2")" ]
}

@test "update_zsh_standalone_plugins: nenhum clone => 0" {
  run update_zsh_standalone_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum clone git"* ]]
}

@test "update_zsh_standalone_plugins: puxa o clone atrasado" {
  _git_setup
  _clone zsh-defer "$HOME/.local/share/zsh-defer"
  git -C "$BATS_TEST_TMPDIR/up/zsh-defer" commit -q --allow-empty -m two
  run update_zsh_standalone_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"zsh-defer: 1 commit(s) atrás"* ]]
  [ "$(git -C "$HOME/.local/share/zsh-defer" log -1 --format=%s)" = two ]
}

@test "update_zsh_standalone_plugins: modificação local vira RC_TODO sem perder nada" {
  _git_setup
  _clone zsh-defer "$HOME/.local/share/zsh-defer"
  git -C "$BATS_TEST_TMPDIR/up/zsh-defer" commit -q --allow-empty -m two
  echo local >"$HOME/.local/share/zsh-defer/meu.zsh"
  git -C "$HOME/.local/share/zsh-defer" add meu.zsh
  git -C "$HOME/.local/share/zsh-defer" commit -q -m local
  git -C "$BATS_TEST_TMPDIR/up/zsh-defer" commit -q --allow-empty -m three
  echo sujo >>"$HOME/.local/share/zsh-defer/meu.zsh"
  update_zsh_standalone_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "plugin(s) com modificações locais: zsh-defer" ]
  grep -q sujo "$HOME/.local/share/zsh-defer/meu.zsh"
}

@test "zsh_git_plugins_update: upstream reescrito com árvore limpa realinha" {
  _git_setup
  _clone zsh-defer "$HOME/.local/share/zsh-defer"
  local up="$BATS_TEST_TMPDIR/up/zsh-defer"
  git -C "$up" commit -q --allow-empty --amend -m reescrito
  git -C "$up" commit -q --allow-empty -m depois
  run zsh_git_plugins_update "$HOME/.local/share/zsh-defer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"histórico reescrito pelo upstream"* ]]
  [[ "$output" == *"Plugins atualizados: zsh-defer"* ]]
  [ "$(git -C "$HOME/.local/share/zsh-defer" log -1 --format=%s)" = depois ]
}

@test "zsh_git_plugins_update: pull que deixa conflito restaura a árvore e vira RC_TODO" {
  _git_setup
  _clone zsh-defer "$HOME/.local/share/zsh-defer"
  git -C "$BATS_TEST_TMPDIR/up/zsh-defer" commit -q --allow-empty -m two
  # pull "ok" que deixou unmerged (pull.rebase + autostash): só depois do pull.
  git_pull_ff_only() { touch "$1/.pulled"; return 0; }
  git_has_unmerged() { [[ -e "$1/.pulled" ]]; }
  zsh_git_plugins_update "$HOME/.local/share/zsh-defer" >"$BATS_TEST_TMPDIR/out" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  grep -q 'pull deixou conflito' "$BATS_TEST_TMPDIR/out"
}
