#!/usr/bin/env bats
# tests/claude_plugins_prefilter.bats — U15: pré-filtro que evita chamar
# `claude plugin update` para plugin idêntico ao clone do marketplace. Toda a
# árvore de config do Claude é montada em $BATS_TEST_TMPDIR.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  command -v jq >/dev/null || skip "jq ausente"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  P="$CLAUDE_CONFIG_DIR/plugins"
  MK="$BATS_TEST_TMPDIR/mk"
  mkdir -p "$P" "$MK/.claude-plugin" "$MK/plugins/rel/.claude-plugin" "$MK/plugins/semver/.claude-plugin"
  printf '{"m":{"installLocation":"%s"}}' "$MK" >"$P/known_marketplaces.json"
  cat >"$MK/.claude-plugin/marketplace.json" <<'JSON'
{"plugins":[
  {"name":"explicit","version":"2.0.0","source":"./plugins/x"},
  {"name":"semver","source":"./plugins/semver"},
  {"name":"rel","source":"./plugins/rel"},
  {"name":"pinned","source":{"source":"git-subdir","url":"https://x","sha":"aaaaaaaa1111"}}
]}
JSON
  echo '{"name":"semver","version":"1.2.0"}' >"$P/../semver.json"
  cp "$P/../semver.json" "$MK/plugins/semver/.claude-plugin/plugin.json"
  echo '{"name":"rel"}' >"$MK/plugins/rel/.claude-plugin/plugin.json"
  git -C "$MK" init -q
  git -C "$MK" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
  HEAD12="$(git -C "$MK" rev-parse HEAD | cut -c1-12)"
}

# $1 = id, $2 = version, $3 = gitCommitSha
_installed() {
  printf '{"version":2,"plugins":{"%s":[{"scope":"project","version":"0"},{"scope":"user","version":"%s","gitCommitSha":"%s"}]}}' \
    "$1" "$2" "$3" >"$P/installed_plugins.json"
}

@test "prefilter: versão explícita igual => pula" {
  _installed explicit@m 2.0.0 x
  run claude_plugin_maybe_outdated explicit@m
  [ "$status" -eq 1 ]
}

@test "prefilter: versão explícita diferente => chama o update" {
  _installed explicit@m 1.9.0 x
  run claude_plugin_maybe_outdated explicit@m
  [ "$status" -eq 0 ]
}

@test "prefilter: fonte relativa usa a versão do plugin.json" {
  _installed semver@m 1.2.0 x
  run claude_plugin_maybe_outdated semver@m
  [ "$status" -eq 1 ]
  _installed semver@m 1.1.0 x
  run claude_plugin_maybe_outdated semver@m
  [ "$status" -eq 0 ]
}

@test "prefilter: fonte relativa sem versão compara com o HEAD do marketplace" {
  _installed rel@m "$HEAD12" x
  run claude_plugin_maybe_outdated rel@m
  [ "$status" -eq 1 ]
  _installed rel@m 0123456789ab x
  run claude_plugin_maybe_outdated rel@m
  [ "$status" -eq 0 ]
}

@test "prefilter: fonte git com sha fixado compara com o gitCommitSha" {
  _installed pinned@m 1.0.0 aaaaaaaa1111
  run claude_plugin_maybe_outdated pinned@m
  [ "$status" -eq 1 ]
  _installed pinned@m 1.0.0 bbbbbbbb2222
  run claude_plugin_maybe_outdated pinned@m
  [ "$status" -eq 0 ]
}

@test "prefilter: plugin fora do marketplace ou marketplace desconhecido => chama o update" {
  _installed sumiu@m 1.0.0 x
  run claude_plugin_maybe_outdated sumiu@m
  [ "$status" -eq 0 ]
  _installed explicit@outro 2.0.0 x
  run claude_plugin_maybe_outdated explicit@outro
  [ "$status" -eq 0 ]
}

@test "prefilter: sem instalação em escopo user => chama o update" {
  printf '{"plugins":{"explicit@m":[{"scope":"project","version":"2.0.0"}]}}' >"$P/installed_plugins.json"
  run claude_plugin_maybe_outdated explicit@m
  [ "$status" -eq 0 ]
}

# ── integração com update_claude_plugins ──────────────────────────────────────
_stub_claude() {
  has() { [[ "$1" == claude || "$1" == jq ]]; }
  run_network_cmd() { "$@"; }
  timeout() { shift; "$@"; }
  log() { printf '%s\n' "$*"; }
  export CALLS="$BATS_TEST_TMPDIR/calls"; : >"$CALLS"
  claude() {
    case "$*" in
      *"marketplace update"*) echo ok ;;
      *"plugin list --json"*) echo '[{"id":"explicit@m","scope":"user"},{"id":"semver@m","scope":"user"}]' ;;
      *"plugin update"*) echo "$*" >>"$CALLS"; echo '{"outcome":"ok","updateOutcome":"already-latest"}' ;;
    esac
  }
  CLAUDE_CLI_NOHOOKS=(claude)
  printf '{"plugins":{"explicit@m":[{"scope":"user","version":"2.0.0"}],"semver@m":[{"scope":"user","version":"1.1.0"}]}}' >"$P/installed_plugins.json"
}

@test "update_claude_plugins: só chama a CLI no plugin divergente" {
  _stub_claude
  run update_claude_plugins
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
  grep -q 'plugin update semver@m' "$CALLS"
  [[ "$output" == *"Pré-filtro: 1 plugin(s) idêntico(s) ao marketplace; 1 para conferir"* ]]
  [[ "$output" == *"0 atualizado(s), 2 já na última versão (2 em escopo user)"* ]]
}

@test "update_claude_plugins: CLAUDE_PLUGIN_PREFILTER=0 chama a CLI em todos" {
  _stub_claude
  CLAUDE_PLUGIN_PREFILTER=0 run update_claude_plugins
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 2 ]
}
