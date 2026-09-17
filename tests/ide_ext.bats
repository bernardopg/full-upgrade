#!/usr/bin/env bats
# tests/ide_ext.bats — atualização de extensões de IDE VSCode-family (H3).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ide.sh"
  QUIET=0
  STEP_REASON=""
  IDE_EXT_CLIS=""
}

# ── helper puro count_ext_updates ─────────────────────────────────────────────

@test "count: conta linhas 'successfully updated'" {
  out="$(printf '%s\n' \
    "Updating extensions: a.b, c.d" \
    "Extension 'a.b' v1 was successfully updated." \
    "Extension 'c.d' v2 was successfully updated." \
    | count_ext_updates)"
  [ "$out" -eq 2 ]
}

@test "count: zero quando nada atualizou" {
  out="$(printf 'No extensions to update.\n' | count_ext_updates)"
  [ "$out" -eq 0 ]
}

# ── seleção de CLIs ───────────────────────────────────────────────────────────

@test "clis: IDE_EXT_CLIS sobrescreve a lista padrão" {
  IDE_EXT_CLIS="code cursor"
  out="$(_ide_ext_clis | tr '\n' ' ')"
  [ "$out" = "code cursor " ]
}

@test "clis: default inclui code e cursor" {
  out="$(_ide_ext_clis)"
  [[ "$out" == *code* ]]
  [[ "$out" == *cursor* ]]
}

# ── máquina de estados update_ide_extensions ──────────────────────────────────

@test "step: nenhum IDE presente retorna 0" {
  has() { return 1; }
  run update_ide_extensions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum IDE"* ]]
}

@test "step: atualiza e soma extensões de um CLI" {
  IDE_EXT_CLIS="code"
  has() { [[ "$1" == code ]]; }
  # stub do run_network_cmd: emite saída de sucesso com 2 updates, rc 0
  run_network_cmd() {
    printf "%s\n" "Extension 'a.b' v1 was successfully updated." \
                  "Extension 'c.d' v2 was successfully updated."
    return 0
  }
  run update_ide_extensions
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 extensão"* ]]
  [[ "$output" == *"Total de extensões atualizadas: 2"* ]]
}

@test "step: retry Node sem auto-seleção de família recupera timeout IPv6" {
  local calls_file="$BATS_TEST_TMPDIR/ide-network-calls"
  : > "$calls_file"
  IDE_EXT_CLIS="code"
  has() { [[ "$1" == code ]]; }
  run_network_cmd() {
    local calls
    calls="$(wc -l < "$calls_file")"
    printf '%s\n' x >> "$calls_file"
    if (( calls == 0 )); then
      printf 'AggregateError [ETIMEDOUT]\n'
      return "$RC_WARN"
    fi
    [[ "${NODE_OPTIONS:-}" == *"--no-network-family-autoselection"* ]]
    printf "Extension 'a.b' v1 was successfully updated.\n"
  }

  run update_ide_extensions

  [ "$status" -eq 0 ]
  [[ "$output" == *"Total de extensões atualizadas: 1"* ]]
  [ "$(wc -l < "$calls_file")" -eq 2 ]
}

@test "step: falha de rede num CLI vira RC_WARN" {
  IDE_EXT_CLIS="code"
  has() { [[ "$1" == code ]]; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run update_ide_extensions
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha de rede"* ]]
}

@test "step: 503 do marketplace (Server returned 503, rc=1) vira warn com motivo próprio" {
  IDE_EXT_CLIS="code"
  IDE_EXT_RETRY_DELAY_S=0
  has() { [[ "$1" == code ]]; }
  STEP_REASON=""
  # run_node_network_cmd real repassa rc/out do run_network_cmd; aqui o stub
  # simula o VSCode/Code-OSS contra open-vsx fora do ar (run real 2026-09-17).
  # NOTE: `run` isola em subshell — STEP_REASON não sobrevive; o motivo vai
  # para o log via `log`, então checamos $output e não a variável.
  run_node_network_cmd() { printf 'Server returned 503\n'; return 1; }
  run update_ide_extensions
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"marketplace indisponível"* ]]
}

@test "step: 5xx do marketplace tem retry e fecha ok quando uma tentativa passa" {
  # Medição real de 2026-09-17: o endpoint de batch do open-vsx alterna 200/503
  # sem relação com a rede local, então a primeira tentativa falhar não pode
  # fechar o step em warn.
  local calls_file="$BATS_TEST_TMPDIR/marketplace-calls"
  : > "$calls_file"
  IDE_EXT_CLIS="code"
  IDE_EXT_MAX_ATTEMPTS=3
  IDE_EXT_RETRY_DELAY_S=0
  has() { [[ "$1" == code ]]; }
  run_node_network_cmd() {
    local calls
    calls="$(wc -l < "$calls_file")"
    printf '%s\n' x >> "$calls_file"
    if (( calls == 0 )); then
      printf 'Server returned 503\n'
      return "$RC_WARN"
    fi
    printf "Extension 'a.b' v1 was successfully updated.\n"
  }

  run update_ide_extensions

  [ "$status" -eq 0 ]
  [[ "$output" == *"nova tentativa"* ]]
  [[ "$output" == *"Total de extensões atualizadas: 1"* ]]
  [ "$(wc -l < "$calls_file")" -eq 2 ]
}

@test "step: 5xx persistente respeita o teto de tentativas" {
  local calls_file="$BATS_TEST_TMPDIR/marketplace-calls-max"
  : > "$calls_file"
  IDE_EXT_CLIS="code"
  IDE_EXT_MAX_ATTEMPTS=3
  IDE_EXT_RETRY_DELAY_S=0
  has() { [[ "$1" == code ]]; }
  run_node_network_cmd() {
    printf '%s\n' x >> "$calls_file"
    printf 'Server returned 503\n'
    return "$RC_WARN"
  }

  run update_ide_extensions

  [ "$status" -eq "$RC_WARN" ]
  [ "$(wc -l < "$calls_file")" -eq 3 ]
  [[ "$output" == *"marketplace indisponível"* ]]
}

@test "step: erro não-5xx não ganha retry (repetir não muda o motivo)" {
  local calls_file="$BATS_TEST_TMPDIR/ide-non5xx-calls"
  : > "$calls_file"
  IDE_EXT_CLIS="code"
  IDE_EXT_MAX_ATTEMPTS=3
  IDE_EXT_RETRY_DELAY_S=0
  has() { [[ "$1" == code ]]; }
  run_node_network_cmd() {
    printf '%s\n' x >> "$calls_file"
    printf 'could not resolve host\n'
    return "$RC_WARN"
  }

  run update_ide_extensions

  [ "$status" -eq "$RC_WARN" ]
  [ "$(wc -l < "$calls_file")" -eq 1 ]
  [[ "$output" == *"falha de rede"* ]]
}

@test "_marketplace_5xx_output: reconhece as formas de 5xx do marketplace" {
  run _marketplace_5xx_output 'Server returned 503'
  [ "$status" -eq 0 ]
  run _marketplace_5xx_output 'HTTP 504 Gateway Timeout'
  [ "$status" -eq 0 ]
  run _marketplace_5xx_output 'ERROR: Service Unavailable'
  [ "$status" -eq 0 ]
  # Rede local e erros permanentes do marketplace não são 5xx transitórios.
  run _marketplace_5xx_output 'could not resolve host'
  [ "$status" -ne 0 ]
  run _marketplace_5xx_output 'Server returned 404'
  [ "$status" -ne 0 ]
  run _marketplace_5xx_output ''
  [ "$status" -ne 0 ]
}

@test "step: 503 via RC_WARN também ganha motivo de marketplace" {
  IDE_EXT_CLIS="code"
  IDE_EXT_MAX_ATTEMPTS=1
  has() { [[ "$1" == code ]]; }
  STEP_REASON=""
  run_node_network_cmd() { printf 'Server returned 503\n'; return "$RC_WARN"; }
  run update_ide_extensions
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"marketplace indisponível"* ]]
}

@test "step: erro genérico sem assinatura 5xx mantém motivo de rede" {
  IDE_EXT_CLIS="code"
  has() { [[ "$1" == code ]]; }
  STEP_REASON=""
  run_node_network_cmd() { printf 'algum erro desconhecido\n'; return 1; }
  run update_ide_extensions
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"erro ao atualizar extensões (rc=1)"* ]]
}

@test "step: soma de múltiplos CLIs" {
  IDE_EXT_CLIS="code cursor"
  has() { [[ "$1" == code || "$1" == cursor ]]; }
  run_network_cmd() {
    printf "Extension 'x.y' v1 was successfully updated.\n"
    return 0
  }
  run update_ide_extensions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total de extensões atualizadas: 2"* ]]
}
