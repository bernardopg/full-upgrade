#!/usr/bin/env bats
# tests/hermes.bats — helper puro do gate de update do Hermes (steps.d).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/10-hermes.sh"
}

@test "hermes_is_current: 'Already up to date' => atual (rc 0)" {
  run hermes_is_current $'→ Fetching from upstream...\n✓ Already up to date.'
  [ "$status" -eq 0 ]
}

@test "hermes_is_current: 'up to date' minúsculo => atual" {
  run hermes_is_current "everything up to date"
  [ "$status" -eq 0 ]
}

@test "hermes_is_current: update disponível => não-atual (rc != 0)" {
  run hermes_is_current $'→ Fetching...\n→ 2 commit(s) behind, run update'
  [ "$status" -ne 0 ]
}

@test "hermes_is_current: saída vazia => não-atual (não pula)" {
  run hermes_is_current ""
  [ "$status" -ne 0 ]
}

@test "catálogo dá ao Hermes tempo para probe, update e drain do gateway" {
  local row timeout_s
  row="$(step_catalog | grep '^Atualizar Hermes|')"
  timeout_s="$(cut -d'|' -f5 <<<"$row")"
  [ "$timeout_s" -eq 420 ]
}

@test "update_hermes: timeout do probe cai para o update completo" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="test"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  sleep() { :; }
  hermes() { printf '✓ Update complete!\n'; }

  run update_hermes
  [ "$status" -eq 0 ]
  [ -s "${LOG_DIR}/hermes-update-${RUN_ID}.log" ]
  grep -q 'Update complete' "${LOG_DIR}/hermes-update-${RUN_ID}.log"
}

@test "update_hermes: falha de rede no update vira warn com log no motivo" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="network"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  sleep() { :; }
  hermes() {
    printf 'fatal: unable to access repository: Could not resolve host\n'
    return 1
  }

  local rc
  set +e
  update_hermes >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"rede indisponível"* ]]
  [[ "$STEP_REASON" == *"hermes-update-network.log"* ]]
}

@test "update_hermes: requisição parada no GitHub é repetida e o update conclui" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="stall"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  sleep() { :; }
  echo 0 > "$BATS_TEST_TMPDIR/calls"
  hermes() {
    local n
    n=$(( $(cat "$BATS_TEST_TMPDIR/calls") + 1 ))
    echo "$n" > "$BATS_TEST_TMPDIR/calls"
    # O limite de baixa velocidade chega ao git que o Hermes chama e cresce a
    # cada tentativa (20s, depois 40s).
    [[ "${GIT_HTTP_LOW_SPEED_LIMIT:-}" == 1 && "${GIT_HTTP_LOW_SPEED_TIME:-}" == $(( 20 * n )) ]] || return 2
    if (( n == 1 )); then
      printf "fatal: unable to access 'https://github.com/NousResearch/hermes-agent.git/': Operation too slow. Less than 1 bytes/sec transferred the last 20 seconds\n"
      return 1
    fi
    printf '✓ Update complete!\n'
  }

  run update_hermes
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
}

@test "update_hermes: falha que não é de rede não é repetida" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="nonet"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  sleep() { :; }
  echo 0 > "$BATS_TEST_TMPDIR/calls"
  hermes() {
    echo $(( $(cat "$BATS_TEST_TMPDIR/calls") + 1 )) > "$BATS_TEST_TMPDIR/calls"
    printf 'error: merge conflict in hermes_cli/main.py\n'
    return 1
  }

  run update_hermes
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
}

# Regressão real (run 20260929-202410): o Hermes troca o erro do git por frases
# próprias ("✗ Network error — cannot reach the remote repository."). Sem elas no
# regex a requisição parada virava fail, sem nova tentativa.
@test "update_hermes: diagnóstico de rede do próprio Hermes é repetido" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="hermesnet"
  LOG_FILE=/dev/null
  timeout() { return 124; }
  sleep() { :; }
  echo 0 > "$BATS_TEST_TMPDIR/calls"
  hermes() {
    local n
    n=$(( $(cat "$BATS_TEST_TMPDIR/calls") + 1 ))
    echo "$n" > "$BATS_TEST_TMPDIR/calls"
    if (( n == 1 )); then
      printf '→ Fetching updates...\n✗ Network error — cannot reach the remote repository.\n'
      return 1
    fi
    printf '✓ Update complete!\n'
  }

  run update_hermes
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
}

@test "NETWORK_TRANSIENT_RE: casa os diagnósticos de fetch do Hermes" {
  grep -qiE "$NETWORK_TRANSIENT_RE" <<<'✗ Network error — cannot reach the remote repository.'
  grep -qiE "$NETWORK_TRANSIENT_RE" <<<'✗ GitHub appears to be having an outage — try again in a few minutes'
  grep -qiE "$NETWORK_TRANSIENT_RE" <<<'✗ GitHub rejected the anonymous fetch (asked for a login)'
}

@test "Hermes captura stderr Git ocultado e repete apenas falha de rede real" {
  LOG_DIR="$BATS_TEST_TMPDIR"
  RUN_ID="hidden"
  LOG_FILE="$LOG_DIR/main.log"
  local fake_bin="$LOG_DIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'De https://github.com/example/repo\nfatal: Operation too slow\n' >&2
exit 128
EOF
  chmod +x "$fake_bin/git"
  PATH="$fake_bin:$PATH"
  timeout() { return 124; }
  sleep() { :; }
  hermes() {
    echo call >> "$LOG_DIR/calls"
    local stderr
    stderr="$(git fetch 2>&1)"
    printf 'Failed to fetch updates from origin.\n  %s\n' "${stderr%%$'\n'*}"
    return 1
  }
  run update_hermes
  [ "$status" -eq "$RC_WARN" ]
  [ "$(wc -l < "$LOG_DIR/calls")" -eq 3 ]
  grep -q 'fatal: Operation too slow' "$LOG_FILE"
  [ -z "$(find "$LOG_DIR" -maxdepth 1 -type d -name 'hermes-git.*')" ]
}
