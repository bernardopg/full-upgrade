#!/usr/bin/env bats
# tests/core.bats — helpers puros de lib/core.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
}

# ── elapsed ───────────────────────────────────────────────────────────────────

@test "elapsed: segundos abaixo de 1 minuto" {
  run elapsed 5
  [ "$status" -eq 0 ]
  [ "$output" = "5s" ]
}

@test "elapsed: exatamente 60s vira 1m 00s" {
  run elapsed 60
  [ "$output" = "1m 00s" ]
}

@test "elapsed: minutos e segundos com zero-pad" {
  run elapsed 90
  [ "$output" = "1m 30s" ]
}

@test "elapsed: zero segundos" {
  run elapsed 0
  [ "$output" = "0s" ]
}

# ── _strip_ansi ───────────────────────────────────────────────────────────────

@test "_strip_ansi: remove códigos de cor preservando texto" {
  result="$(printf '\033[1;32mverde\033[0m normal\n' | _strip_ansi)"
  [ "$result" = "verde normal" ]
}

@test "_strip_ansi: texto sem ANSI passa intacto" {
  result="$(printf 'sem cor aqui\n' | _strip_ansi)"
  [ "$result" = "sem cor aqui" ]
}

# ── has ───────────────────────────────────────────────────────────────────────

@test "has: comando existente retorna 0" {
  run has bash
  [ "$status" -eq 0 ]
}

@test "has: comando inexistente retorna não-zero" {
  run has __comando_que_nao_existe_xyz__
  [ "$status" -ne 0 ]
}

# ── add_skip_step / skip_step_count ───────────────────────────────────────────

@test "skip_step_count: lista vazia é 0" {
  FULL_UPGRADE_SKIP=""
  run skip_step_count
  [ "$output" = "0" ]
}

@test "add_skip_step + skip_step_count: dois itens contam 2" {
  FULL_UPGRADE_SKIP=""
  add_skip_step "Step A"
  add_skip_step "Step B"
  run skip_step_count
  [ "$output" = "2" ]
}

@test "skip_step_count: ignora espaços em branco entre vírgulas" {
  FULL_UPGRADE_SKIP="A ,  B , C"
  run skip_step_count
  [ "$output" = "3" ]
}

# ── _step_skip_requested ──────────────────────────────────────────────────────

@test "_step_skip_requested: nome presente retorna 0" {
  FULL_UPGRADE_SKIP="Validar sudo,Atualizar mirrors"
  run _step_skip_requested "Atualizar mirrors"
  [ "$status" -eq 0 ]
}

@test "_step_skip_requested: respeita trim de espaços ao redor do nome" {
  FULL_UPGRADE_SKIP="  Validar sudo  ,  Atualizar mirrors  "
  run _step_skip_requested "Validar sudo"
  [ "$status" -eq 0 ]
}

@test "_step_skip_requested: nome ausente retorna não-zero" {
  FULL_UPGRADE_SKIP="Validar sudo"
  run _step_skip_requested "Step inexistente"
  [ "$status" -ne 0 ]
}

@test "_step_skip_requested: não casa substring parcial" {
  FULL_UPGRADE_SKIP="Atualizar mirrors"
  run _step_skip_requested "Atualizar"
  [ "$status" -ne 0 ]
}

# ── aur_ignore_args ───────────────────────────────────────────────────────────

@test "aur_ignore_args: lista vazia não produz saída" {
  FULL_UPGRADE_AUR_IGNORE=""
  run aur_ignore_args
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "aur_ignore_args: cada pacote vira --ignore=<pkg>" {
  FULL_UPGRADE_AUR_IGNORE="foo bar"
  run aur_ignore_args
  [ "${lines[0]}" = "--ignore=foo" ]
  [ "${lines[1]}" = "--ignore=bar" ]
}
