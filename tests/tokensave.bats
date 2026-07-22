#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  source "${FU_ROOT}/steps.d/71-tokensave.sh"
  LOG_FILE=/dev/null QUIET=0
}

@test "update_tokensave: usa self-updater oficial e confirma versão" {
  local fake="${BATS_TEST_TMPDIR}/tokensave" calls="${BATS_TEST_TMPDIR}/calls"
  printf '#!/usr/bin/env bash\n[[ "$1" == "--version" ]] && { echo "tokensave 7.6.0"; exit 0; }\n' > "$fake"
  chmod +x "$fake"
  TOKENSAVE_BIN="$fake"
  run_network_cmd() { printf '%s\n' "$*" >> "$calls"; return 0; }
  export TOKENSAVE_BIN calls

  run update_tokensave
  [ "$status" -eq 0 ]
  grep -q 'upgrade' "$calls"
  [[ "$output" == *"tokensave 7.6.0"* ]]
}

@test "update_tokensave: falha de rede vira RC_WARN sem apagar binário" {
  local fake="${BATS_TEST_TMPDIR}/tokensave"
  printf '#!/usr/bin/env bash\necho "tokensave 7.6.0"\n' > "$fake"
  chmod +x "$fake"
  TOKENSAVE_BIN="$fake"
  run_network_cmd() { return "$RC_WARN"; }
  export TOKENSAVE_BIN

  run update_tokensave
  [ "$status" -eq "$RC_WARN" ]
  [ -x "$fake" ]
}
