#!/usr/bin/env bats
# O gh é mockado: nenhum teste consulta credenciais ou rede reais.
setup() {
  load test_helper
  load_libs
  source "${FU_LIB}/steps/ai.sh"
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR"
  unset GITHUB_TOKEN GH_TOKEN
  has() { [[ "$1" == kimchi || "$1" == gh ]]; }
  kimchi() { [[ "$1" == --version ]] && printf 'kimchi 1.16.0\n'; }
  gh() {
    [[ "$*" == 'api repos/getkimchi/kimchi/releases/latest --jq .tag_name' ]] || return 90
    printf 'v1.16.0\n'
  }
  run_network_cmd() {
    printf 'kimchi update: failed to check for updates: github API returned 403\n'
    return 1
  }
}

@test "kimchi: 403 com versão atual confirmada via gh retorna OK" {
  update_kimchi && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
  [[ "$STEP_REASON" == *confirmada* ]]
  [ -z "${GITHUB_TOKEN:-}" ]
}

@test "kimchi: release nova via gh não vira falso up-to-date" {
  gh() { printf 'v1.17.0\n'; }
  update_kimchi && rc=0 || rc=$?
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *'1.17.0 disponível'* ]]
}

@test "kimchi: resposta inválida do gh não vira sucesso" {
  gh() { printf 'invalid-response\n'; }
  run update_kimchi
  [ "$status" -eq "$RC_WARN" ]
}

@test "kimchi: gh indisponível mantém WARN com motivo não vazio" {
  gh() { return 1; }
  update_kimchi && rc=0 || rc=$?
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *kimchi* ]]
}

@test "kimchi: falha que não é 403 não consulta gh" {
  run_network_cmd() { printf 'connection timed out\n'; return "$RC_WARN"; }
  gh() { printf 'consulta-indevida\n' >&2; return 88; }
  run update_kimchi
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" != *consulta-indevida* ]]
}
