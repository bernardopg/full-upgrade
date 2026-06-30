#!/usr/bin/env bats
# tests/cli.bats — parse_args e apply_mode_and_early_exits (lib/cli.sh)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/cli.sh"
}

reset_flags() {
  ASSUME_YES=0; DEVEL_UPDATE=0; DRY_RUN=0; VERBOSE=0; QUIET=0
  NO_REPAIR=0; NO_CLEANUP=0; RESTART_SERVICES=0; LIST_STEPS=0
  JSON_SUMMARY=0; ONLY_CATEGORY=""; EXPLAIN_STEP=""; MODE=""
  SHOW_VERSION=0; SHOW_CONFIG=0; DO_SELF_UPDATE=0; DO_REPORT=0
  REPORT_FILE=""; REPORT_FROM=""; FAIL_FAST=0; DO_HISTORY=0
  HISTORY_N=10; DO_AUDIT=0; DO_RESUME=0; RESUME_STEPS=""
  TRAY_MODE=""; TRAY_LAUNCH=0; TRAY_VIEW_LOG=0; TRAY_LAUNCH_ARGS=()
  FULL_UPGRADE_SKIP=""
}

# ── usage ──────────────────────────────────────────────────────────────────────

@test "usage: contém texto de ajuda essencial" {
  run usage
  [ "$status" -eq 0 ]
  [[ "$output" == *"--mode"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--skip"* ]]
  [[ "$output" == *"--only"* ]]
}

# ── parse_args: flags booleanas ────────────────────────────────────────────────

@test "parse_args: --yes seta ASSUME_YES" {
  reset_flags
  parse_args --yes
  [ "$ASSUME_YES" -eq 1 ]
}

@test "parse_args: -y seta ASSUME_YES" {
  reset_flags
  parse_args -y
  [ "$ASSUME_YES" -eq 1 ]
}

@test "parse_args: --devel seta DEVEL_UPDATE" {
  reset_flags
  parse_args --devel
  [ "$DEVEL_UPDATE" -eq 1 ]
}

@test "parse_args: --dry-run seta DRY_RUN" {
  reset_flags
  parse_args --dry-run
  [ "$DRY_RUN" -eq 1 ]
}

@test "parse_args: -n seta DRY_RUN" {
  reset_flags
  parse_args -n
  [ "$DRY_RUN" -eq 1 ]
}

@test "parse_args: --quiet seta QUIET" {
  reset_flags
  parse_args --quiet
  [ "$QUIET" -eq 1 ]
}

@test "parse_args: --verbose seta VERBOSE" {
  reset_flags
  parse_args --verbose
  [ "$VERBOSE" -eq 1 ]
}

@test "parse_args: --no-repair seta NO_REPAIR" {
  reset_flags
  parse_args --no-repair
  [ "$NO_REPAIR" -eq 1 ]
}

@test "parse_args: --no-cleanup seta NO_CLEANUP" {
  reset_flags
  parse_args --no-cleanup
  [ "$NO_CLEANUP" -eq 1 ]
}

@test "parse_args: --restart-services seta RESTART_SERVICES" {
  reset_flags
  parse_args --restart-services
  [ "$RESTART_SERVICES" -eq 1 ]
}

@test "parse_args: --json seta JSON_SUMMARY" {
  reset_flags
  parse_args --json
  [ "$JSON_SUMMARY" -eq 1 ]
}

@test "parse_args: --list-steps seta LIST_STEPS" {
  reset_flags
  parse_args --list-steps
  [ "$LIST_STEPS" -eq 1 ]
}

@test "parse_args: --audit seta DO_AUDIT" {
  reset_flags
  parse_args --audit
  [ "$DO_AUDIT" -eq 1 ]
}

@test "parse_args: --resume seta DO_RESUME" {
  reset_flags
  parse_args --resume
  [ "$DO_RESUME" -eq 1 ]
}

@test "parse_args: --fail-fast seta FAIL_FAST" {
  reset_flags
  parse_args --fail-fast
  [ "$FAIL_FAST" -eq 1 ]
}

@test "parse_args: --continue-on-fail reseta FAIL_FAST" {
  reset_flags
  FAIL_FAST=1
  parse_args --continue-on-fail
  [ "$FAIL_FAST" -eq 0 ]
}

@test "parse_args: --version seta SHOW_VERSION" {
  reset_flags
  parse_args --version
  [ "$SHOW_VERSION" -eq 1 ]
}

@test "parse_args: -V seta SHOW_VERSION" {
  reset_flags
  parse_args -V
  [ "$SHOW_VERSION" -eq 1 ]
}

@test "parse_args: --update seta DO_SELF_UPDATE" {
  reset_flags
  parse_args --update
  [ "$DO_SELF_UPDATE" -eq 1 ]
}

@test "parse_args: -u seta DO_SELF_UPDATE" {
  reset_flags
  parse_args -u
  [ "$DO_SELF_UPDATE" -eq 1 ]
}

# ── parse_args: --mode ─────────────────────────────────────────────────────────

@test "parse_args: --mode update" {
  reset_flags
  parse_args --mode update
  [ "$MODE" = "update" ]
}

@test "parse_args: --mode doctor" {
  reset_flags
  parse_args --mode doctor
  [ "$MODE" = "doctor" ]
}

@test "parse_args: --mode repair" {
  reset_flags
  parse_args --mode repair
  [ "$MODE" = "repair" ]
}

@test "parse_args: --mode full" {
  reset_flags
  parse_args --mode full
  [ "$MODE" = "full" ]
}

@test "parse_args: --mode=update (inline)" {
  reset_flags
  parse_args --mode=update
  [ "$MODE" = "update" ]
}

@test "parse_args: --mode=doctor (inline)" {
  reset_flags
  parse_args --mode=doctor
  [ "$MODE" = "doctor" ]
}

@test "parse_args: --doctor seta MODE=doctor" {
  reset_flags
  parse_args --doctor
  [ "$MODE" = "doctor" ]
}

@test "parse_args: --mode vazio causa exit 2" {
  reset_flags
  run parse_args --mode
  [ "$status" -eq 2 ]
  [[ "$output" == *"requer um valor"* ]]
}

@test "parse_args: --mode inválido causa exit 2" {
  reset_flags
  run parse_args --mode banana
  [ "$status" -eq 2 ]
  [[ "$output" == *"Modo inválido"* ]]
}

@test "parse_args: --modeX (colado) cai em opção inválida" {
  reset_flags
  run parse_args --modeX
  [ "$status" -eq 2 ]
  [[ "$output" == *"Opção inválida"* ]]
}

# ── parse_args: --skip ─────────────────────────────────────────────────────────

@test "parse_args: --skip adiciona step ao FULL_UPGRADE_SKIP" {
  reset_flags
  parse_args --skip "Atualizar Ollama"
  [[ "$FULL_UPGRADE_SKIP" == *"Atualizar Ollama"* ]]
}

@test "parse_args: --skip=X (inline)" {
  reset_flags
  parse_args --skip="Atualizar npm global"
  [[ "$FULL_UPGRADE_SKIP" == *"Atualizar npm global"* ]]
}

@test "parse_args: --skip múltiplos acumulam" {
  reset_flags
  parse_args --skip "Step A" --skip "Step B"
  [[ "$FULL_UPGRADE_SKIP" == *"Step A"* ]]
  [[ "$FULL_UPGRADE_SKIP" == *"Step B"* ]]
}

@test "parse_args: --skip sem argumento causa exit 2" {
  reset_flags
  run parse_args --skip
  [ "$status" -eq 2 ]
  [[ "$output" == *"requer o nome"* ]]
}

@test "parse_args: --skip com flag como argumento causa exit 2" {
  reset_flags
  run parse_args --skip --dry-run
  [ "$status" -eq 2 ]
}

# ── parse_args: --skip-category ────────────────────────────────────────────────

@test "parse_args: --skip-category doctor funciona" {
  reset_flags
  parse_args --skip-category doctor
  [[ "$FULL_UPGRADE_SKIP" == *"Doctor:"* ]]
}

@test "parse_args: --skip-category=repair (inline)" {
  reset_flags
  parse_args --skip-category=repair
  [[ "$FULL_UPGRADE_SKIP" == *"Reparar"* ]]
}

@test "parse_args: --skip-category inválido causa exit 2" {
  reset_flags
  run parse_args --skip-category nonexistentcat
  [ "$status" -eq 2 ]
  [[ "$output" == *"desconhecida"* ]]
}

@test "parse_args: --skip-category sem argumento causa exit 2" {
  reset_flags
  run parse_args --skip-category
  [ "$status" -eq 2 ]
}

# ── parse_args: --only ─────────────────────────────────────────────────────────

@test "parse_args: --only doctor seta MODE=doctor" {
  reset_flags
  parse_args --only doctor
  [ "$MODE" = "doctor" ]
}

@test "parse_args: --only com categoria seta ONLY_CATEGORY" {
  reset_flags
  parse_args --only lang
  [ "$ONLY_CATEGORY" = "lang" ]
}

@test "parse_args: --only=doctor (inline) seta MODE" {
  reset_flags
  parse_args --only=doctor
  [ "$MODE" = "doctor" ]
}

@test "parse_args: --only=lang (inline) seta ONLY_CATEGORY" {
  reset_flags
  parse_args --only=lang
  [ "$ONLY_CATEGORY" = "lang" ]
}

@test "parse_args: --only sem argumento causa exit 2" {
  reset_flags
  run parse_args --only
  [ "$status" -eq 2 ]
}

# ── parse_args: --report ───────────────────────────────────────────────────────

@test "parse_args: --report seta DO_REPORT sem arquivo" {
  reset_flags
  parse_args --report
  [ "$DO_REPORT" -eq 1 ]
  [ -z "$REPORT_FILE" ]
}

@test "parse_args: --report com arquivo" {
  reset_flags
  parse_args --report /tmp/my-report.md
  [ "$DO_REPORT" -eq 1 ]
  [ "$REPORT_FILE" = "/tmp/my-report.md" ]
}

@test "parse_args: --report=arquivo (inline)" {
  reset_flags
  parse_args --report=/tmp/out.md
  [ "$DO_REPORT" -eq 1 ]
  [ "$REPORT_FILE" = "/tmp/out.md" ]
}

# ── parse_args: --from ─────────────────────────────────────────────────────────

@test "parse_args: --from com run_id" {
  reset_flags
  parse_args --from 20260613-142301
  [ "$REPORT_FROM" = "20260613-142301" ]
}

@test "parse_args: --from=run_id (inline)" {
  reset_flags
  parse_args --from=abc123
  [ "$REPORT_FROM" = "abc123" ]
}

@test "parse_args: --from sem argumento causa exit 2" {
  reset_flags
  run parse_args --from
  [ "$status" -eq 2 ]
}

# ── parse_args: --history ──────────────────────────────────────────────────────

@test "parse_args: --history sem número usa default 10" {
  reset_flags
  parse_args --history
  [ "$DO_HISTORY" -eq 1 ]
  [ "$HISTORY_N" -eq 10 ]
}

@test "parse_args: --history 5" {
  reset_flags
  parse_args --history 5
  [ "$DO_HISTORY" -eq 1 ]
  [ "$HISTORY_N" -eq 5 ]
}

@test "parse_args: --history=8 (inline)" {
  reset_flags
  parse_args --history=8
  [ "$DO_HISTORY" -eq 1 ]
  [ "$HISTORY_N" -eq 8 ]
}

# ── parse_args: --explain-step ─────────────────────────────────────────────────

@test "parse_args: --explain-step com nome" {
  reset_flags
  parse_args --explain-step "Doctor: reboot pendente"
  [ "$EXPLAIN_STEP" = "Doctor: reboot pendente" ]
}

@test "parse_args: --explain-step=nome (inline)" {
  reset_flags
  parse_args --explain-step="Doctor: saúde de disco"
  [ "$EXPLAIN_STEP" = "Doctor: saúde de disco" ]
}

@test "parse_args: --explain-step sem argumento causa exit 2" {
  reset_flags
  run parse_args --explain-step
  [ "$status" -eq 2 ]
}

# ── parse_args: --config ───────────────────────────────────────────────────────

@test "parse_args: --config seta SHOW_CONFIG=1" {
  reset_flags
  parse_args --config
  [ "$SHOW_CONFIG" -eq 1 ]
}

@test "parse_args: -c seta SHOW_CONFIG=1" {
  reset_flags
  parse_args -c
  [ "$SHOW_CONFIG" -eq 1 ]
}

@test "parse_args: --config-example seta SHOW_CONFIG=2" {
  reset_flags
  parse_args --config-example
  [ "$SHOW_CONFIG" -eq 2 ]
}

# ── parse_args: --tray ─────────────────────────────────────────────────────────

@test "parse_args: --tray sem subcmd seta TRAY_MODE=start" {
  reset_flags
  parse_args --tray
  [ "$TRAY_MODE" = "start" ]
}

@test "parse_args: --tray --enable seta TRAY_MODE=enable" {
  reset_flags
  parse_args --tray --enable
  [ "$TRAY_MODE" = "enable" ]
}

@test "parse_args: --tray --disable seta TRAY_MODE=disable" {
  reset_flags
  parse_args --tray --disable
  [ "$TRAY_MODE" = "disable" ]
}

@test "parse_args: --tray --status seta TRAY_MODE=status" {
  reset_flags
  parse_args --tray --status
  [ "$TRAY_MODE" = "status" ]
}

@test "parse_args: --tray --check seta TRAY_MODE=check" {
  reset_flags
  parse_args --tray --check
  [ "$TRAY_MODE" = "check" ]
}

@test "parse_args: --tray --restart seta TRAY_MODE=restart" {
  reset_flags
  parse_args --tray --restart
  [ "$TRAY_MODE" = "restart" ]
}

@test "parse_args: --tray-enable (atalho)" {
  reset_flags
  parse_args --tray-enable
  [ "$TRAY_MODE" = "enable" ]
}

@test "parse_args: --tray-disable (atalho)" {
  reset_flags
  parse_args --tray-disable
  [ "$TRAY_MODE" = "disable" ]
}

@test "parse_args: --tray-status (atalho)" {
  reset_flags
  parse_args --tray-status
  [ "$TRAY_MODE" = "status" ]
}

@test "parse_args: --tray-check (atalho)" {
  reset_flags
  parse_args --tray-check
  [ "$TRAY_MODE" = "check" ]
}

@test "parse_args: --tray-view-log seta TRAY_VIEW_LOG" {
  reset_flags
  parse_args --tray-view-log
  [ "$TRAY_VIEW_LOG" -eq 1 ]
}

@test "parse_args: --tray-launch captura args e faz break" {
  reset_flags
  parse_args --tray-launch --mode doctor -- --yes
  [ "$TRAY_LAUNCH" -eq 1 ]
  [ "${TRAY_LAUNCH_ARGS[0]}" = "--mode" ]
  [ "${TRAY_LAUNCH_ARGS[1]}" = "doctor" ]
  [ "${TRAY_LAUNCH_ARGS[2]}" = "--" ]
  [ "${TRAY_LAUNCH_ARGS[3]}" = "--yes" ]
}

# ── parse_args: combinações ────────────────────────────────────────────────────

@test "parse_args: múltiplas flags combinadas" {
  reset_flags
  parse_args --yes --dry-run --verbose --mode update
  [ "$ASSUME_YES" -eq 1 ]
  [ "$DRY_RUN" -eq 1 ]
  [ "$VERBOSE" -eq 1 ]
  [ "$MODE" = "update" ]
}

@test "parse_args: opção inválida causa exit 2" {
  reset_flags
  run parse_args --invalid-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"Opção inválida"* ]]
}

# ── apply_mode_and_early_exits: --version ──────────────────────────────────────

@test "apply_mode_and_early_exits: --version imprime versão e sai" {
  SCRIPT_VERSION="3.19.0"
  reset_flags
  SHOW_VERSION=1
  run apply_mode_and_early_exits
  [ "$status" -eq 0 ]
  [ "$output" = "3.19.0" ]
}

# ── apply_mode_and_early_exits: --list-steps ───────────────────────────────────

@test "apply_mode_and_early_exits: --list-steps imprime catálogo e sai" {
  reset_flags
  LIST_STEPS=1
  run apply_mode_and_early_exits
  [ "$status" -eq 0 ]
  [[ "$output" == *"STEP"* ]]
  [[ "$output" == *"CATEGORIA"* ]]
}

# ── apply_mode_and_early_exits: --config ───────────────────────────────────────

@test "apply_mode_and_early_exits: --config-example imprime e sai" {
  reset_flags
  SHOW_CONFIG=2
  run apply_mode_and_early_exits
  [ "$status" -eq 0 ]
  [[ "$output" == *"config"* ]] || [[ "$output" == *"Config"* ]]
}

@test "apply_mode_and_early_exits: --config (1) imprime e sai" {
  reset_flags
  SHOW_CONFIG=1
  run apply_mode_and_early_exits
  [ "$status" -eq 0 ]
}
