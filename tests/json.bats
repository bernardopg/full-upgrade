#!/usr/bin/env bats
# tests/json.bats — escape JSON (lib/json.sh). Funções puras, sem mutação.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/json.sh"
}

@test "json_escape: string simples vira JSON válido" {
  run json_escape 'texto simples'
  [ "$status" -eq 0 ]
  [ "$output" = '"texto simples"' ]
}

@test "json_escape: aspas e backslash escapados" {
  result="$(json_escape 'a"b\c')"
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: newline, tab e CR escapados como sequências" {
  result="$(json_escape "$(printf 'l1\nl2\tcol\r')")"
  [[ "$result" == *'\n'* ]]
  [[ "$result" == *'\t'* ]]
  [[ "$result" == *'\r'* ]]
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: ESC ANSI (0x1b) não invalida o JSON" {
  # Regressão #18: reason com cor ANSI quebrava a linha do JSONL.
  result="$(json_escape "$(printf 'a\033[31mvermelho\033[0mb')")"
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: control chars diversos são removidos" {
  result="$(json_escape "$(printf 'a\001b\002c\037d')")"
  [ "$result" = '"abcd"' ]
  printf '{"v":%s}' "$result" | jq -e . >/dev/null
}

@test "json_escape: UTF-8 multibyte passa intacto" {
  run json_escape 'ação ✔ ⚠ não'
  [ "$output" = '"ação ✔ ⚠ não"' ]
}

# ── run_id_from_artifact / rotate_logs ────────────────────────────────────────

@test "run_id_from_artifact: extrai o RUN_ID de qualquer artefato de run" {
  [ "$(run_id_from_artifact 'full-upgrade-20260724-212309-1640415.log')" = "20260724-212309-1640415" ]
  [ "$(run_id_from_artifact '/tmp/x/hermes-update-20260724-212309-1640415.log')" = "20260724-212309-1640415" ]
  [ "$(run_id_from_artifact 'full-upgrade-20260724-212309-1640415.aur-out-of-date')" = "20260724-212309-1640415" ]
}

@test "run_id_from_artifact: arquivo que não é de run não devolve RUN_ID" {
  run run_id_from_artifact 'arch-news-last'
  [ "$status" -ne 0 ]
  run run_id_from_artifact 'timeshift-backlog-cleanup-20260712.log'
  [ "$status" -ne 0 ]
}

@test "rotate_logs: mantém os MAX_LOGS runs mais novos e apaga os antigos por inteiro" {
  LOG_DIR="$(mktemp -d)"
  MAX_LOGS=2
  RUN_ID="20260103-100000-3"

  local r
  for r in 20260101-100000-1 20260102-100000-2 20260103-100000-3; do
    : > "${LOG_DIR}/full-upgrade-${r}.log"
    : > "${LOG_DIR}/full-upgrade-${r}.jsonl"
    : > "${LOG_DIR}/full-upgrade-${r}.md"
    # artefatos que a rotação por extensão deixava vazar
    : > "${LOG_DIR}/full-upgrade-${r}.aur-out-of-date"
    : > "${LOG_DIR}/hermes-update-${r}.log"
  done
  : > "${LOG_DIR}/arch-news-last"

  rotate_logs

  # Run mais antigo some inteiro, inclusive os artefatos fora do padrão.
  [ ! -e "${LOG_DIR}/full-upgrade-20260101-100000-1.log" ]
  [ ! -e "${LOG_DIR}/full-upgrade-20260101-100000-1.aur-out-of-date" ]
  [ ! -e "${LOG_DIR}/hermes-update-20260101-100000-1.log" ]
  # Os 2 mais novos ficam inteiros.
  [ -e "${LOG_DIR}/full-upgrade-20260102-100000-2.jsonl" ]
  [ -e "${LOG_DIR}/hermes-update-20260103-100000-3.log" ]
  # Arquivo que não pertence a run nenhum não é tocado.
  [ -e "${LOG_DIR}/arch-news-last" ]
}

@test "rotate_logs: nunca apaga os artefatos do run em andamento" {
  LOG_DIR="$(mktemp -d)"
  MAX_LOGS=1
  # RUN_ID propositalmente o MAIS ANTIGO: mesmo assim tem de sobreviver.
  RUN_ID="20260101-100000-1"
  local r
  for r in 20260101-100000-1 20260102-100000-2 20260103-100000-3; do
    : > "${LOG_DIR}/full-upgrade-${r}.log"
  done

  rotate_logs
  [ -e "${LOG_DIR}/full-upgrade-20260101-100000-1.log" ]
}

@test "rotate_logs: abaixo do limite não remove nada" {
  LOG_DIR="$(mktemp -d)"
  MAX_LOGS=20
  RUN_ID="20260101-100000-1"
  : > "${LOG_DIR}/full-upgrade-20260101-100000-1.log"
  rotate_logs
  [ -e "${LOG_DIR}/full-upgrade-20260101-100000-1.log" ]
}

# ── pkg_diff_json ─────────────────────────────────────────────────────────────

@test "pkg_diff_json: serializa upgrade, install e remove" {
  local diff
  diff="$(printf 'U chromium 150.0-1 151.0-1\nI novo 1.0-1\nR velho 9.9-1\n')"
  run pkg_diff_json "$diff"
  [ "$status" -eq 0 ]
  [[ "$output" == '[{"action":"upgraded","name":"chromium","from":"150.0-1","to":"151.0-1"},{"action":"installed","name":"novo","version":"1.0-1"},{"action":"removed","name":"velho","version":"9.9-1"}]' ]]
}

@test "pkg_diff_json: diff vazio vira array vazio" {
  run pkg_diff_json ""
  [ "$output" = "[]" ]
}

# ── jsonl_is_dry_run ──────────────────────────────────────────────────────────

@test "jsonl_is_dry_run: reconhece dry-run e run real pelo run_start" {
  local d; d="$(mktemp -d)"
  printf '%s\n' '{"event":"run_start","run_id":"a","dry_run":true}' > "$d/dry.jsonl"
  printf '%s\n' '{"event":"run_start","run_id":"b","dry_run":false}' > "$d/real.jsonl"
  run jsonl_is_dry_run "$d/dry.jsonl";  [ "$status" -eq 0 ]
  run jsonl_is_dry_run "$d/real.jsonl"; [ "$status" -ne 0 ]
  run jsonl_is_dry_run "$d/nao-existe"; [ "$status" -ne 0 ]
}
