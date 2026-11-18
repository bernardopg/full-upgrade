#!/usr/bin/env bats
# tests/cleanup_cov.bats — limpezas: relatórios além de MAX_LOGS, journal,
# coredumps, cache AUR sem `du`, prompts de snapshots (snapper/Timeshift) e de
# órfãos num pseudo-terminal, e órfãos que sobram depois das rodadas.
# PATH isolado; sudo só executa o stub seguinte.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/cleanup.sh"
  source "${FU_LIB}/steps/pacman.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=0 STEP_REASON="" ASSUME_YES=1
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}

# ── relatórios e journal ─────────────────────────────────────────────────────

@test "relatórios: diretório ausente, dentro do limite e excedentes removidos" {
  LOG_DIR="$BATS_TEST_TMPDIR/nao-existe"
  run cleanup_old_reports
  [[ "$output" == *"não existe; nada a limpar"* ]]
  LOG_DIR="$BATS_TEST_TMPDIR/logs"; mkdir -p "$LOG_DIR"
  rotate_logs() { :; }
  touch "$LOG_DIR/full-upgrade-20261101-000000-1.log"
  run cleanup_old_reports
  [[ "$output" == *"dentro do limite"* ]]
  rotate_logs() { rm -f "$LOG_DIR"/*.log; }
  MAX_LOGS=20 run cleanup_old_reports
  [[ "$output" == *"Removidos 1 arquivo(s) de run(s) além dos 20 mais recentes"* ]]
}

@test "journal: sem journalctl e vacuum com sudo" {
  run cleanup_journal
  [[ "$output" == *"journalctl não encontrado"* ]]
  stub journalctl 0 ""
  run cleanup_journal
  [ "$status" -eq 0 ]
  [ "$(stub_calls journalctl)" = "--vacuum-time=2weeks --vacuum-size=500M" ]
}

# ── coredumps e cache AUR ─────────────────────────────────────────────────────

@test "coredumps: diretório ausente e remoção sem tamanho legível" {
  stub coredumpctl 0 ""
  COREDUMP_DIR="$BATS_TEST_TMPDIR/nao-existe" run cleanup_old_coredumps
  [[ "$output" == *"não existe; nada a limpar"* ]]
  export COREDUMP_DIR="$BATS_TEST_TMPDIR/cd"; mkdir -p "$COREDUMP_DIR"
  touch -d '30 days ago' "$COREDUMP_DIR/core.x.zst"
  stub du 1 ""
  run cleanup_old_coredumps
  [ "$status" -eq 0 ]
  [[ "$output" == *"Coredumps antigos removidos: 1 arquivo(s)."* ]]
  [ ! -e "$COREDUMP_DIR/core.x.zst" ]
}

@test "cache AUR: sem du o relatório só diz limpo" {
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$XDG_CACHE_HOME/paru/clone/foo"
  touch "$XDG_CACHE_HOME/paru/clone/foo/foo-1-x86_64.pkg.tar.zst"
  stub du 1 ""
  run cleanup_aur_cache
  [[ "$output" == *"/paru/clone: limpo."* ]]
  [ ! -e "$XDG_CACHE_HOME/paru/clone/foo/foo-1-x86_64.pkg.tar.zst" ]
}

# ── snapshots ─────────────────────────────────────────────────────────────────

_snapper() {
  stub_script snapper 'case "$*" in
    "-c root list --csvout") printf "%s\n" "#,Type,Pre,Date,User,Description" "\"1\",s,,d,r,\"full-upgrade pré-upgrade\"" "\"3\",s,,d,r,\"full-upgrade pré-upgrade\"" ;;
  esac'
}

_timeshift() {
  stub_script timeshift 'case "$*" in
    --list) printf "%s\n" "0    >  2026-11-10_10-00-00  O     full-upgrade pré-upgrade" "1    >  2026-11-15_10-00-00  O     full-upgrade pré-upgrade" ;;
  esac'
}

@test "snapshots: snapper e Timeshift sem nada a remover" {
  SNAPSHOT_KEEP=5
  _snapper
  SNAPSHOT_TOOL=snapper run cleanup_old_snapshots
  [[ "$output" == *"Nenhum snapshot snapper full-upgrade antigo"* ]]
  _timeshift
  SNAPSHOT_TOOL=timeshift run cleanup_old_snapshots
  [[ "$output" == *"Nenhum snapshot timeshift full-upgrade antigo"* ]]
}

@test "snapshots: Timeshift sem --yes e sem TTY não remove" {
  _timeshift
  ASSUME_YES=0 SNAPSHOT_KEEP=1 SNAPSHOT_TOOL=timeshift run cleanup_old_snapshots </dev/null
  [[ "$output" == *"não interativa sem --yes"* ]]
  ! grep -q -- "--delete" "$STUB_LOG"
}

@test "snapshots: prompts do snapper e do Timeshift recusados e aceitos" {
  _snapper; _timeshift
  local env="ASSUME_YES=0 SNAPSHOT_KEEP=1"
  pty_call "steps/cleanup.sh" "$env SNAPSHOT_TOOL=snapper cleanup_old_snapshots" 'n\r'
  [[ "$output" == *"Remover estes snapshots snapper?"* ]]
  [[ "$output" == *"cancelada pelo usuário"* ]]
  pty_call "steps/cleanup.sh" "$env SNAPSHOT_TOOL=snapper cleanup_old_snapshots" 's\r'
  grep -q "^snapper -c root delete 1" "$STUB_LOG"
  pty_call "steps/cleanup.sh" "$env SNAPSHOT_TOOL=timeshift cleanup_old_snapshots" 'n\r'
  [[ "$output" == *"Remover estes snapshots timeshift?"* ]]
  pty_call "steps/cleanup.sh" "$env SNAPSHOT_TOOL=timeshift cleanup_old_snapshots" 's\r'
  grep -q "^timeshift --delete --snapshot 2026-11-10_10-00-00" "$STUB_LOG"
}

# ── órfãos ────────────────────────────────────────────────────────────────────

@test "órfãos: nenhum, prompt recusado/aceito e sem TTY" {
  stub pacman 0 ""
  run cleanup_orphans
  [[ "$output" == *"Nenhum pacote órfão encontrado"* ]]
  stub_script pacman 'case "$1" in -Qdtq) [[ -e "$STUB_LOG.removido" ]] || echo libfoo ;; -Rns) touch "$STUB_LOG.removido" ;; esac'
  stub pacman-conf 0 "$BATS_TEST_TMPDIR/db/"
  ASSUME_YES=0 run cleanup_orphans </dev/null
  [[ "$output" == *"não interativa sem --yes"* ]]
  pty_call "steps/pacman.sh steps/cleanup.sh" "ASSUME_YES=0 cleanup_orphans" 'n\r'
  [[ "$output" == *"Remover pacotes órfãos?"* ]]
  [[ "$output" == *"cancelada pelo usuário"* ]]
  pty_call "steps/pacman.sh steps/cleanup.sh" "ASSUME_YES=0 cleanup_orphans" 's\r'
  [[ "$output" == *"nenhuma dependência órfã remanescente"* ]]
}

@test "órfãos: sobram depois do limite de rodadas viram TODO" {
  stub pacman-conf 0 "$BATS_TEST_TMPDIR/db/"
  stub_script pacman 'case "$1" in -Qdtq) echo libteimosa ;; esac'
  ORPHAN_CLEANUP_MAX_ROUNDS=2 cleanup_orphans >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "órfãos remanescentes após 2 rodada(s)" ]
  [ "$(stub_calls pacman | grep -c -- '-Rns')" -eq 2 ]
}
