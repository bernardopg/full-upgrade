#!/usr/bin/env bats
# tests/manual_binaries_cov.bats — updaters de binário baixado à mão (GitKraken
# CLI, RTK, Snyk): versão atual, release nova com checksum que confere,
# checksum divergente, rede fora e binário sem permissão de escrita. O `curl`
# é stub que serve fixtures locais; nada sai para a rede.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/manual_apps.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/tools.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/security.sh"
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/70-rtk.sh"
  stub_path_init
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"
  export FIX LATEST_TAG=""
  stub uname 0 "x86_64"
  # curl: -w url_effective => .../tag/$LATEST_TAG; -o DEST URL => copia o
  # fixture homônimo; só URL => imprime o fixture.
  stub_script curl 'dest=""; url=""; eff=0
while (( $# )); do case "$1" in -o) dest="$2"; shift 2 ;; -w) eff=1; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
[[ -n "${CURL_FAIL:-}" ]] && exit 6
if (( eff )); then [[ -n "$LATEST_TAG" ]] && echo "https://github.com/x/y/releases/tag/$LATEST_TAG"; exit 0; fi
f="$FIX/${url##*/}"; [[ -f "$f" ]] || exit 22
if [[ -n "$dest" ]]; then cp "$f" "$dest"; else cat "$f"; fi'
}

# ── GitKraken CLI ─────────────────────────────────────────────────────────────

_gk_release() {
  LATEST_TAG="v3.2.0"
  printf 'zip' > "$FIX/gk_3.2.0_linux_amd64.zip"
  if [[ "${1:-}" == bad ]]; then
    echo "0000000000000000000000000000000000000000000000000000000000000000  gk_3.2.0_linux_amd64.zip" > "$FIX/gk_checksums.txt"
  else
    (cd "$FIX" && sha256sum gk_3.2.0_linux_amd64.zip > gk_checksums.txt)
  fi
  # unzip -o -q ZIP -d DIR => cria DIR/gk executável.
  stub_script unzip 'while (( $# )); do case "$1" in -d) d="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$d"; printf "#!/usr/bin/env bash\necho \"GitKraken CLI\nCore 3.2.0\"\n" > "$d/gk"; chmod +x "$d/gk"'
}

@test "update_gk: sem gk ou sem unzip não faz nada" {
  run update_gk
  [ "$status" -eq 0 ]
  stub gk 0 "Core 3.1.0"
  run update_gk
  [[ "$output" == *"curl e unzip são necessários"* ]]
}

@test "update_gk: já atual, release nova instalada e versão desconhecida da rede" {
  stub gk 0 "Core 3.2.0"
  _gk_release
  run update_gk
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está na versão mais recente"* ]]
  stub gk 0 "Core 3.1.0"
  run update_gk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando gk: 3.1.0 → 3.2.0"* ]]
  [[ "$("$STUB_BIN/gk")" == *"Core 3.2.0"* ]]
  LATEST_TAG=""
  stub gk 0 "Core 3.1.0"
  run update_gk
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_gk: checksum divergente e rede fora no download" {
  stub gk 0 "Core 3.1.0"
  _gk_release bad
  run update_gk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum do gk não confere"* ]]
  rm "$FIX/gk_checksums.txt"
  run update_gk
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha de rede ao baixar"* ]]
}

@test "update_gk: arquitetura sem suporte pula" {
  stub gk 0 "Core 3.1.0"; stub unzip 0
  stub uname 0 "riscv64"
  run update_gk
  [ "$status" -eq 0 ]
  [[ "$output" == *"não suportada"* ]]
}

# ── RTK ───────────────────────────────────────────────────────────────────────

_rtk_release() {
  LATEST_TAG="v0.43.0"
  local d="$BATS_TEST_TMPDIR/rtkpkg"; mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "rtk 0.43.0"\n' > "$d/rtk"; chmod +x "$d/rtk"
  tar -czf "$FIX/rtk-x86_64-unknown-linux-musl.tar.gz" -C "$d" rtk
  (cd "$FIX" && sha256sum rtk-x86_64-unknown-linux-musl.tar.gz > checksums.txt)
}

@test "update_rtk: ausente, já atual e release nova" {
  run update_rtk
  [ "$status" -eq 0 ]
  [[ "$output" == *"rtk não encontrado"* ]]
  stub rtk 0 "rtk 0.43.0"
  _rtk_release
  run update_rtk
  [[ "$output" == *"já está na versão mais recente"* ]]
  stub rtk 0 "rtk 0.42.0"
  run update_rtk
  [ "$status" -eq 0 ]
  [[ "$output" == *"rtk atualizado para 0.43.0"* ]]
}

@test "update_rtk: checksum divergente, rede fora e versão indeterminada" {
  stub rtk 0 "rtk 0.42.0"
  _rtk_release
  echo "00  rtk-x86_64-unknown-linux-musl.tar.gz" > "$FIX/checksums.txt"
  run update_rtk
  [ "$status" -eq 1 ]
  rm "$FIX/checksums.txt"
  run update_rtk
  [ "$status" -eq "$RC_WARN" ]
  LATEST_TAG=""
  run update_rtk
  [ "$status" -eq "$RC_WARN" ]
  stub uname 0 "ppc64le"
  run update_rtk
  [ "$status" -eq 0 ]
}

# ── Snyk ──────────────────────────────────────────────────────────────────────

_snyk_release() {
  echo "1.1310.0" > "$FIX/version"
  printf '#!/usr/bin/env bash\necho 1.1310.0\n' > "$FIX/snyk-linux"
  if [[ "${1:-}" == bad ]]; then
    echo "00  snyk-linux" > "$FIX/snyk-linux.sha256"
  else
    (cd "$FIX" && sha256sum snyk-linux > snyk-linux.sha256)
  fi
}

@test "update_snyk: ausente, já atual e release nova verificada" {
  run update_snyk
  [ "$status" -eq 0 ]
  _snyk_release
  stub snyk 0 "1.1310.0"
  run update_snyk
  [[ "$output" == *"já está na versão mais recente"* ]]
  stub snyk 0 "1.1308.4"
  run update_snyk
  [ "$status" -eq 0 ]
  [[ "$output" == *"snyk atualizado para 1.1310.0"* ]]
}

@test "update_snyk: checksum divergente, rede fora e versão indisponível" {
  stub snyk 0 "1.1308.4"
  _snyk_release bad
  run update_snyk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum do snyk não confere"* ]]
  rm "$FIX/snyk-linux.sha256"
  run update_snyk
  [ "$status" -eq "$RC_WARN" ]
  rm "$FIX/version"
  run update_snyk
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_snyk: instalação via npm é coberta pelo step de npm" {
  mkdir -p "$BATS_TEST_TMPDIR/nm/node_modules/snyk"
  printf '#!/usr/bin/env bash\necho 1.0.0\n' > "$BATS_TEST_TMPDIR/nm/node_modules/snyk/cli"
  chmod +x "$BATS_TEST_TMPDIR/nm/node_modules/snyk/cli"
  ln -s "$BATS_TEST_TMPDIR/nm/node_modules/snyk/cli" "$STUB_BIN/snyk"; hash -r
  run update_snyk
  [ "$status" -eq 0 ]
  [[ "$output" == *"gerenciado pelo npm"* ]]
}

# ── OWASP ZAP core ────────────────────────────────────────────────────────────

_zap_release() {
  # Cria o tarball oficial ZAP_2.18.0_Linux.tar.gz e o JSON da release.
  local d="$BATS_TEST_TMPDIR/zappkg/ZAP_2.18.0"; mkdir -p "$d"
  printf '#!/usr/bin/env bash\n' > "$d/zap.sh"; chmod +x "$d/zap.sh"; touch "$d/zap-2.18.0.jar"
  [[ "${1:-}" == semjar ]] && rm "$d/zap-2.18.0.jar"
  tar -czf "$FIX/ZAP_2.18.0_Linux.tar.gz" -C "$BATS_TEST_TMPDIR/zappkg" ZAP_2.18.0
  local sum; sum="$(sha256sum "$FIX/ZAP_2.18.0_Linux.tar.gz" | awk '{print $1}')"
  [[ "${1:-}" == badsum ]] && sum="$(printf '0%.0s' {1..64})"
  ZAP_META="{\"tag_name\":\"v2.18.0\",\"assets\":[{\"name\":\"ZAP_2.18.0_Linux.tar.gz\",\"browser_download_url\":\"https://x/ZAP_2.18.0_Linux.tar.gz\",\"digest\":\"sha256:${sum}\"}]}"
  github_api_get() { printf '%s\n' "$ZAP_META"; }
  ZAP_HOME="$BATS_TEST_TMPDIR/opt/zaproxy"; mkdir -p "$ZAP_HOME"
  printf '#!/usr/bin/env bash\n' > "$ZAP_HOME/zap.sh"; chmod +x "$ZAP_HOME/zap.sh"
}

@test "zap_update_core: já atual e troca atômica (backup some após validar)" {
  _zap_release
  RUN_ID=t1
  run zap_update_core "$ZAP_HOME" 2.18.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"já na versão mais recente"* ]]
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null
  [ -f "$ZAP_HOME/zap-2.18.0.jar" ]
  [ ! -e "${ZAP_HOME}.full-upgrade-backup-t1" ]  # backup removido após validar
}

@test "zap_update_core: sha256 inválido, pacote incompleto e download falho" {
  _zap_release badsum
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"sha256 inválido"* ]]
  _zap_release semjar
  unset status
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null || status=$?
  [[ "$STEP_REASON" == *"pacote sem zap.sh/jar esperados"* ]]
  rm "$FIX/ZAP_2.18.0_Linux.tar.gz"
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null || true
  [[ "$STEP_REASON" == *"download do 2.18.0 falhou"* ]]
}

@test "zap_update_core: diretório sem permissão e sem sudo vira warn" {
  _zap_release
  _manual_write_prefix() { return 1; }
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"exige sudo indisponível"* ]]
}
