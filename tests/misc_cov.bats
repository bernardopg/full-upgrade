#!/usr/bin/env bats
# tests/misc_cov.bats — ramos pequenos que sobraram: unidades críticas da
# sessão, comparação de versões equivalentes, grace period do timeout, imagens
# oficiais do Docker, apps manuais cobertos por step, histórico (sem summary,
# duração menor/igual), auditoria (relatório não gravável, JSON), TokenSave,
# fwupd, notícias do Arch, resumo (skip sem motivo, reboot) e afins.

load test_helper
load stub_helper

setup() {
  load_libs
  for f in packages.sh tools.sh firmware.sh news.sh cleanup.sh pacman.sh audit.sh; do source "${FU_LIB}/steps/$f"; done
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  source "${FU_LIB}/history.sh"
  source "${FU_ROOT}/steps.d/71-tokensave.sh"
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  write_step_event_json() { :; }
  write_summary_event_json() { :; }
}

@test "core: unidades críticas, versões equivalentes e grace period" {
  service_restart_is_session_critical sddm.service
  service_restart_is_session_critical autovt@tty2.service
  [ "$(version_compare 1.2 1.2.0)" = 0 ]
  catalog_info_for_step() { echo "tools||mutating|1||f|d"; }
  _teimoso() { trap '' TERM; sleep 30 & wait; }
  set +e
  run_step "X" _teimoso
  set -e
  [ "${STEP_RESULTS[-1]}" = warn ]
}

@test "docker e apps manuais: nomes reconhecidos" {
  _docker_is_remote_image python:3.13
  _manual_apps_has_step kiro-cli
  _manual_apps_has_step coderabbit
  mkdir -p "$BATS_TEST_TMPDIR/art/photocraft"; touch "$BATS_TEST_TMPDIR/art/photocraft/installation.json"
  ARTCRAFT_DIR="$BATS_TEST_TMPDIR/art" _manual_apps_has_step photocraft-cli
  HOME=/h _manual_apps_managed_target /h/.cargo/bin/x
  HOME=/h _manual_apps_managed_target /h/.local/share/claude/versions/1
}

@test "histórico: sem summary e tendência de duração menor e igual" {
  export LOG_DIR="$BATS_TEST_TMPDIR/logs"; mkdir -p "$LOG_DIR"
  printf '{"event":"run_start","dry_run":false}\n' > "$LOG_DIR/full-upgrade-20261101-100000-1.jsonl"
  run report_history 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"nenhum run com resumo"* ]]
  _run() { printf '{"event":"run_start","dry_run":false,"script_version":"4","timestamp":"2026-11-0%sT10:00:00","scope":"completo"}\n{"event":"summary","ok":1,"warn":0,"todo":0,"fail":0,"skip":0,"duration_seconds":%s}\n' "$2" "$3" > "$LOG_DIR/full-upgrade-2026110$2-100000-1.jsonl"; touch -d "$1" "$LOG_DIR/full-upgrade-2026110$2-100000-1.jsonl"; }
  _run '3 days ago' 1 100; _run '2 days ago' 2 50
  run report_history 5
  [[ "$output" == *"↓ -"* ]]
  _run '1 day ago' 3 50
  run report_history 5
  [[ "$output" == *"estável"* ]]
}

@test "auditoria: relatório não gravável e resumo JSON" {
  for p in cargo arch_audit fwupd secure_boot failed_units journal_auth pip; do eval "_audit_probe_$p() { :; }"; done
  DO_REPORT=1 REPORT_FILE="$BATS_TEST_TMPDIR/nao/existe.md" run run_audit_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *"falha ao gravar relatório de auditoria"* ]]
  DO_REPORT=0 JSON_SUMMARY=1 run run_audit_mode
  [[ "$output" == *'"counts":'* ]]
}

@test "tokensave: ausente, rede fora mas já atual pela API e update falho" {
  TOKENSAVE_BIN="$BATS_TEST_TMPDIR/nao-existe" run update_tokensave
  [[ "$output" == *"TokenSave não encontrado"* ]]
  printf '#!/bin/sh\necho "tokensave 1.2.3"\n' > "$BATS_TEST_TMPDIR/ts"; chmod +x "$BATS_TEST_TMPDIR/ts"
  export TOKENSAVE_BIN="$BATS_TEST_TMPDIR/ts"
  _tokensave_latest_version() { echo 1.2.3; }
  version_is_outdated() { return 0; }
  _retry() { return "$RC_WARN"; }
  run update_tokensave
  [ "$status" -eq 0 ]
  [[ "$output" == *"API oficial confirma que 1.2.3"* ]]
  _retry() { return 5; }
  update_tokensave >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "tokensave upgrade falhou" ]
}

@test "fwupd: refresh falho, sem dispositivos contados e get-updates falho" {
  _retry() { return 3; }
  run update_fwupd
  [ "$status" -eq 3 ]
  _retry() { return 0; }
  fwupdmgr() { case "$1" in get-updates) return "${GU_RC:-2}" ;; get-devices) echo '{}' ;; esac; }
  run update_fwupd
  [[ "$output" == *"Nenhuma atualização de firmware disponível."* ]]
  GU_RC=4 run update_fwupd
  [ "$status" -eq 4 ]
}

@test "notícias: rede fora, erro do curl e nada de ação" {
  curl() { echo "curl: (6) Could not resolve host: archlinux.org"; return 6; }
  run check_arch_news
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Feed de notícias inacessível (rede)"* ]]
  curl() { echo "curl: (22) 500"; return 22; }
  run check_arch_news
  [[ "$output" == *"Falha ao baixar o feed de notícias do Arch (curl rc=22)"* ]]
  curl() { printf '<rss><item><title>Pacote novo</title><link>https://a/b</link><pubDate>Mon, 16 Nov 2026 10:00:00 +0000</pubDate></item></rss>\n'; }
  ARCH_NEWS_SEEN_FILE="$BATS_TEST_TMPDIR/seen" run check_arch_news
  [ "$status" -eq 0 ]
}

@test "resumo: skip sem motivo e recomendação de reboot" {
  STEP_NAMES=("A" "B"); STEP_RESULTS=(ok skip); STEP_TIMES=(1 0); STEP_REASONS=("" ""); STEP_CATEGORIES=(packages packages)
  REBOOT_RECOMMENDATION="kernel novo" TOTAL_START=0
  run print_summary
  [[ "$output" == *"Pulados (1)"* ]]
  [[ "$output" == *"kernel novo"* ]]
}

@test "limpeza: paccache e órfãos que somem depois da rodada" {
  load stub_helper
  stub_path_init; stub_privilege
  stub paccache 0 ""
  run cleanup_paccache
  [ "$(stub_calls paccache)" = "-r -k 2" ]
  stub pacman-conf 0 "$BATS_TEST_TMPDIR/db/"
  stub_script pacman 'case "$1" in -Qdtq) [[ -e "$STUB_LOG.x" ]] || echo libx ;; -Rns) touch "$STUB_LOG.x" ;; esac'
  ASSUME_YES=1 ORPHAN_CLEANUP_MAX_ROUNDS=1 run cleanup_orphans
  [ "$status" -eq 0 ]
}

@test "apps manuais: CLI do Artcraft no segundo grupo" {
  mkdir -p "$BATS_TEST_TMPDIR/art/pdfcraft"; touch "$BATS_TEST_TMPDIR/art/pdfcraft/installation.json"
  ARTCRAFT_DIR="$BATS_TEST_TMPDIR/art" _manual_apps_has_step pdfcraft-cli
}
