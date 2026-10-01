#!/usr/bin/env bats
load test_helper
setup() {
  load_libs
  source "$FU_LIB/steps/lang_rust.sh"
  source "$FU_LIB/steps/lang_other.sh"
  source "$FU_LIB/steps/doctor/packages.sh"
  source "$FU_LIB/steps/preflight.sh"
  source "$FU_LIB/tray.sh"
  QUIET=0
  JSONL_FILE="$BATS_TEST_TMPDIR/events.jsonl"
  LOG_DIR="$BATS_TEST_TMPDIR"
  LOG_FILE="$LOG_DIR/test.log"
  CARGO_HOME="$LOG_DIR/cargo"
}

@test "log_raw preserva JSON escapado e remove apenas ANSI" {
  local data='{"text":"linha\nnova","path":"C:\\temp"}'
  log_raw $'\e[31m'"$data"$'\e[0m'
  [ "$(cat "$LOG_FILE")" = "$data" ]
  python3 -m json.tool "$LOG_FILE" >/dev/null
}

@test "risco Rust inclui unsound mesmo permitido, sem misturar yanked" {
  run parse_cargo_risk_bins <<'EOF'
Crate: faster-hex
Warning: unsound
warning: 1 allowed warning found in /tmp/bin/cargo-audit
Crate: libssh2-sys
Warning: yanked
warning: 1 allowed warning found in /tmp/bin/cargo-update
error: 2 vulnerabilities found in /tmp/bin/rustup
EOF
  [ "$output" = $'cargo-audit\nrustup' ]
}

@test "auditoria Rust não vira OK com erro operacional ou cobertura incompleta" {
  mkdir -p "$CARGO_HOME/bin"
  touch "$CARGO_HOME/bin/testbin"; chmod +x "$CARGO_HOME/bin/testbin"
  cargo() { printf 'error: advisory database damaged\n'; return 1; }
  run audit_cargo_bins
  [ "$status" -eq "$RC_WARN" ]
  cargo() { printf "warning: testbin was not built with 'cargo auditable', the report will be incomplete\n"; }
  run audit_cargo_bins
  [ "$status" -eq "$RC_WARN" ]
}

@test "memo Rust não oculta riscos nem dispensa rebuild após advisory DB mudar" {
  mkdir -p "$CARGO_HOME/advisory-db"
  git -C "$CARGO_HOME/advisory-db" init -q
  git -C "$CARGO_HOME/advisory-db" -c user.name=Test -c user.email=test@example.invalid commit -qm initial --allow-empty
  _rust_rebuild_memo_record cargo-audit 0.22.2
  _rust_rebuild_memo_skip cargo-audit 0.22.2
  git -C "$CARGO_HOME/advisory-db" -c user.name=Test -c user.email=test@example.invalid commit -qm new --allow-empty
  run _rust_rebuild_memo_skip cargo-audit 0.22.2
  [ "$status" -eq 1 ]
  AUTO_FIX_RUST_CVES=1 ASSUME_YES=1
  _rust_collect_vuln_bins() { printf 'cargo-audit\n'; }
  _rust_run_capture() { printf 'No packages need updating.\n'; }
  has() { return 0; }
  cargo() { printf 'cargo-audit v0.22.2:\n    cargo-audit\n'; }
  _rust_rebuild_memo_record cargo-audit 0.22.2
  run_logged() { return 99; }
  run autofix_rust_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"pulando o rebuild"* ]]
}

@test "skip dinâmico ajusta total; skip solicitado não desconta duas vezes" {
  TOTAL_STEPS=3
  step_skip "Atualizar RTK" "cmd-ausente: rtk" >/dev/null
  [ "$TOTAL_STEPS" -eq 2 ]
  add_skip_step "Validar sudo"
  step_skip "Validar sudo" "FULL_UPGRADE_SKIP" >/dev/null
  [ "$TOTAL_STEPS" -eq 2 ]
}

@test "Go e Muse compartilham cobertura com inventário" {
  go() { printf '\tpath\texample.org/tool/cmd/cli\n\tmod\texample.org/tool\tv1.2.3\n'; }
  [ "$(go_tool_module fake)" = example.org/tool/cmd/cli ]
  go() { printf '\tpath\tcommand-line-arguments\n\tmod\tlocal\t(devel)\n'; }
  run go_tool_module fake
  [ "$status" -eq 1 ]
  [ "$(_manual_apps_kind muse-bin-1.4.2-R4684.1)" = covered ]
}

@test "run externo publica início e fim no tray sem consultar rede" {
  TRAY_STATE_FILE="$LOG_DIR/state.json"
  XDG_RUNTIME_DIR="$LOG_DIR"
  FU_RUN_LOCK_FILE="$LOG_DIR/full-upgrade.lock"
  printf '{"state":"idle","repo":1,"aur":0,"flatpak":0,"checked_at":"old","repo_updates":["pkg 1 -> 2"]}' > "$TRAY_STATE_FILE"
  tray_gather_updates_detail() { touch "$LOG_DIR/network"; return 99; }
  DRY_RUN=0
  acquire_run_lock >/dev/null
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" state)" = running ]
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" repo_updates)" = '["pkg 1 -> 2"]' ]
  release_run_lock
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" state)" = updates ]
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" checked_at)" = old ]
  [ ! -e "$LOG_DIR/network" ]
}

@test "tray Python valida detalhes completos e publicação externa" {
  run python3 "$FU_ROOT/tests/tray_appindicator.py"
  [ "$status" -eq 0 ]
}

@test "Mason executa atualização seletiva e propaga erro do registro" {
  command -v nvim >/dev/null || skip "Neovim indisponível"
  run python3 "$FU_ROOT/tests/editor_mason.py"
  [ "$status" -eq 0 ]
}

@test "rebuild auditable usa fonte isolada e o mesmo lock para metadata e build" {
  local cached="$CARGO_HOME/registry/src/test/demo-1.0.0"
  mkdir -p "$cached"
  printf '[package]\nname="demo"\nversion="1.0.0"\n' > "$cached/Cargo.toml"
  printf 'old\n' > "$cached/Cargo.lock"
  mkdir -p "$CARGO_HOME/bin"
  cargo() { printf 'demo v1.0.0:\n    demo\n'; }
  has() { [[ "$1" == cargo-auditable ]]; }
  run_logged() {
    if [[ "$2" == update ]]; then
      printf 'fresh\n' > "${4%/*}/Cargo.lock"
    else
      [[ "$*" == 'cargo auditable build --release --locked --manifest-path '* ]] || return 99
      [ "$(cat "${7%/*}/Cargo.lock")" = fresh ] || return 98
      mkdir -p "${7%/*}/target/release"
      printf '#!/bin/sh\nexit 0\n' > "${7%/*}/target/release/demo"
      chmod +x "${7%/*}/target/release/demo"
      printf '%s' "${7%/*}" > "$LOG_DIR/rebuild-path"
    fi
  }
  _rust_rebuild_crate demo 1.0.0
  [ "$(cat "$cached/Cargo.lock")" = old ]
  [ ! -e "$(cat "$LOG_DIR/rebuild-path")" ]
  [ -x "$CARGO_HOME/bin/demo" ]
}

@test "consulta de updates não sobrescreve resumo novo publicado enquanto aguardava rede" {
  TRAY_STATE_FILE="$LOG_DIR/state.json"
  tray_is_full_upgrade_running() { return 1; }
  tray_gather_updates_detail() { touch "$LOG_DIR/new-summary"; printf '0 0 0'; }
  tray_last_summary_counts() { [ -e "$LOG_DIR/new-summary" ] && printf '0 1 0' || printf '0 0 0'; }
  tray_last_summary_line() { return 1; }
  tray_last_doctor_pending_items() { :; }
  tray_check_now no_notify >/dev/null
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" state)" = error ]
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" fail)" = 1 ]
}
