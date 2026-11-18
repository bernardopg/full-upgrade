#!/usr/bin/env bats
# tests/ui_cov.bats — fallback ASCII dos símbolos, largura via tput, todas as
# linhas de modo do banner, símbolos de status, steps de categoria desconhecida
# no resumo, totais com falha, JSON final e a lista de pacotes truncada.

load test_helper

setup() {
  load_libs
  QUIET=0 LOG_FILE=/dev/null JSONL_FILE=/dev/null NO_COLOR=1
  write_summary_event_json() { :; }
}

@test "símbolos ASCII fora de locale UTF-8" {
  run env -u LC_ALL -u LC_CTYPE LANG=C NO_UNICODE=0 bash -c "source '$FU_LIB/ui.sh'; printf '%s %s %s' \"\$SYM_OK\" \"\$BOX_TL\" \"\$HR_HEAVY\""
  [ "$output" = "ok + =" ]
}

@test "ui_width: sem COLUMNS usa o tput uma vez" {
  unset COLUMNS UI_WIDTH_TPUT_CACHE
  tput() { echo 77; }
  [ "$(ui_width)" = 77 ]
}

@test "banner: todas as linhas de modo" {
  DRY_RUN=1 QUIET=1 VERBOSE=1 MODE=doctor ONLY_CATEGORY=ai RESUME_STEPS="X" NO_REPAIR=1
  NO_CLEANUP=1 DEVEL_UPDATE=1 JSON_SUMMARY=1 FULL_UPGRADE_SKIP="A,B"
  FULL_UPGRADE_DISABLED_INTEGRATIONS="cua-driver" SCRIPT_SHA256=abcdef0123456789
  run print_banner
  for marca in DRY-RUN QUIET VERBOSE MODE:doctor ONLY RESUME NO-REPAIR NO-CLEANUP --devel JSON "SKIP] Steps ignorados: A,B" "INTEGRAÇÕES DESABILITADAS] cua-driver"; do
    [[ "$output" == *"$marca"* ]] || { echo "faltou $marca"; false; }
  done
}

@test "_status_sym: cada status tem símbolo" {
  [ "$(_status_sym warn)" = "${SYM_WARN}|" ]
  [ "$(_status_sym fail)" = "${SYM_FAIL}|" ]
  [ "$(_status_sym skip)" = "${SYM_SKIP}|" ]
  run summary_category_in_groups categoria-inexistente
  [ "$status" -eq 1 ]
}

@test "resumo: categoria desconhecida, falha e JSON no fim" {
  STEP_NAMES=("Step órfão" "Step quebrado" "Step pendente")
  STEP_RESULTS=(warn fail todo)
  STEP_TIMES=(3 4 5)
  STEP_REASONS=("motivo do órfão" "" "decidir")
  STEP_CATEGORIES=("categoria-x" "packages" "packages")
  JSON_SUMMARY=1 TOTAL_START=0 SECONDS=10
  run print_summary
  [[ "$output" == *"Step órfão"*"motivo do órfão"* ]]
  [[ "$output" == *"Atenção: 1 step(s) com falha"* ]]
  [[ "$output" == *"Aviso: 1 item(ns) merecem revisão"* ]]
  [[ "$output" == *'"fail":1'* ]]
  run summary_category_totals_json
  [[ "$output" == *'"fail":1'* ]]
}

@test "pacotes: instalados aparecem e a lista passa de 30 truncada" {
  before="$BATS_TEST_TMPDIR/b" after="$BATS_TEST_TMPDIR/a"
  : > "$before"; : > "$after"
  for i in $(seq -w 1 35); do echo "pkg$i 1.0-1" >> "$after"; done
  run print_pkg_changes "$before" "$after"
  [[ "$output" == *"35 instalado(s)"* ]]
  [[ "$output" == *"+ pkg01"* ]]
  [[ "$output" == *"… e mais 5 (lista completa no log)"* ]]
}
