#!/usr/bin/env bats
# tests/ai_cov.bats — ramos de falha e de versão nova dos CLIs de IA (Ollama,
# kilo, pi, kimi, droid, coderabbit, kiro, muse, jcode, helper check→apply), do
# skills CLI e do clone git de skills, e da limpeza de plugins bloqueados.
# PATH isolado: cada CLI é stub; run_network_cmd é trocado por um mapa de rc.

load test_helper
load stub_helper

setup() {
  GIT_REAL="$(type -P git)"
  load_libs
  source "${FU_LIB}/steps/ai.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$HOME"
  # Como em full-upgrade.sh: os `cmd | log_out` dependem do rc do comando.
  set -o pipefail
}

# run_network_cmd falso: rc em NET_RC_<n> pela ordem da chamada (default 0),
# saída em NET_OUT. Registra cada chamada em $BATS_TEST_TMPDIR/net.
_net() {
  echo 0 > "$BATS_TEST_TMPDIR/net.n"
  run_network_cmd() {
    local n; n=$(( $(cat "$BATS_TEST_TMPDIR/net.n") + 1 )); echo "$n" > "$BATS_TEST_TMPDIR/net.n"
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/net"
    local rcv="NET_RC_$n"
    printf '%s\n' "${NET_OUT:-}"
    return "${!rcv:-0}"
  }
}

# ── Ollama, kilo, pi, claude ─────────────────────────────────────────────────

@test "ollama: já na mais recente, instalador indisponível e instalador com erro" {
  export OLLAMA_SELF_UPDATE=1
  stub ollama 0 "ollama version is 0.5.0"
  stub curl 0 "https://github.com/ollama/ollama/releases/tag/v0.5.0"
  run update_ollama
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está na versão mais recente (0.5.0)"* ]]
  stub curl 0 "https://github.com/ollama/ollama/releases/tag/v0.6.0"
  fetch_network_text() { return 1; }
  run update_ollama
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"não foi possível obter o instalador"* ]]
  fetch_network_text() { echo 'exit 3'; }
  run update_ollama
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"instalador retornou erro"* ]]
}

@test "kilo: upgrade nativo falho e instalador oficial também falho" {
  stub kilo 0 "7.3.0"
  _opencode_style_upgrade() { STEP_REASON="kilo upgrade falhou"; return "$RC_WARN"; }
  fetch_network_text() { printf '#!/usr/bin/env bash\nexit 1\n'; }
  run update_kilo
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Instalador oficial do kilo falhou"* ]]
}

@test "pi: extensões sem rede, catálogo com timeout e com falha genérica" {
  stub pi 0 "0.9.0"
  _net
  NET_RC_2=$RC_WARN NET_RC_3=1 NET_OUT="Model catalog refresh timed out" run update_pi
  [[ "$output" == *"falha de rede ao atualizar extensões"* ]]
  [[ "$output" == *"timeout ao refrescar catálogos"* ]]
  _net
  NET_RC_3=2 NET_OUT="erro" run update_pi
  [[ "$output" == *"falha ao refrescar catálogos de modelos (rc=2)"* ]]
}

@test "claude: ausente do PATH é no-op" {
  run update_claude_code
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude não encontrado no PATH"* ]]
}

# ── kimi ──────────────────────────────────────────────────────────────────────

@test "kimi: prefixo estrangeiro sem rede; updater oficial sem rede e com falha" {
  stub kimi 0 "0.30.0"
  kimi_npm_package() { :; }
  kimi_foreign_npm_prefix() { echo "$BATS_TEST_TMPDIR/npm"; }
  stub npm 0 "0.31.0"
  _net
  NET_RC_1=$RC_WARN run update_kimi
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha de rede ao atualizar"* ]]
  kimi_foreign_npm_prefix() { :; }
  _net
  NET_RC_1=$RC_WARN update_kimi >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "rede indisponível para kimi update" ]
  _net; unset status
  NET_RC_1=1 update_kimi >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "kimi update falhou" ]
}

# ── skills CLI ────────────────────────────────────────────────────────────────

_skills_env() {
  mkdir -p "$HOME/.agents/skills"
  stub npx 0 ""
  agent_skills_git_ff() { :; }
  agent_skills_tracked_count() { echo 2; }
  agent_skills_source_heads() { return 1; }
  with_updater_github_token() { "$@"; }
  timeout() { shift; "$@"; }
  npm() { [[ "$*" == "view skills version" ]] && echo 1.7.5; return 0; }
}

@test "skills: sem tempo no catálogo, estouro sem versão boa e skills órfãs" {
  _skills_env
  step_time_left() { echo 10; }
  update_agent_skills >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "sem tempo no limite do catálogo para rodar o skills CLI" ]
  step_time_left() { :; }
  agent_skills_cli_previous_version() { :; }
  npx() { return 124; }
  unset status
  update_agent_skills >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "skills CLI excedeu 60s (skills@1.7.5)"* ]]
  npx() { printf 'Skills deleted upstream:\n  • velha\n'; }
  run update_agent_skills
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando 2 agent skill(s)"* ]]
  [[ "$output" == *"Skills sem upstream (não recebem mais update, mantidas): velha"* ]]
}

# ── clone git de skills ───────────────────────────────────────────────────────

_git_env() {
  ln -s "$GIT_REAL" "$STUB_SAFE/git"; hash -r
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  UP="$BATS_TEST_TMPDIR/up.git" WORK="$BATS_TEST_TMPDIR/w" DIR="$BATS_TEST_TMPDIR/skills"
  git init -q --bare "$UP"
  git clone -q "$UP" "$WORK" 2>/dev/null
  echo a > "$WORK/f"; git -C "$WORK" add f; git -C "$WORK" commit -qm a; git -C "$WORK" push -q origin main
  git clone -q "$UP" "$DIR"
}

@test "git_ff: upstream sumido vira TODO; fetch falho vira warn" {
  _git_env
  rm -rf "$UP"
  agent_skills_git_ff "$DIR" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "upstream do clone de skills em"*"inacessível" ]]
  git_fetch_full() { echo "fatal: erro desconhecido"; return 1; }
  unset status
  agent_skills_git_ff "$DIR" || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "fetch do clone de skills em"*"falhou" ]]
}

@test "git_ff: histórico divergente vira TODO sem reset" {
  _git_env
  echo b > "$WORK/f"; git -C "$WORK" commit -qam b; git -C "$WORK" push -q origin main
  echo c > "$DIR/g"; git -C "$DIR" add g; git -C "$DIR" commit -qm local
  agent_skills_git_ff "$DIR" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"divergiu de origin/main"* ]]
  [ -e "$DIR/g" ]
}

# ── plugins ───────────────────────────────────────────────────────────────────

@test "plugins: CLI desconhecido na blocklist e Claude sem plugins de usuário" {
  AI_PLUGIN_BLOCKLIST="x"
  run ai_plugin_purge_blocked outro
  [ "$status" -eq 0 ]
  AI_PLUGIN_BLOCKLIST=""
  stub claude 0 "[]"
  _net
  run update_claude_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum plugin do Claude Code em escopo user"* ]]
}

@test "codex: marketplace sem rede vira warn" {
  stub codex 0 ""
  AI_PLUGIN_BLOCKLIST=""
  _net
  NET_RC_1=$RC_WARN update_codex_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "rede indisponível para codex plugin marketplace upgrade" ]
}

# ── CLIs self-update ──────────────────────────────────────────────────────────

# CLI stub cuja versão muda depois do update: lê $BATS_TEST_TMPDIR/<nome>.ver.
_versioned() {
  echo "$2" > "$BATS_TEST_TMPDIR/$1.ver"
  stub_script "$1" "case \"\$1\" in --version) echo \"$1 \$(cat $BATS_TEST_TMPDIR/$1.ver)\" ;; *) echo $3 > $BATS_TEST_TMPDIR/$1.ver ;; esac"
}

@test "droid: update falho; coderabbit e kiro com versão nova" {
  stub droid 0 "droid 1.0"
  _net
  NET_OUT="update available" NET_RC_2=1 run update_droid
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao atualizar o droid"* ]]
  _versioned coderabbit 1.0 1.1
  run_network_cmd() { "$@"; }
  run update_coderabbit
  [[ "$output" == *"coderabbit atualizado: 1.0 → 1.1"* ]]
  _versioned kiro-cli 2.0 2.1
  run update_kiro_cli
  [[ "$output" == *"kiro-cli atualizado: 2.0 → 2.1"* ]]
}

@test "check→apply: check sem rede e update falho" {
  stub grok 0 "grok 1.0.0"
  _net
  NET_RC_1=1 run update_grok
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Não foi possível verificar atualização do grok"* ]]
  _net
  NET_OUT="new version available" NET_RC_2=1 run update_grok
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao atualizar o grok"* ]]
}

@test "muse: launcher falho vira warn" {
  stub muse 0 "muse 1.4.0"
  _net
  NET_RC_1=3 update_muse >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "muse (MUSE_LAUNCHER_INSTALL=1) falhou (rc=3)" ]
}

@test "jcode: release sem tag legível e update falho" {
  stub jcode 0 "jcode 0.4.0"
  stub curl 0 ""
  _net
  NET_OUT='{"name":"sem tag"}' run update_jcode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Não foi possível parsear a versão mais recente"* ]]
  _net
  NET_OUT='{"tag_name":"v0.5.0"}' NET_RC_2=1 run update_jcode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao atualizar o jcode"* ]]
}
