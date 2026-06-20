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

@test "step: falha de rede num CLI vira RC_WARN" {
  IDE_EXT_CLIS="code"
  has() { [[ "$1" == code ]]; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run update_ide_extensions
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha de rede"* ]]
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
