#!/usr/bin/env bats
# tests/core_cov.bats — caminhos de lib/core.sh que dependem do runtime: o
# timeout de run_step (mata a árvore do step e libera o lock do pacman), deps de
# comando ausentes, gate de rede sem espera, modo verbose e contador com total;
# recuperação de clone git (stash/reset/pop) com git simulado; sha256 sem
# sha256sum; gate de rede com cache; e helpers pequenos.

load test_helper

setup() {
  load_libs
  GITHUB_TOKEN_FILE="$BATS_TEST_TMPDIR/nao-existe"
  STEP_NAMES=(); STEP_RESULTS=(); STEP_TIMES=(); STEP_REASONS=(); STEP_CATEGORIES=()
  TOTAL_STEPS=0 QUIET=0 LOG_FILE=/dev/null
  write_step_event_json() { :; }
}

# Linha de catálogo falsa para o step "X": categoria|tags|efeito|timeout|deps|func|desc.
_catalog() { CAT_LINE="$1"; catalog_info_for_step() { printf '%s\n' "$CAT_LINE"; }; }

# ── run_step ──────────────────────────────────────────────────────────────────

@test "run_step: dependência de comando ausente vira skip" {
  _catalog "tools||read-only|0|sh, comando-que-nao-existe-xyz||f|d"
  _impl() { echo rodou; }
  run_step "X" _impl
  [ "${STEP_RESULTS[-1]}" = "skip" ]
  [ "${STEP_REASONS[-1]}" = "cmd-ausente: comando-que-nao-existe-xyz" ]
}

@test "run_step: sem rede e espera já gasta antes; verbose; warn e contador com total" {
  _catalog "tools|network|read-only|0||f|d"
  network_gate_ready() { NETWORK_GATE_WAITED=0; return 1; }
  run_step "X" true
  [ "${STEP_REASONS[-1]}" = "sem conectividade (rede ainda fora; espera já feita em step anterior)" ]
  _catalog "tools||read-only|0||f|d"
  _warn() { return "$RC_WARN"; }
  TOTAL_STEPS=12 VERBOSE=1
  out="$(run_step "Y" _warn arg1; printf '|%s' "${STEP_RESULTS[-1]}")"
  [[ "$out" == *"[verbose] func: f | args: _warn arg1"* ]]
  [[ "$out" == *"/12]"* ]]
  [[ "$out" == *"|warn" ]]
}

@test "run_step: timeout mata a árvore do step e libera o lock do pacman" {
  _catalog "pacman|pacman|mutating|1||f|d"
  pacman_release_stale_lock() { echo liberou > "$BATS_TEST_TMPDIR/lock"; }
  _lento() { sleep 30 & wait; }
  SECONDS=0
  # Como em produção (sem errexit): o `wait` do subshell morto devolve 143.
  set +e
  run_step "X" _lento
  set -e
  (( SECONDS < 15 ))
  [ "${STEP_RESULTS[-1]}" = "warn" ]
  [ "${STEP_REASONS[-1]}" = "tempo esgotado: limite de 1s do catálogo" ]
  [ "$(cat "$BATS_TEST_TMPDIR/lock")" = liberou ]
}

@test "step_time_left: sem prazo, prazo futuro e vencido" {
  STEP_DEADLINE=0
  [ -z "$(step_time_left)" ]
  STEP_DEADLINE=$(( SECONDS + 100 ))
  (( $(step_time_left) >= 99 ))
  SECONDS=100; STEP_DEADLINE=95
  [ "$(step_time_left)" = 0 ]
}

# ── gate de rede ──────────────────────────────────────────────────────────────

@test "network_gate_ready: primeira sonda com rede grava o cache" {
  NETWORK_GATE_CACHE_STATE=""
  network_probe() { return 0; }
  network_gate_ready
  [ "$NETWORK_GATE_CACHE_STATE" = up ]
}

# ── git_recover_plugin_repo (git simulado) ───────────────────────────────────

# git falso: refs/stash muda depois do push quando STASHED=1; reset/pop/push
# respondem com os rc pedidos.
_fake_git() {
  git_has_local_work() { return 1; }
  git() {
    shift 2
    case "$1 ${2:-}" in
      "symbolic-ref --quiet") echo refs/remotes/origin/main ;;
      "rev-parse -q") [[ -e "$BATS_TEST_TMPDIR/pushed" && "${STASHED:-1}" == 1 ]] && echo depois || echo antes ;;
      "stash push") touch "$BATS_TEST_TMPDIR/pushed"; return "${PUSH_RC:-0}" ;;
      "reset --hard") return "${RESET_RC:-0}" ;;
      "stash pop") echo pop >> "$BATS_TEST_TMPDIR/calls"; return "${POP_RC:-0}" ;;
      "checkout -f"|"reset --quiet") echo "$1" >> "$BATS_TEST_TMPDIR/calls" ;;
    esac
  }
}

@test "git_recover: stash falho, reset falho devolve o stash e pop conflitado restaura a árvore" {
  _fake_git
  PUSH_RC=1 run git_recover_plugin_repo /x p
  [ "$status" -eq 1 ]
  rm -f "$BATS_TEST_TMPDIR/pushed"
  RESET_RC=1 run git_recover_plugin_repo /x p
  [ "$status" -eq 1 ]
  grep -qx pop "$BATS_TEST_TMPDIR/calls"
  rm -f "$BATS_TEST_TMPDIR/pushed" "$BATS_TEST_TMPDIR/calls"
  POP_RC=1 run git_recover_plugin_repo /x p
  [ "$output" = "conflict origin/main" ]
  grep -qx checkout "$BATS_TEST_TMPDIR/calls"
}

# ── helpers pequenos ──────────────────────────────────────────────────────────

@test "helpers: versões iguais, coredump fora da lista, espaço livre e sha256 sem sha256sum" {
  [ "$(version_compare 1.2.3 1.2.3)" = 0 ]
  COREDUMP_IGNORE_EXE="ffmpeg*" run coredump_exe_is_ignored /usr/bin/vlc
  [ "$status" -eq 1 ]
  [[ "$(avail_kib_for_path /)" =~ ^[0-9]+$ ]]
  f="$BATS_TEST_TMPDIR/f"; echo abc > "$f"
  want="$(sha256sum "$f" | awk '{print $1}')"
  has() { [[ "$1" != sha256sum ]] && command -v "$1" >/dev/null 2>&1; }
  shasum() { sha256sum "${@: -1}"; }
  [ "$(file_sha256 "$f")" = "$want" ]
  has() { return 1; }
  run file_sha256 "$f"
  [ "$status" -eq 1 ]
}

@test "capture_installed_pkgs: grava a lista ordenada do pacman" {
  has() { [[ "$1" == pacman ]]; }
  pacman() { printf 'zsh 5.9-1\nbash 5.3-1\n'; }
  DRY_RUN=0
  capture_installed_pkgs "$BATS_TEST_TMPDIR/pkgs"
  [ "$(head -1 "$BATS_TEST_TMPDIR/pkgs")" = "bash 5.3-1" ]
}

@test "_log_to_terminal: mensagem longa com quebra embutida sai como veio" {
  COLUMNS=40
  msg="$(printf 'linha um bem comprida que passa da largura do terminal\nlinha dois')"
  run _log_to_terminal "$msg"
  [ "$output" = "$msg" ]
}

# Regressão: com o snapshot "antes" vazio, `FNR == NR` também valia no segundo
# arquivo e todos os pacotes instalados apareciam como removidos.
@test "pkg_diff: antes vazio lista tudo como instalado, não removido" {
  : > "$BATS_TEST_TMPDIR/antes"
  printf 'bash 5.3-1\nzsh 5.9-1\n' > "$BATS_TEST_TMPDIR/depois"
  run pkg_diff "$BATS_TEST_TMPDIR/antes" "$BATS_TEST_TMPDIR/depois"
  [ "$output" = $'I bash 5.3-1\nI zsh 5.9-1' ]
}

@test "pkg_diff: o mesmo arquivo dos dois lados não gera diferença" {
  printf 'bash 5.3-1\n' > "$BATS_TEST_TMPDIR/igual"
  run pkg_diff "$BATS_TEST_TMPDIR/igual" "$BATS_TEST_TMPDIR/igual"
  [ -z "$output" ]
}
