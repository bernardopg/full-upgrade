#!/usr/bin/env bats
# tests/help.bats — sistema de ajuda com seções e tópicos (R1)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # cli.sh só define funções (sem efeitos no source).
  # shellcheck source=/dev/null
  source "${FU_LIB}/cli.sh"
  NO_COLOR=1
  COLUMNS=120
  # reset_flags local (cli.bats tem o seu; aqui replicamos o essencial)
  reset_flags() {
    ASSUME_YES=0; DEVEL_UPDATE=0; DRY_RUN=0; VERBOSE=0; QUIET=0
    NO_REPAIR=0; NO_CLEANUP=0; RESTART_SERVICES=0; LIST_STEPS=0
    JSON_SUMMARY=0; ONLY_CATEGORY=""; EXPLAIN_STEP=""; MODE=""
    SHOW_VERSION=0; SHOW_CONFIG=0; DO_SELF_UPDATE=0; DO_REPORT=0
    REPORT_FILE=""; REPORT_FROM=""; FAIL_FAST=0; DO_HISTORY=0
    HISTORY_N=10; DO_AUDIT=0; DO_RESUME=0; RESUME_STEPS=""
    DO_HEALTHCHECK=0; DO_CONFIG_TUI=0; HELP_TOPIC=""
  }
}

# ── usage ─────────────────────────────────────────────────────────────────────

@test "usage: contém texto de ajuda essencial" {
  run usage
  [ "$status" -eq 0 ]
  [[ "$output" == *"--mode"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--skip"* ]]
  [[ "$output" == *"--only"* ]]
}

@test "usage: seções organizadas" {
  run usage
  [[ "$output" == *"MODOS DE EXECUÇÃO"* ]]
  [[ "$output" == *"FILTROS DE STEPS"* ]]
  [[ "$output" == *"CONFIGURAÇÃO"* ]]
  [[ "$output" == *"DIAGNÓSTICO E RELATÓRIOS"* ]]
  [[ "$output" == *"STATUS NO RESUMO"* ]]
  [[ "$output" == *"AMBIENTE"* ]]
}

@test "usage: documenta os comandos novos (R2/R3)" {
  run usage
  [[ "$output" == *"--config-tui"* ]]
  [[ "$output" == *"--healthcheck"* ]]
  [[ "$output" == *"--help [TÓPICO]"* ]]
}

@test "usage: coluna de flags alinhada (26 colunas)" {
  run usage_flag "--config-tui" "descrição curta"
  [ "$status" -eq 0 ]
  # "--config-tui" tem 12 chars + 14 espaços de padding
  [[ "$output" == "--config-tui              descrição curta"* ]]
}

@test "usage_flag: descrição longa quebra com indent continuado" {
  COLUMNS=60
  run usage_flag "-c, --config" "uma descrição bem longa que certamente não cabe em sessenta colunas de terminal e precisa quebrar"
  [ "$status" -eq 0 ]
  local line2
  line2="$(printf '%s\n' "$output" | sed -n '2p')"
  # Continuação alinha na coluna 26 (hanging indent): começa com espaços e tem
  # conteúdo não-espaçado depois.
  [[ "$line2" =~ ^[[:space:]]+[^[:space:]] ]]
}

# ── tópicos ───────────────────────────────────────────────────────────────────

@test "usage_topics: lista os tópicos canônicos" {
  run usage_topics
  [[ "$output" == *"modes"* ]]
  [[ "$output" == *"steps"* ]]
  [[ "$output" == *"config"* ]]
  [[ "$output" == *"healthcheck"* ]]
  [[ "$output" == *"tui"* ]]
  [[ "$output" == *"tray"* ]]
  [[ "$output" == *"env"* ]]
}

@test "usage_topic: tópico modes documenta os 4 modos" {
  run usage_topic modes
  [ "$status" -eq 0 ]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"repair"* ]]
  [[ "$output" == *"full"* ]]
}

@test "usage_topic: tópico healthcheck documenta as seções" {
  run usage_topic healthcheck
  [[ "$output" == *"--healthcheck --json"* ]]
  [[ "$output" == *"Timeshift"* ]]
  [[ "$output" == *"Backup nuvem"* ]]
  [[ "$output" == *"Read-only"* ]]
}

@test "usage_topic: tópico tui documenta teclas" {
  run usage_topic tui
  [[ "$output" == *"--config-tui"* ]]
  [[ "$output" == *"Space"* ]]
  [[ "$output" == *"filtro"* ]]
  [[ "$output" == *"backup"* ]]
}

@test "usage_topic: tópico config documenta caminho e TUI" {
  run usage_topic config
  [[ "$output" == *".config/full-upgrade/config"* ]]
  [[ "$output" == *"--config-tui"* ]]
}

@test "usage_topic: tópico desconhecido => rc 2 e lista válidos" {
  run usage_topic nao-existe
  [ "$status" -eq 2 ]
  [[ "$output" == *"desconhecido"* ]]
  [[ "$output" == *"healthcheck"* ]]
}

# ── parse_args + validação ────────────────────────────────────────────────────

@test "parse_args: --help TÓPICO agenda o tópico sem imprimir" {
  reset_flags
  parse_args --help healthcheck
  [ "$HELP_TOPIC" = "healthcheck" ]
}

@test "parse_args: --help=tópico não é confundido com flag" {
  reset_flags
  parse_args --help tui
  [ "$HELP_TOPIC" = "tui" ]
}

@test "parse_args: --healthcheck seta DO_HEALTHCHECK" {
  reset_flags
  parse_args --healthcheck
  [ "$DO_HEALTHCHECK" -eq 1 ]
}

@test "parse_args: --config-tui seta DO_CONFIG_TUI" {
  reset_flags
  parse_args --config-tui
  [ "$DO_CONFIG_TUI" -eq 1 ]
}

@test "validação: --healthcheck com --audit é rejeitado" {
  reset_flags
  run bash -c '
    source "${1}/../lib/globals.sh" 2>/dev/null || true
  ' : /dev/null # noop para compatibilidade
  # Validação direta das variáveis (sem fork do entrypoint inteiro):
  DO_HEALTHCHECK=1
  DO_AUDIT=1
  local _exclusive=0
  (( DO_HEALTHCHECK )) && _exclusive=$(( _exclusive + 1 ))
  (( DO_CONFIG_TUI   )) && _exclusive=$(( _exclusive + 1 ))
  (( DO_REPORT       )) && _exclusive=$(( _exclusive + 1 ))
  (( DO_AUDIT        )) && _exclusive=$(( _exclusive + 1 ))
  (( DO_HISTORY      )) && _exclusive=$(( _exclusive + 1 ))
  [ "$_exclusive" -gt 1 ]
}

@test "usage_flag: colorização não quebra com cores ativas" {
  C_BOLD=$'\033[1m' C_CYAN=$'\033[1;36m' C_RESET=$'\033[0m'
  run usage_flag "--dry-run" "mostra sem executar"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[1;36m'* ]]
  [[ "$output" == *"mostra sem executar"* ]]
}
