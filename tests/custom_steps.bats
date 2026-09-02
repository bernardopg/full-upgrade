#!/usr/bin/env bats
# tests/custom_steps.bats — funções de steps.d/30-copilot.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/30-copilot.sh"
  MOCKDIR="$(mktemp -d)"
  export LOG_FILE="/dev/null"
}

teardown() {
  rm -rf "$MOCKDIR"
}

# ── update_copilot_cli ─────────────────────────────────────────────────────────

@test "copilot: binário não encontrado => return 0 (skip)" {
  # Força o branch "não encontrado" sem depender do PATH do host
  COPILOT_BIN="$MOCKDIR/bin/inexistente"
  run update_copilot_cli
  [ "$status" -eq 0 ]
}

@test "copilot: update com sucesso (rc=0) => return 0" {
  cat >"$MOCKDIR/copilot" <<'SH'
#!/bin/sh
echo "Updated copilot"
exit 0
SH
  chmod +x "$MOCKDIR/copilot"
  COPILOT_BIN="$MOCKDIR/copilot"
  QUIET=0
  run update_copilot_cli
  [ "$status" -eq 0 ]
}

@test "copilot: update com falha forwarda rc" {
  cat >"$MOCKDIR/copilot" <<'SH'
#!/bin/sh
echo "Update failed"
exit 1
SH
  chmod +x "$MOCKDIR/copilot"
  COPILOT_BIN="$MOCKDIR/copilot"
  QUIET=0
  run update_copilot_cli
  [ "$status" -eq 1 ]
}

@test "copilot: COPILOT_BIN definido tem prioridade" {
  printf '#!/bin/sh\necho "copilot updated"\nexit 0\n' > "$MOCKDIR/custom-copilot"
  chmod +x "$MOCKDIR/custom-copilot"
  COPILOT_BIN="$MOCKDIR/custom-copilot"
  QUIET=0
  run update_copilot_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot updated"* ]]
}

@test "copilot: output filtrado remove linhas vazias" {
  cat >"$MOCKDIR/copilot" <<'SH'
#!/bin/sh
echo ""
echo "Updated"
echo ""
exit 0
SH
  chmod +x "$MOCKDIR/copilot"
  COPILOT_BIN="$MOCKDIR/copilot"
  QUIET=0
  run update_copilot_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated"* ]]
}
