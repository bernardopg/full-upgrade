#!/usr/bin/env bats
# tests/claude_plugins.bats — atualização dos plugins do Claude Code. O `claude`
# é sempre stub: nada toca rede, marketplaces ou ~/.claude.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  STEP_REASON=""
  has() { [[ "$1" == claude ]]; }
  run_network_cmd() { "$@"; }
}

@test "claude_plugin_user_ids: só escopo user, sem duplicata" {
  run claude_plugin_user_ids <<<'[{"id":"a@m","scope":"user"},{"id":"b@m","scope":"local"},{"id":"a@m","scope":"user"},{"id":"c@m","scope":"synced"}]'
  [ "$output" = "a@m" ]
}

@test "claude_plugin_update_classify: updated, current, confirm e fail" {
  run claude_plugin_update_classify <<EOF2
a@m	{"outcome":"ok","updateOutcome":"updated","oldVersion":"1","newVersion":"2"}
b@m	{"outcome":"ok","updateOutcome":"already-latest"}
c@m	{"outcome":"needs-confirmation","shownCommand":{"sha256":"x"}}
d@m	{"outcome":"error","message":"boom"}
EOF2
  [ "${lines[0]}" = $'updated\ta@m\t1 → 2' ]
  [ "${lines[1]}" = $'current\tb@m\t' ]
  [ "${lines[2]}" = $'confirm\tc@m\t' ]
  [ "${lines[3]}" = $'fail\td@m\tboom' ]
}

@test "update_claude_plugins: comando de instalação alterado vira TODO sem -y" {
  claude() {
    case "$*" in
      "plugin marketplace update") echo ok ;;
      "plugin list --json") echo '[{"id":"x@m","scope":"user"}]' ;;
      "plugin update x@m --scope user --json") echo '{"outcome":"needs-confirmation","shownCommand":{"sha256":"s"}}' ;;
      *) echo "chamada inesperada: $*" >&2; return 9 ;;
    esac
  }
  update_claude_plugins || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"x@m"* ]]
}

@test "update_claude_plugins: falha no marketplace vira RC_WARN" {
  claude() { return 1; }
  run update_claude_plugins
  [ "$status" -eq "$RC_WARN" ]
}

# ── agent_skills_git_ff ───────────────────────────────────────────────────────
_skills_repos() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email t@t; git config --global user.name t
  git config --global init.defaultBranch main
  git init -q "$BATS_TEST_TMPDIR/up"
  git -C "$BATS_TEST_TMPDIR/up" commit -q --allow-empty -m one
  git clone -q "$BATS_TEST_TMPDIR/up" "$BATS_TEST_TMPDIR/skills"
  git -C "$BATS_TEST_TMPDIR/up" commit -q --allow-empty -m two
}

@test "agent_skills_git_ff: clone limpo atrás do upstream faz fast-forward" {
  _skills_repos
  agent_skills_git_ff "$BATS_TEST_TMPDIR/skills"
  [ "$(git -C "$BATS_TEST_TMPDIR/skills" log -1 --format=%s)" = two ]
}

@test "agent_skills_git_ff: clone sem upstream configurado usa origin/HEAD" {
  _skills_repos
  git -C "$BATS_TEST_TMPDIR/skills" branch --unset-upstream
  agent_skills_git_ff "$BATS_TEST_TMPDIR/skills"
  [ "$(git -C "$BATS_TEST_TMPDIR/skills" log -1 --format=%s)" = two ]
}

@test "agent_skills_git_ff: alteração local vira TODO e não mexe no clone" {
  _skills_repos
  echo x >"$BATS_TEST_TMPDIR/skills/f"; git -C "$BATS_TEST_TMPDIR/skills" add f
  agent_skills_git_ff "$BATS_TEST_TMPDIR/skills" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/skills" log -1 --format=%s)" = one ]
}

@test "agent_skills_git_ff: diretório sem git é no-op" {
  run agent_skills_git_ff "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

# ── update_codex_plugins ──────────────────────────────────────────────────────
@test "update_codex_plugins: nome divergente no upstream não vira aviso" {
  has() { [[ "$1" == codex ]]; }
  codex() { echo 'Failed to upgrade marketplace `claude-plugins-official`: failed to refresh plugin cache for x: plugin.json name `a` does not match marketplace plugin name `b`'; echo 'Error: 1 upgrade failure(s) occurred.'; }
  run update_codex_plugins
  [ "$status" -eq 0 ]
}

@test "update_codex_plugins: só falha de upstream com rc 1 não vira aviso" {
  has() { [[ "$1" == codex ]]; }
  codex() { echo 'Failed to upgrade marketplace `x`: plugin.json name `a` does not match marketplace plugin name `b`'; return 1; }
  run update_codex_plugins
  [ "$status" -eq 0 ]
}

@test "update_codex_plugins: outra falha com rc 0 vira RC_WARN" {
  has() { [[ "$1" == codex ]]; }
  codex() { echo 'Failed to upgrade marketplace `ponytail`: git fetch failed'; }
  update_codex_plugins || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *ponytail* ]]
}

@test "agent_skills_upstream_deleted: extrai as skills apagadas no upstream" {
  run agent_skills_upstream_deleted <<'EOF2'
Warning: The following skills from mattpocock/skills appear to have been deleted upstream:
  • qa
  • edit-article
Skipping deletion in non-interactive mode.
Warning: The following skills from x/y appear to have been deleted upstream:
  • qa
✓ All global skills are up to date
EOF2
  [ "$output" = "qa edit-article" ]
}
