#!/usr/bin/env bats
# tests/ui.bats — comportamento responsivo e compacto da TUI.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  LOG_FILE="${BATS_TEST_TMPDIR}/ui.log"
  JSONL_FILE="${BATS_TEST_TMPDIR}/ui.jsonl"
  QUIET=0
  write_step_event_json() { :; }
  write_summary_event_json() { :; }
}

@test "ui_truncate: preserva texto curto e corta texto longo com reticências" {
  [ "$(ui_truncate "curto" 8)" = "curto" ]
  [ "$(ui_truncate "abcdefghij" 6)" = "abcde…" ]
  [ "$(ui_truncate "abc" 1)" = "…" ]
}

@test "ui_progress: adapta a barra à largura do terminal" {
  COLUMNS=80
  wide="$(ui_progress 1 4)"
  [ "${#wide}" -gt 14 ]

  COLUMNS=60
  medium="$(ui_progress 1 4)"
  [ "${#medium}" -lt "${#wide}" ]
  [[ "$medium" == *"25%" ]]

  COLUMNS=40
  [ "$(ui_progress 1 4)" = " 25%" ]
}

@test "step_warn: preserva reason alinhado e o mostra junto ao status" {
  STEP_NAMES=("Step de teste")
  STEP_CATEGORIES=("core")
  STEP_START=$SECONDS
  STEP_REASON="falha transitória detalhada"

  run step_warn

  [ "$status" -eq 0 ]
  [[ "$output" == *"falha transitória detalhada"* ]]
}

@test "step_warn: registra reason no array do processo atual" {
  STEP_NAMES=("Step de teste")
  STEP_CATEGORIES=("core")
  STEP_START=$SECONDS
  STEP_REASON="motivo preservado"

  step_warn >/dev/null

  [ "${STEP_RESULTS[0]}" = "warn" ]
  [ "${STEP_REASONS[0]}" = "motivo preservado" ]
}

@test "step_skip: modo compacto silencia terminal mas preserva log e arrays" {
  COMPACT_SKIP_OUTPUT=1

  step_skip "Step filtrado" "modo doctor" >"${BATS_TEST_TMPDIR}/terminal.out"

  [ ! -s "${BATS_TEST_TMPDIR}/terminal.out" ]
  [ "${STEP_RESULTS[0]}" = "skip" ]
  [ "${STEP_REASONS[0]}" = "modo doctor" ]
  grep -q "Step filtrado (modo doctor)" "$LOG_FILE"
}

@test "print_summary: muitos skips viram uma única linha compacta" {
  COMPACT_SKIP_OUTPUT=1
  STEP_NAMES=(A B C D E F G H I)
  STEP_RESULTS=(skip skip skip skip skip skip skip skip skip)
  STEP_TIMES=(0 0 0 0 0 0 0 0 0)
  STEP_CATEGORIES=(core core core core core core core core core)
  STEP_REASONS=(filtro filtro filtro filtro filtro filtro filtro filtro filtro)

  run print_summary

  [ "$status" -eq 0 ]
  [[ "$output" == *"9 steps omitidos por filtro"* ]]
  [[ "$output" != *"  A"* ]]
}

# ── ui_pad_left / ui_strip_ansi / ui_wrap ─────────────────────────────────────

@test "ui_pad_left: alinha à direita e nunca corta o que já é maior" {
  [ "$(ui_pad_left "7" 3)" = "  7" ]
  [ "$(ui_pad_left "120" 3)" = "120" ]
  [ "$(ui_pad_left "12345" 3)" = "12345" ]
}

@test "ui_strip_ansi: remove escapes sem fork e preserva o texto" {
  local colored
  colored="$(printf '\033[1;33maviso\033[0m final')"
  [ "$(ui_strip_ansi "$colored")" = "aviso final" ]
  [ "$(ui_strip_ansi "sem cor")" = "sem cor" ]
}

@test "ui_wrap: devolve intacta a linha que cabe na largura" {
  [ "$(ui_wrap "curta" 40)" = "curta" ]
}

@test "ui_wrap: quebra em espaços repetindo a indentação inicial" {
  run ui_wrap "  alfa beta gama delta" 12
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  alfa beta" ]
  [ "${lines[1]}" = "  gama delta" ]
}

@test "ui_wrap: token maior que a largura sai inteiro em vez de cortado" {
  local url="https://example.com/um/caminho/absurdamente/longo/que/nao/cabe"
  run ui_wrap "  veja $url agora" 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"$url"* ]]
}

@test "ui_wrap: mede largura de exibição, ignorando escapes ANSI" {
  local colored
  colored="$(printf '  \033[33malfa beta\033[0m')"
  # 11 colunas de exibição ("  alfa beta") cabem em 12, apesar de a string crua
  # ser bem maior por causa dos escapes.
  run ui_wrap "$colored" 12
  [ "${#lines[@]}" -eq 1 ]
}
