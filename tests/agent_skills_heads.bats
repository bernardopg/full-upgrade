#!/usr/bin/env bats
# tests/agent_skills_heads.bats — U16: o skills CLI só roda quando alguma fonte
# git das skills ganhou commit ou o lock mudou. git ls-remote, npx e npm são
# stubs; o estado fica em $BATS_TEST_TMPDIR.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  command -v jq >/dev/null || skip "jq ausente"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.agents/skills" "$XDG_STATE_HOME/skills"
  LOCK="$XDG_STATE_HOME/skills/.skill-lock.json"
  cat >"$LOCK" <<'JSON'
{"version":3,"skills":{
  "a":{"source":"o/a","sourceUrl":"https://github.com/o/a.git"},
  "b":{"source":"o/a","sourceUrl":"https://github.com/o/a.git"},
  "c":{"source":"o/c","sourceUrl":"https://github.com/o/c.git"}}}
JSON
  LOG_FILE=/dev/null
  export CALLS="$BATS_TEST_TMPDIR/npx.calls"
  : >"$CALLS"
  log() { printf '%s\n' "$*"; }
  has() { [[ "$1" == npx || "$1" == jq || "$1" == git ]]; }
  agent_skills_git_ff() { :; }
  with_updater_github_token() { "$@"; }
  timeout() { shift; "$@"; }
  npm() { [[ "$*" == 'view skills version' ]] && echo 1.7.4; }
  npx() { echo "$2" >>"$CALLS"; echo '✓ All global skills are up to date'; }
  export HEAD_A=1111111111111111111111111111111111111111
  git() {
    [[ "$1" == ls-remote ]] || return 1
    case "$2" in
      *o/a.git) printf '%s\tHEAD\n' "$HEAD_A" ;;
      *o/c.git) printf '%s\tHEAD\n' 2222222222222222222222222222222222222222 ;;
    esac
  }
}

@test "agent_skills_source_urls: URLs únicas e ordenadas" {
  run agent_skills_source_urls "$LOCK"
  [ "$output" = "$(printf 'https://github.com/o/a.git\nhttps://github.com/o/c.git')" ]
}

@test "agent_skills_source_heads: uma linha por fonte" {
  run agent_skills_source_heads "$LOCK"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "https://github.com/o/a.git 1111"* ]]
}

@test "agent_skills_source_heads: fonte sem resposta => rc 1" {
  git() { return 128; }
  run agent_skills_source_heads "$LOCK"
  [ "$status" -ne 0 ]
}

@test "agent_skills_source_heads: skill sem sourceUrl => rc 1" {
  printf '{"skills":{"a":{"sourceUrl":"https://github.com/o/a.git"},"local":{"source":"./x"}}}' >"$LOCK"
  run agent_skills_source_heads "$LOCK"
  [ "$status" -ne 0 ]
}

@test "agent_skills_fingerprint: muda com a HEAD e com o lock" {
  local f1 f2 f3
  f1="$(agent_skills_fingerprint "h1" "$LOCK")"
  f2="$(agent_skills_fingerprint "h2" "$LOCK")"
  echo ' ' >>"$LOCK"
  f3="$(agent_skills_fingerprint "h1" "$LOCK")"
  [ "$f1" != "$f2" ]
  [ "$f1" != "$f3" ]
  [[ "$f1" =~ ^[0-9a-f]{64}$ ]]
}

@test "update_agent_skills: primeiro run chama o CLI e grava o fingerprint" {
  run update_agent_skills
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
  [ -s "$(agent_skills_heads_file)" ]
}

@test "update_agent_skills: nada mudou => não chama o CLI" {
  update_agent_skills >/dev/null
  : >"$CALLS"
  run update_agent_skills
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma das 2 fonte(s) mudou"* ]]
  [ ! -s "$CALLS" ]
}

@test "update_agent_skills: commit novo numa fonte => chama o CLI de novo" {
  update_agent_skills >/dev/null
  : >"$CALLS"
  export HEAD_A=3333333333333333333333333333333333333333
  run update_agent_skills
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "update_agent_skills: falha do CLI não grava fingerprint" {
  npx() { echo "$2" >>"$CALLS"; return 1; }
  run update_agent_skills
  [ "$status" -eq "$RC_WARN" ]
  [ ! -e "$(agent_skills_heads_file)" ]
}
