#!/usr/bin/env bats
# tests/lang_rust_cov.bats — auditoria cargo (audit_cargo_bins e a coleta), o
# rebuild com lock fresco (_rust_rebuild_crate), o memo e os ramos restantes do
# autofix_rust_cves. PATH isolado: cargo/rustup são stubs; $CARGO_HOME é tmp.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/lang_rust.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export CARGO_HOME="$BATS_TEST_TMPDIR/cargo" LOG_DIR="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$LOG_DIR"
}

_bin() { mkdir -p "$CARGO_HOME/bin"; printf '#!/bin/sh\n' > "$CARGO_HOME/bin/$1"; chmod +x "$CARGO_HOME/bin/$1"; }

# cargo audit com saída em $AUDIT_OUT e rc em $AUDIT_RC.
_audit() {
  export AUDIT_OUT="$1" AUDIT_RC="${2:-0}"
  stub_script cargo 'case "$1" in audit) printf "%s\n" "$AUDIT_OUT"; exit "$AUDIT_RC" ;; esac'
}

VULN="error: 1 vulnerability found in $BATS_TEST_TMPDIR/cargo/bin/tokei
error: 1 vulnerability found in $BATS_TEST_TMPDIR/cargo/bin/rustup"

# ── update_cargo_bins / _rust_run_capture ────────────────────────────────────

@test "update_cargo_bins roda install-update; _rust_run_capture devolve saída e rc" {
  stub cargo 0 ""
  run update_cargo_bins
  [ "$status" -eq 0 ]
  [ "$(stub_calls cargo)" = "install-update -a" ]
  run _rust_run_capture sh -c 'echo saida; exit 3'
  [ "$status" -eq 3 ]
  [[ "$output" == *saida* ]]
}

# ── audit_cargo_bins ──────────────────────────────────────────────────────────

@test "audit: sem \$CARGO_HOME/bin, diretório vazio e só binário gigante" {
  run audit_cargo_bins
  [[ "$output" == *"não encontrado"* ]]
  mkdir -p "$CARGO_HOME/bin"
  run audit_cargo_bins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem binários cargo para auditar"* ]]
  truncate -s 600M "$CARGO_HOME/bin/enorme"; chmod +x "$CARGO_HOME/bin/enorme"
  audit_cargo_bins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"todos excedem 512 MiB"* ]]
}

@test "audit: falha de rede repetida tenta de novo e vira warn" {
  _bin tokei
  sleep() { :; }
  _audit "error: could not resolve host github.com" 1
  run audit_cargo_bins
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"tentando novamente"* ]]
  [[ "$output" == *"falha de rede transitória"* ]]
  [ "$(stub_calls cargo | wc -l)" -eq 2 ]
}

@test "audit: rc≠0 sem achado vira warn; limpo vira ok" {
  _bin tokei
  _audit "erro qualquer" 2
  audit_cargo_bins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "auditoria cargo falhou (rc=2); consulte o log" ]
  _audit "Loaded 900 advisories" 0
  run audit_cargo_bins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem achados de segurança"* ]]
}

@test "audit: achados separam toolchain e cargo-installed com remediação" {
  _bin tokei; _bin rustup
  _audit "$VULN" 1
  run audit_cargo_bins
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Instalados via cargo (1): tokei"* ]]
  [[ "$output" == *"Toolchain/rustup (1): rustup"* ]]
  [[ "$output" == *"rustup self update && rustup update"* ]]
}

# ── _rust_collect_vuln_bins ───────────────────────────────────────────────────

@test "coleta: sem diretório, vazio, rede, rc≠0 sem achado e achados" {
  run _rust_collect_vuln_bins
  [ "$status" -eq 0 ] && [ -z "$output" ]
  mkdir -p "$CARGO_HOME/bin"
  run _rust_collect_vuln_bins
  [ "$status" -eq 0 ] && [ -z "$output" ]
  _bin tokei
  _audit "network is unreachable" 1
  run _rust_collect_vuln_bins
  [ "$status" -eq "$RC_WARN" ]
  _audit "falhou" 1
  run _rust_collect_vuln_bins
  [ "$status" -eq "$RC_WARN" ]
  _audit "$VULN" 1
  run _rust_collect_vuln_bins
  [ "$status" -eq 0 ]
  [ "$output" = $'rustup\ntokei' ]
}

# ── memo ──────────────────────────────────────────────────────────────────────

@test "memo: advisory DB nova invalida; gravação falha não deixa .tmp" {
  stub_script git 'echo rev2'
  printf '# advisory-db rev1\ncrate\t1.0\t%s\n' "$(date +%s)" > "$LOG_DIR/rust-cve-rebuild-nofix.tsv"
  run _rust_rebuild_memo_skip crate 1.0
  [ "$status" -eq 1 ]
  _rust_rebuild_memo_record outro 2.0
  run cat "$LOG_DIR/rust-cve-rebuild-nofix.tsv"
  [[ "$output" == "# advisory-db rev2"* ]]
  [[ "$output" != *$'crate\t1.0'* ]]
  LOG_DIR="$BATS_TEST_TMPDIR/nao/existe"
  run _rust_rebuild_memo_record x 1
  [ "$status" -eq 0 ]
  [ ! -e "$LOG_DIR" ]
}

# ── _rust_rebuild_crate ───────────────────────────────────────────────────────

_src() { mkdir -p "$CARGO_HOME/registry/src/index/tokei-1.0"; echo '[package]' > "$CARGO_HOME/registry/src/index/tokei-1.0/Cargo.toml"; }

# cargo: install --list lista tokei; update rc $UPD_RC; auditable build cria os
# binários de $BUILD_BINS (rc $BUILD_RC).
_cargo_build() {
  export UPD_RC="${1:-0}" BUILD_RC="${2:-0}" BUILD_BINS="${3-tokei}" LIST="${4-$'tokei v1.0:\n    tokei'}"
  stub_script cargo '
case "$1 $2" in
  "install --list") printf "%s\n" "$LIST" ;;
  "install --force") exit 0 ;;
  "update --manifest-path") exit "$UPD_RC" ;;
  "auditable build")
    d=""; while [[ $# -gt 0 ]]; do [[ "$1" == --target-dir ]] && d="$2"; shift; done
    mkdir -p "$d/release"
    for b in $BUILD_BINS; do printf "#!/bin/sh\n" > "$d/release/$b"; chmod +x "$d/release/$b"; done
    exit "$BUILD_RC" ;;
esac'
  stub cargo-auditable 0 ""
}

@test "rebuild: sem cargo-auditable cai no cargo install --force" {
  _src
  stub cargo 0 ""
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 0 ]
  [ "$(stub_calls cargo)" = "install --force tokei" ]
}

@test "rebuild: crate sem binários instalados, update e build falhando" {
  _src; _bin tokei
  _cargo_build 0 0 tokei ""
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 1 ]
  _cargo_build 1
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 1 ]
  _cargo_build 0 1
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 1 ]
}

@test "rebuild: binário não gerado e falha ao instalar não trocam o original" {
  _src; _bin tokei
  _cargo_build 0 0 ""
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 1 ]
  _cargo_build 0 0 tokei
  chmod 555 "$CARGO_HOME/bin"
  run _rust_rebuild_crate tokei 1.0
  chmod 755 "$CARGO_HOME/bin"
  [ "$status" -eq 1 ]
  [ "$(cat "$CARGO_HOME/bin/tokei")" = '#!/bin/sh' ]
  [ -z "$(find "$CARGO_HOME/bin" -name '.tokei.*')" ]
}

@test "rebuild: sucesso instala o binário novo no lugar do antigo" {
  _src; _bin tokei
  echo velho >> "$CARGO_HOME/bin/tokei"
  _cargo_build 0 0 tokei
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 0 ]
  [ "$(cat "$CARGO_HOME/bin/tokei")" = '#!/bin/sh' ]
}

@test "rebuild: sem fonte em registry/src baixa via cargo fetch e usa o lock fresco" {
  _bin tokei
  _cargo_build 0 0 tokei
  # O stub de cargo também atende o fetch: extrai a fonte como o cargo real.
  stub_script cargo '
case "$1 $2" in
  "install --list") printf "%s\n" "$LIST" ;;
  "install --force") exit 0 ;;
  "fetch --manifest-path")
    grep -q "^tokei = \"=1.0\"$" "$3" || exit 9
    mkdir -p "$CARGO_HOME/registry/src/index/tokei-1.0"; echo "[package]" > "$CARGO_HOME/registry/src/index/tokei-1.0/Cargo.toml" ;;
  "update --manifest-path") exit "$UPD_RC" ;;
  "auditable build")
    d=""; while [[ $# -gt 0 ]]; do [[ "$1" == --target-dir ]] && d="$2"; shift; done
    mkdir -p "$d/release"
    for b in $BUILD_BINS; do printf "#!/bin/sh\n" > "$d/release/$b"; chmod +x "$d/release/$b"; done
    exit "$BUILD_RC" ;;
esac'
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 0 ]
  grep -q "^cargo fetch --manifest-path" "$STUB_LOG"
  grep -q "^cargo auditable build" "$STUB_LOG"
  ! grep -q "^cargo install --force" "$STUB_LOG"
}

@test "rebuild: fetch falhando cai no cargo install --force" {
  _bin tokei
  _cargo_build 0 0 tokei
  stub_script cargo '
case "$1 $2" in
  "install --list") printf "%s\n" "$LIST" ;;
  "install --force") exit 0 ;;
  "fetch --manifest-path") exit 101 ;;
esac'
  run _rust_rebuild_crate tokei 1.0
  [ "$status" -eq 0 ]
  grep -q "^cargo install --force tokei" "$STUB_LOG"
}

@test "_rust_fetch_crate_source: nome ou versão inválidos não geram manifesto" {
  stub cargo 0 ""
  run _rust_fetch_crate_source 'x"; evil' 1.0
  [ "$status" -eq 1 ]
  run _rust_fetch_crate_source tokei '1.0"'
  [ "$status" -eq 1 ]
  [ -z "$(stub_calls cargo)" ]
}

# ── autofix_rust_cves: ramos restantes ───────────────────────────────────────

_autofix_env() {
  AUTO_FIX_RUST_CVES=1 ASSUME_YES=1
  _rust_run_capture() { return 0; }
  STATEF="$BATS_TEST_TMPDIR/n"; echo 0 > "$STATEF"
}

@test "autofix: sem ferramenta de remediação vira warn; sem cargo-update avisa" {
  _autofix_env
  _rust_collect_vuln_bins() { printf 'tokei\n'; }
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"cargo-update ausente"* ]]
  [[ "$output" == *"Nenhuma ferramenta de remediação"* ]]
}

@test "autofix: re-auditoria sem rede depois de remediação real" {
  _autofix_env
  stub rustup 0 ""
  _rust_collect_vuln_bins() {
    local n; n=$(( $(cat "$STATEF") + 1 )); echo "$n" > "$STATEF"
    (( n == 1 )) && { printf 'rustup\n'; return 0; }
    return "$RC_WARN"
  }
  autofix_rust_cves >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "re-auditoria sem rede" ]
}

# Coleta: 1ª e 2ª chamadas acham tokei; a 3ª (pós-rebuild) devolve $AFTER/$AFTER_RC.
_rebuild_flow() {
  _autofix_env
  stub cargo-install-update 0 ""
  stub_script cargo 'case "$1 $2" in "install --list") printf "tokei v1.0:\n    tokei\n" ;; esac'
  export AFTER="$1" AFTER_RC="${2:-0}"
  _rust_collect_vuln_bins() {
    local n; n=$(( $(cat "$STATEF") + 1 )); echo "$n" > "$STATEF"
    (( n <= 2 )) && { printf 'tokei\n'; return 0; }
    [[ -n "$AFTER" ]] && printf '%s\n' "$AFTER"
    return "$AFTER_RC"
  }
  _rust_rebuild_crate() { return 0; }
}

@test "autofix: rebuild com lock fresco remove a CVE" {
  _rebuild_flow ""
  run autofix_rust_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"cargo install --force tokei"* ]]
  [[ "$output" == *"Binários com achados após rebuild: 0"* ]]
}

@test "autofix: re-auditoria pós-rebuild sem rede vira warn" {
  _rebuild_flow "" "$RC_WARN"
  autofix_rust_cves >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "re-auditoria sem rede" ]
}

@test "autofix: pós-rebuild só sobra toolchain" {
  _rebuild_flow rustup
  autofix_rust_cves >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "achados de segurança persistem na toolchain: rustup" ]
}

@test "autofix: CVE persiste após rebuild grava o memo" {
  _rebuild_flow tokei
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"CVEs persistem após rebuild com resolução fresca (tokei)"* ]]
  grep -q $'^tokei\t1.0\t' "$LOG_DIR/rust-cve-rebuild-nofix.tsv"
}

@test "autofix: prompt interativo recusado e aceito" {
  local defs="AUTO_FIX_RUST_CVES=1 ASSUME_YES=0
_rust_collect_vuln_bins() { printf 'tokei\n'; }
autofix_rust_cves; echo \"rc=\$?\""
  pty_call "steps/lang_rust.sh" "$defs" 'n\r'
  [[ "$output" == *"Aplicar remediação"* ]]
  [[ "$output" == *"cancelada pelo usuário"* ]]
  [[ "$output" == *"rc=$RC_TODO"* ]]
  pty_call "steps/lang_rust.sh" "$defs" 's\r'
  [[ "$output" == *"Nenhuma ferramenta de remediação"* ]]
  [[ "$output" == *"rc=$RC_WARN"* ]]
}

@test "audit: advisory informativo (unsound) vira warn de cobertura parcial" {
  _bin tokei
  _audit "Warning: unsound
Crate: foo" 0
  audit_cargo_bins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"cobertura parcial"* ]]
}

@test "autofix: memo fresco pula o rebuild; rebuild falho vira acionável" {
  _rebuild_flow tokei
  printf 'tokei\t1.0\t%s\n' "$(date +%s)" > "$LOG_DIR/rust-cve-rebuild-nofix.tsv"
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"persistiu; pulando o"* ]]
  [[ "$output" == *"CVEs seguem em tokei"* ]]
  rm "$LOG_DIR/rust-cve-rebuild-nofix.tsv"; echo 0 > "$STATEF"
  _rust_rebuild_crate() { return 1; }
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Rebuild indisponível/falhou para: tokei"* ]]
}
