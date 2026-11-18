#!/usr/bin/env bats
# tests/doctor_dev_more_cov.bats — inventário de CLIs de IA com --version que
# estoura o teto, autofix do pip (sem pip; pendência que sobra) e o Doctor de
# MCP com todas as fontes: token do gh, TOML inválido do Codex, entradas com
# problema no OpenCode/hub, Hermes falhando e hub divergente. HOME descartável.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/mcp.sh"
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  unset GITHUB_PERSONAL_ACCESS_TOKEN CODEX_GITHUB_PERSONAL_ACCESS_TOKEN
}

@test "CLIs de IA: --version além do teto é registrado e o inventário segue" {
  stub claude 0 "2.0.0"
  stub codex 0 "codex 0.152.0"
  stub_script timeout '[[ "$2" == *claude ]] && exit 124; shift; exec "$@"'
  run doctor_ai_clis
  [[ "$output" == *"claude: verificação de versão excedeu 5s"* ]]
  [[ "$output" == *"codex:"*"0.152.0"* ]]
}

@test "autofix pip: sem pip e pendência que continua depois do install" {
  AUTO_FIX_PIP_DEPS=1
  run autofix_pip_user_deps
  [[ "$output" == *"pip indisponível"* ]]
  stub_script python 'if [[ "$1 $2" == "-m pip" ]]; then
  case "$3" in check) echo "fvs 0.3.4 requires orjson, which is not installed."; exit 1 ;; esac
  exit 0
fi
exec python3 "$@"'
  _classify_pip_origins() { printf '%s\tuser\n' "$(cat)"; }
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip check ainda reporta pendências"* ]]
}

# Ambiente MCP com todas as fontes; cada uma traz um problema diferente.
_mcp_sources() {
  mkdir -p "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.hermes"
  printf 'lixo = = =\n' > "$HOME/.codex/config.toml"
  echo '{"mcp":{"ok":{"type":"local","command":["npx","x"]},"ruim":"texto"}}' > "$HOME/.config/opencode/opencode.json"
  printf 'mcp_servers:\n  memoria:\n    command: x\n' > "$HOME/.hermes/config.yaml"
  stub gh 0 "gho_token_de_teste"
  stub hermes 3 ""
  mcp_hub_drift() { return 1; }
  mcp_hub_json() { echo "$HOME/hub.json"; }
}

@test "MCP: todas as fontes com problemas viram warn com remediação do Codex" {
  _mcp_sources
  stub headroom 0 ""
  run doctor_mcp_servers
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"codex: TOML inválido"* ]]
  [[ "$output" == *"opencode:ruim"* ]]
  [[ "$output" == *"hermes: 'hermes mcp list' falhou (rc=3)"* ]]
  [[ "$output" == *"hub: configs MCP divergentes"* ]]
  [[ "$output" == *"Remediação (codex):"* ]]
}

@test "MCP: fontes presentes sem servidor e MCP_AUTO_UPDATE ligado" {
  mkdir -p "$HOME/.config/opencode"
  echo '{"mcp":{}}' > "$HOME/.config/opencode/opencode.json"
  mcp_hub_drift() { return 0; }
  mcp_hub_json() { echo "$HOME/nao-existe.json"; }
  run doctor_mcp_servers
  [[ "$output" == *"Fontes MCP presentes, mas nenhum servidor configurado"* ]]
  echo '{"mcp":{"ok":{"type":"local","command":["npx","x"]}}}' > "$HOME/.config/opencode/opencode.json"
  stub npx 0 ""
  MCP_AUTO_UPDATE=1 run doctor_mcp_servers
  [[ "$output" == *"MCP_AUTO_UPDATE=1"* ]]
}

@test "MCP: token do Codex resolvido pelo gh e entrada inválida no JSON do hub" {
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.gh]\ncommand = "x"\nenv = { GITHUB_PERSONAL_ACCESS_TOKEN = "${CODEX_GITHUB_PERSONAL_ACCESS_TOKEN}" }\n' > "$HOME/.codex/config.toml"
  stub gh 0 "gho_teste"
  echo '{lixo' > "$HOME/hub.json"
  mcp_hub_drift() { return 0; }
  mcp_hub_json() { echo "$HOME/hub.json"; }
  run doctor_mcp_servers
  [[ "$output" == *"hub: JSON inválido"* ]]
}
