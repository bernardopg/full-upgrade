#!/usr/bin/env bats
# tests/ai_plugin_blocklist.bats — AI_PLUGIN_BLOCKLIST: plugins de agentes
# desinstalados do Codex e do Claude Code antes de renovar os marketplaces.
# codex/claude são sempre funções stub: nada toca ~/.codex, ~/.claude nem rede.
#
# Caso real: um plugin desligado só por caminho de skill no config.toml do
# Codex (…/<plugin>/5.3.2/skills/…) voltou a carregar numa sessão depois que o
# `codex plugin marketplace upgrade` instalou a 5.3.3 num caminho novo.

load test_helper

CODEX_PLUGINS='{"installed":[
  {"pluginId":"noisy@noisy","name":"noisy","marketplaceName":"noisy"},
  {"pluginId":"documents@openai-primary-runtime","name":"documents","marketplaceName":"openai-primary-runtime"},
  {"pluginId":"extra@noisy","name":"extra","marketplaceName":"noisy"}]}'
CODEX_MKTS='{"marketplaces":[{"name":"noisy"},{"name":"openai-primary-runtime"}]}'
CLAUDE_PLUGINS='[
  {"id":"noisy@noisy","scope":"user"},
  {"id":"caveman@caveman","scope":"user"},
  {"id":"noisy@noisy","scope":"project"}]'
CLAUDE_MKTS='[{"name":"noisy"},{"name":"caveman"}]'

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"
  : > "$LOG_FILE"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  timeout() { shift; "$@"; }
  codex() {
    case "$*" in
      'plugin list --json') printf '%s\n' "$CODEX_PLUGINS" ;;
      'plugin marketplace list --json') printf '%s\n' "$CODEX_MKTS" ;;
      *) printf 'codex %s\n' "$*" >> "$CALLS"; return "${MOCK_RM_RC:-0}" ;;
    esac
  }
  claude() {
    case "$*" in
      'plugin list --json') printf '%s\n' "$CLAUDE_PLUGINS" ;;
      'plugin marketplace list --json') printf '%s\n' "$CLAUDE_MKTS" ;;
      *) printf 'claude %s\n' "$*" >> "$CALLS"; return "${MOCK_RM_RC:-0}" ;;
    esac
  }
}

@test "ai_plugin_blocked codex-plugins: casa por nome do plugin ou do marketplace" {
  run ai_plugin_blocked codex-plugins noisy <<<"$CODEX_PLUGINS"
  [ "$status" -eq 0 ]
  [ "$output" = $'noisy@noisy\nextra@noisy' ]
}

@test "ai_plugin_blocked claude-plugins: só escopo user, sem duplicar" {
  run ai_plugin_blocked claude-plugins Noisy <<<"$CLAUDE_PLUGINS"
  [ "$output" = "noisy@noisy" ]
}

@test "ai_plugin_blocked marketplaces e JSON inválido" {
  run ai_plugin_blocked codex-marketplaces noisy <<<"$CODEX_MKTS"
  [ "$output" = "noisy" ]
  run ai_plugin_blocked claude-marketplaces noisy <<<"$CLAUDE_MKTS"
  [ "$output" = "noisy" ]
  run ai_plugin_blocked codex-plugins noisy <<<"não é json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ai_plugin_purge_blocked: blocklist vazia não chama o CLI" {
  AI_PLUGIN_BLOCKLIST=""
  run ai_plugin_purge_blocked codex
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "ai_plugin_purge_blocked codex: remove plugins e depois o marketplace" {
  AI_PLUGIN_BLOCKLIST="noisy"
  ai_plugin_purge_blocked codex
  [ "$(cat "$CALLS")" = $'codex plugin remove noisy@noisy\ncodex plugin remove extra@noisy\ncodex plugin marketplace remove noisy' ]
  [[ "$(cat "$LOG_FILE")" == *"AI_PLUGIN_BLOCKLIST: removido(s) do codex: plugin noisy@noisy, plugin extra@noisy, marketplace noisy."* ]]
}

@test "ai_plugin_purge_blocked claude: uninstall em escopo user, aceita vírgula" {
  AI_PLUGIN_BLOCKLIST="outro,noisy"
  ai_plugin_purge_blocked claude
  [ "$(cat "$CALLS")" = $'claude plugin uninstall --scope user noisy@noisy\nclaude plugin marketplace remove noisy' ]
}

@test "ai_plugin_purge_blocked: falha na remoção não falha o step" {
  AI_PLUGIN_BLOCKLIST="noisy"
  MOCK_RM_RC=1
  run ai_plugin_purge_blocked codex
  [ "$status" -eq 0 ]
  [[ "$(cat "$LOG_FILE")" == *"Falha ao remover o plugin bloqueado noisy@noisy (codex)"* ]]
}

@test "update_codex_plugins: remove bloqueados antes do marketplace upgrade" {
  AI_PLUGIN_BLOCKLIST="noisy"
  has() { [[ "$1" == codex ]]; }
  run_network_cmd() { printf 'upgrade\n' >> "$CALLS"; "$@" >/dev/null; }
  update_codex_plugins
  [ "$(head -1 "$CALLS")" = "codex plugin remove noisy@noisy" ]
  [ "$(tail -1 "$CALLS")" = "codex plugin marketplace upgrade" ]
}
