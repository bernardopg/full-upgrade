#!/usr/bin/env bats
# tests/uv_tools_hold.bats — U2: ferramenta uv presa por restrição gravada no
# uv-receipt.toml. uv, PyPI e a unit do headroom são stubs; nada toca rede.

load test_helper

setup() {
  load_libs
  HEADROOM_USER_UNIT="$BATS_TEST_TMPDIR/no-unit"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_py.sh"
  log() { printf '%s\n' "$*"; }
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS/headroom-ai" "$TOOLS/graphifyy"
  cat >"$TOOLS/headroom-ai/uv-receipt.toml" <<'TOML'
[tool]
requirements = [
    { name = "headroom-ai", extras = ["all"] },
    { name = "mcp", specifier = "<2" },
]
entrypoints = [
    { name = "headroom", install-path = "/x/bin/headroom", from = "headroom-ai" },
]
TOML
  cat >"$TOOLS/graphifyy/uv-receipt.toml" <<'TOML'
[tool]
requirements = [{ name = "graphifyy" }]
TOML
  export TOOLS
  uv() {
    case "$1 $2" in
      "tool upgrade") echo "Nothing to upgrade" ; return 0 ;;
      "tool dir") echo "$TOOLS" ;;
      "tool list") printf 'graphifyy v0.9.112\n- graphify\nheadroom-ai v0.42.0\n- headroom\n' ;;
    esac
  }
  pypi_latest_version() { case "$1" in headroom-ai) echo 0.44.0 ;; graphifyy) echo 0.9.112 ;; esac; }
}

@test "uv_receipt_constraints: lê o --with com specifier" {
  run uv_receipt_constraints "$TOOLS/headroom-ai/uv-receipt.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "mcp<2" ]
}

@test "uv_receipt_constraints: receipt sem specifier não imprime nada" {
  run uv_receipt_constraints "$TOOLS/graphifyy/uv-receipt.toml"
  [ "$output" = "" ]
}

@test "uv_receipt_constraints: pin da própria ferramenta em linha única" {
  printf '[tool]\nrequirements = [{ name = "ruff", specifier = "==0.1.0" }]\n' >"$BATS_TEST_TMPDIR/r.toml"
  run uv_receipt_constraints "$BATS_TEST_TMPDIR/r.toml"
  [ "$output" = "ruff==0.1.0" ]
}

@test "uv_receipt_constraints: receipt ausente => vazio e rc 0" {
  run uv_receipt_constraints "$BATS_TEST_TMPDIR/nada.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "uv_receipt_install_spec: inclui os extras e descarta o --with" {
  run uv_receipt_install_spec "$TOOLS/headroom-ai/uv-receipt.toml" headroom-ai
  [ "$output" = "headroom-ai[all]" ]
}

@test "uv_receipt_install_spec: sem extras devolve só o nome" {
  run uv_receipt_install_spec "$TOOLS/graphifyy/uv-receipt.toml" graphifyy
  [ "$output" = "graphifyy" ]
}

@test "uv_tool_list_versions: ignora as linhas de executáveis" {
  run uv_tool_list_versions "$(printf 'semgrep v1.185.0\n- semgrep\nmcp-for-blender v2.3.0\n')"
  [ "$output" = "$(printf 'semgrep 1.185.0\nmcp-for-blender 2.3.0')" ]
}

@test "uv_tools_held_back: aponta só a ferramenta com restrição e atrás do PyPI" {
  run uv_tools_held_back
  [ "$status" -eq 0 ]
  [ "$output" = "headroom-ai|0.42.0|0.44.0|mcp<2|headroom-ai[all]" ]
}

@test "uv_tools_held_back: PyPI indisponível não acusa nada" {
  pypi_latest_version() { :; }
  run uv_tools_held_back
  [ "$output" = "" ]
}

@test "uv_tools_held_back: restrição presente mas já na última não acusa" {
  pypi_latest_version() { echo 0.42.0; }
  run uv_tools_held_back
  [ "$output" = "" ]
}

@test "uv_tool_hold_ignored: compara pela PEP 503 com vírgula ou espaço" {
  FULL_UPGRADE_UV_TOOL_HOLD_IGNORE="foo, Headroom_AI"
  run uv_tool_hold_ignored headroom-ai
  [ "$status" -eq 0 ]
  run uv_tool_hold_ignored graphifyy
  [ "$status" -ne 0 ]
}

@test "update_uv_tools: ferramenta presa vira RC_TODO com a remediação" {
  run update_uv_tools
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"headroom-ai 0.42.0 está preso pela restrição 'mcp<2'"* ]]
  [[ "$output" == *"uv tool install 'headroom-ai[all]' --force"* ]]
}

@test "update_uv_tools: ferramenta presa e ignorada fica ok" {
  FULL_UPGRADE_UV_TOOL_HOLD_IGNORE="headroom-ai"
  run update_uv_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixado de propósito"* ]]
}

@test "update_uv_tools: pendência do headroom tem precedência e soma o motivo" {
  check_headroom_unit_compat() { STEP_REASON="unit incompatível"; return "$RC_TODO"; }
  local rc=0
  update_uv_tools >/dev/null || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "unit incompatível; uv tool preso por restrição do receipt: headroom-ai 0.42.0→0.44.0" ]]
}
