#!/usr/bin/env bats
# tests/config.bats — typo-guard de chaves de config (L4)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # config.sh não é carregado por load_libs (tem auto-detecção); sourcing direto
  # é seguro: as funções de lint são puras e não rodam nada no source.
  # shellcheck source=/dev/null
  source "${FU_LIB}/config.sh"
}

# ── levenshtein ───────────────────────────────────────────────────────────────

@test "levenshtein: strings iguais => 0" {
  run levenshtein SNAPSHOT_KEEP SNAPSHOT_KEEP
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "levenshtein: um char faltando => 1" {
  run levenshtein ENABLE_CUSTOM_TOOL ENABLE_CUSTOM_TOOLS
  [ "$output" = "1" ]
}

@test "levenshtein: duas trocas => 2" {
  run levenshtein SNAPSHOT_KEPT SNAPSHOT_KEEP
  [ "$output" = "2" ]
}

@test "levenshtein: chaves não relacionadas => distância grande" {
  run levenshtein MIN_FREE_GIB FULL_UPGRADE_REPO
  (( output >= 5 ))
}

# ── config_known_keys ─────────────────────────────────────────────────────────

@test "config_known_keys: inclui as chaves canônicas" {
  run config_known_keys
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENABLE_CUSTOM_TOOLS"* ]]
  [[ "$output" == *"NOTIFY_ON_FINISH"* ]]
  [[ "$output" == *"FULL_UPGRADE_SKIP"* ]]
}

# ── config_assigned_keys ──────────────────────────────────────────────────────

@test "config_assigned_keys: captura KEY= e export KEY=, ignora comentários" {
  local tmp="${BATS_TEST_TMPDIR}/cfg"
  cat > "$tmp" <<'EOF'
# comentário
ENABLE_CUSTOM_TOOLS=1
export NOTIFY_ON_FINISH=1
  MIN_FREE_GIB=3
# NOT_A_KEY=ignored
EOF
  run config_assigned_keys "$tmp"
  [[ "$output" == *"ENABLE_CUSTOM_TOOLS"* ]]
  [[ "$output" == *"NOTIFY_ON_FINISH"* ]]
  [[ "$output" == *"MIN_FREE_GIB"* ]]
  [[ "$output" != *"NOT_A_KEY"* ]]
}

@test "config_assigned_keys: deduplica chaves repetidas" {
  local tmp="${BATS_TEST_TMPDIR}/cfg"
  printf 'MIN_FREE_GIB=1\nMIN_FREE_GIB=2\n' > "$tmp"
  run config_assigned_keys "$tmp"
  [ "$(grep -c MIN_FREE_GIB <<< "$output")" -eq 1 ]
}

# ── config_lint_keys ──────────────────────────────────────────────────────────

@test "config_lint_keys: acusa typos e sugere a chave certa" {
  local tmp="${BATS_TEST_TMPDIR}/cfg"
  cat > "$tmp" <<'EOF'
ENABLE_CUSTOM_TOOL=1
export NOTFY_ON_FINISH=1
MIN_FREE_GIB=3
MY_OWN_HELPER=foo
EOF
  run config_lint_keys "$tmp"
  [[ "$output" == *"ENABLE_CUSTOM_TOOL|ENABLE_CUSTOM_TOOLS"* ]]
  [[ "$output" == *"NOTFY_ON_FINISH|NOTIFY_ON_FINISH"* ]]
}

@test "config_lint_keys: não acusa chaves válidas" {
  local tmp="${BATS_TEST_TMPDIR}/cfg"
  printf 'MIN_FREE_GIB=3\nSNAPSHOT_KEEP=5\n' > "$tmp"
  run config_lint_keys "$tmp"
  [ -z "$output" ]
}

@test "config_lint_keys: não acusa var do usuário sem near-miss" {
  local tmp="${BATS_TEST_TMPDIR}/cfg"
  printf 'MY_OWN_HELPER=foo\n' > "$tmp"
  run config_lint_keys "$tmp"
  [[ "$output" != *"MY_OWN_HELPER"* ]]
}

@test "config_lint_keys: ignora identificadores curtos (<5)" {
  local tmp="${BATS_TEST_TMPDIR}/cfg"
  printf 'ABCD=1\n' > "$tmp"
  run config_lint_keys "$tmp"
  [ -z "$output" ]
}

@test "config_lint_keys: arquivo inexistente => vazio, rc 0" {
  run config_lint_keys "${BATS_TEST_TMPDIR}/nope"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
