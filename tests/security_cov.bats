#!/usr/bin/env bats
# tests/security_cov.bats — snyk (arquiteturas, sem sudo, mktemp, install) e o
# core do ZAP com troca atômica falhando em cada etapa (extração, backup, troca,
# validação pós-instalação), rota IPv6 e o desfecho dos add-ons. PATH isolado;
# curl serve fixtures; diretórios do ZAP são descartáveis.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/manual_apps.sh"
  source "${FU_LIB}/steps/security.sh"
  stub_path_init
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON="" RUN_ID=t
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"; export FIX
  export TMPDIR="$BATS_TEST_TMPDIR"
  stub uname 0 "x86_64"
  run_network_cmd() { "$@"; }
  stub_script curl 'dest=""; url=""
while (( $# )); do case "$1" in -o) dest="$2"; shift 2 ;; --retry|--connect-timeout) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
f="$FIX/${url##*/}"; [[ -f "$f" ]] || exit 22
if [[ -n "$dest" ]]; then cp "$f" "$dest"; else cat "$f"; fi'
}

# ── snyk ──────────────────────────────────────────────────────────────────────

_snyk() {
  echo "1.1310.0" > "$FIX/version"
  printf '#!/usr/bin/env bash\necho 1.1310.0\n' > "$FIX/snyk-linux"
  (cd "$FIX" && sha256sum snyk-linux > snyk-linux.sha256)
  stub snyk 0 "1.1308.4"
}

@test "snyk: arm64 já atual e arquitetura sem suporte" {
  stub snyk 0 "1.1310.0"; echo "1.1310.0" > "$FIX/version"
  stub uname 0 aarch64
  run update_snyk
  [[ "$output" == *"snyk já está na versão mais recente"* ]]
  stub uname 0 riscv64
  run update_snyk
  [[ "$output" == *"não suportada pelo atualizador do snyk"* ]]
}

@test "snyk: sem sudo, mktemp falho e install falho" {
  _snyk
  _manual_write_prefix() { return 1; }
  update_snyk >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "atualize o snyk com sudo disponível"* ]]
  _manual_write_prefix() { :; }
  mktemp() { return 1; }
  run update_snyk
  [ "$status" -eq "$RC_WARN" ]
  unset -f mktemp
  stub install 1 ""
  run update_snyk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao instalar o binário snyk"* ]]
}

# ── ZAP core ──────────────────────────────────────────────────────────────────

# Tarball oficial (ou lixo com BAD=1) + JSON da release com o sha256 correto.
_zap() {
  local d="$BATS_TEST_TMPDIR/zappkg/ZAP_2.18.0"; mkdir -p "$d"
  printf '#!/usr/bin/env bash\n' > "$d/zap.sh"; chmod +x "$d/zap.sh"; touch "$d/zap-2.18.0.jar"
  if [[ "${1:-}" == lixo ]]; then echo lixo > "$FIX/ZAP_2.18.0_Linux.tar.gz"
  else tar -czf "$FIX/ZAP_2.18.0_Linux.tar.gz" -C "$BATS_TEST_TMPDIR/zappkg" ZAP_2.18.0; fi
  local sum; sum="$(sha256sum "$FIX/ZAP_2.18.0_Linux.tar.gz" | awk '{print $1}')"
  ZAP_META="{\"tag_name\":\"v2.18.0\",\"assets\":[{\"name\":\"ZAP_2.18.0_Linux.tar.gz\",\"browser_download_url\":\"https://x/ZAP_2.18.0_Linux.tar.gz\",\"digest\":\"sha256:${sum}\"}]}"
  github_api_get() { printf '%s\n' "$ZAP_META"; }
  _manual_write_prefix() { :; }
  ZAP_HOME="$BATS_TEST_TMPDIR/opt/zaproxy"; mkdir -p "$ZAP_HOME"
  printf '#!/usr/bin/env bash\n' > "$ZAP_HOME/zap.sh"; chmod +x "$ZAP_HOME/zap.sh"; touch "$ZAP_HOME/zap-2.17.0.jar"
}

@test "zap core: extração falha e diretório sem permissão para o backup" {
  _zap lixo
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null 2>&1 || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "ZAP core 2.18.0: extração falhou"* ]]
  _zap; unset status
  chmod 555 "$BATS_TEST_TMPDIR/opt"
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null 2>&1 || status=$?
  chmod 755 "$BATS_TEST_TMPDIR/opt"
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "ZAP core: não foi possível mover"* ]]
  [ -f "$ZAP_HOME/zap-2.17.0.jar" ]
}

@test "zap core: troca falha e validação pós-instalação falha restauram a versão anterior" {
  _zap
  mv() { [[ "$2" == */ZAP_2.18.0 ]] && return 1; command mv "$@"; }
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null 2>&1 || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"troca de diretório falhou; versão anterior restaurada" ]]
  [ -f "$ZAP_HOME/zap-2.17.0.jar" ]
  unset -f mv; unset status
  chown() { rm -f "$3"/zap-2.18.0.jar; }
  zap_update_core "$ZAP_HOME" 2.17.0 >/dev/null 2>&1 || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"validação pós-instalação falhou; versão anterior restaurada" ]]
  [ -f "$ZAP_HOME/zap-2.17.0.jar" ]
}

@test "zap: rota IPv6 e add-ons com falha e sem mensagem reconhecida" {
  run zap_has_ipv6_route
  [ "$status" -eq 1 ]
  stub ip 0 "2606:4700:4700::1111 from :: via fe80::1 dev wlan0"
  run zap_has_ipv6_route
  [ "$status" -eq 0 ]
  stub ip 0 "unreachable 2606:4700:4700::1111"
  run zap_has_ipv6_route
  [ "$status" -eq 1 ]
  mkdir -p "$BATS_TEST_TMPDIR/zh"; touch "$BATS_TEST_TMPDIR/zh/zap-2.18.0.jar"
  printf '#!/usr/bin/env bash\necho "${ZAP_OUT:-}"; exit "${ZAP_RC:-0}"\n' > "$BATS_TEST_TMPDIR/zh/zap.sh"; chmod +x "$BATS_TEST_TMPDIR/zh/zap.sh"
  ln -s "$BATS_TEST_TMPDIR/zh/zap.sh" "$STUB_BIN/zap"; hash -r
  zap_update_core() { return 0; }
  zap_free_port() { echo 50000; }
  ZAP_RC=3 ZAP_OUT="erro" update_zap >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "ZAP: atualização de add-ons falhou (rc=3)" ]
  ZAP_OUT="pronto" run update_zap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Add-ons do ZAP atualizados (core 2.18.0)"* ]]
}
