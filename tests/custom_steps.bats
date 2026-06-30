#!/usr/bin/env bats
# tests/custom_steps.bats — funções de steps.d/20-adguardvpn.sh e steps.d/30-copilot.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/20-adguardvpn.sh"
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/30-copilot.sh"
  MOCKDIR="$(mktemp -d)"
  export LOG_FILE="/dev/null"
}

teardown() {
  rm -rf "$MOCKDIR"
}

# ── update_adguardvpn ──────────────────────────────────────────────────────────

@test "adguardvpn: binário não encontrado => return 0 (skip)" {
  # Força o branch "não encontrado" sem depender do PATH do host
  ADGUARD_BIN="$MOCKDIR/bin/inexistente"
  run update_adguardvpn
  [ "$status" -eq 0 ]
}

@test "adguardvpn: rc=17 (latest version) => return 0" {
  printf '#!/bin/sh\necho "adguardvpn-cli 2.5.0"\n' > "$MOCKDIR/adguardvpn-cli"
  printf '#!/bin/sh\nexit 17\n' >> "$MOCKDIR/adguardvpn-cli"
  chmod +x "$MOCKDIR/adguardvpn-cli"
  ADGUARD_BIN="$MOCKDIR/adguardvpn-cli"
  QUIET=0
  run update_adguardvpn
  [ "$status" -eq 0 ]
}

@test "adguardvpn: grep 'latest version' no output => return 0" {
  cat >"$MOCKDIR/adguardvpn-cli" <<'SH'
#!/bin/sh
case "$*" in
  "--version") echo "adguardvpn-cli 2.5.0" ;;
  "update -y") echo "You are using the latest version" ; exit 1 ;;
esac
SH
  chmod +x "$MOCKDIR/adguardvpn-cli"
  ADGUARD_BIN="$MOCKDIR/adguardvpn-cli"
  QUIET=0
  run update_adguardvpn
  [ "$status" -eq 0 ]
}

@test "adguardvpn: update com sucesso (rc=0) => return 0" {
  cat >"$MOCKDIR/adguardvpn-cli" <<'SH'
#!/bin/sh
case "$*" in
  "--version") echo "adguardvpn-cli 2.5.0" ;;
  "update -y") echo "Updated to 2.6.0" ; exit 0 ;;
esac
SH
  chmod +x "$MOCKDIR/adguardvpn-cli"
  ADGUARD_BIN="$MOCKDIR/adguardvpn-cli"
  QUIET=0
  run update_adguardvpn
  [ "$status" -eq 0 ]
}

@test "adguardvpn: update com falha (rc!=0,17) => forward rc" {
  cat >"$MOCKDIR/adguardvpn-cli" <<'SH'
#!/bin/sh
case "$*" in
  "--version") echo "adguardvpn-cli 2.5.0" ;;
  "update -y") echo "Network error" ; exit 1 ;;
esac
SH
  chmod +x "$MOCKDIR/adguardvpn-cli"
  ADGUARD_BIN="$MOCKDIR/adguardvpn-cli"
  QUIET=0
  run update_adguardvpn
  [ "$status" -eq 1 ]
}

@test "adguardvpn: ADGUARD_BIN definido tem prioridade" {
  printf '#!/bin/sh\necho "adguardvpn-cli 3.0.0"\n' > "$MOCKDIR/custom-adguard"
  printf '#!/bin/sh\nexit 17\n' >> "$MOCKDIR/custom-adguard"
  chmod +x "$MOCKDIR/custom-adguard"
  ADGUARD_BIN="$MOCKDIR/custom-adguard"
  QUIET=0
  run update_adguardvpn
  [ "$status" -eq 0 ]
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
