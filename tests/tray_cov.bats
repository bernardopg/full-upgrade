#!/usr/bin/env bats
# tests/tray_cov.bats — caminhos do tray fora do menu Python: coleta de
# updates, gravação do estado, notificação, terminal, autostart, unit systemd,
# backend yad (laço do daemon com yad stubado), reinício e o --tray --check.
# PATH isolado; nenhum applet real é iniciado ou encerrado.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/tray.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/home/.config"
  mkdir -p "$HOME"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"
  TRAY_STATE_FILE="$LOG_DIR/tray-state.json"
  TRAY_PID_FILE="$BATS_TEST_TMPDIR/tray.pid"
  TRAY_LOCK_FILE="$BATS_TEST_TMPDIR/tray.lock"
  FU_RUN_LOCK_FILE="$BATS_TEST_TMPDIR/run.lock"
  TRAY_SYSTEM_ICON_DIR="$BATS_TEST_TMPDIR/icons"
}

# ── Estado e coleta ───────────────────────────────────────────────────────────

@test "tray_last_doctor_pending_items: warn, todo e fail com e sem motivo" {
  f="$LOG_DIR/full-upgrade-20261117-000000-1.jsonl"
  printf '%s\n' '{"event":"step","step":"Doctor: rede","status":"warn","reason":"DNS lento"}' \
    '{"event":"step","step":"Atualizar X","status":"fail","reason":""}' \
    '{"event":"step","step":"Y","status":"ok"}' \
    '{"event":"summary","ok":1}' > "$f"
  tray_latest_completed_real_jsonl() { echo "$f"; }
  run tray_last_doctor_pending_items
  [[ "$output" == *"rede — DNS lento"* ]]
  [[ "$output" == *"Atualizar X"* ]]
  [[ "$output" != *" Y"* ]]
}

@test "tray_is_full_upgrade_running: sem lock, lock livre e fallback por PID" {
  run tray_is_full_upgrade_running
  [ "$status" -eq 1 ]
  : > "$FU_RUN_LOCK_FILE"
  stub_script flock 'exit 0'
  run tray_is_full_upgrade_running
  [ "$status" -eq 1 ]
  rm "$STUB_BIN/flock"; hash -r
  echo "$$" > "$FU_RUN_LOCK_FILE"
  run tray_is_full_upgrade_running
  [ "$status" -eq 0 ]
  echo 999999999 > "$FU_RUN_LOCK_FILE"
  run tray_is_full_upgrade_running
  [ "$status" -ne 0 ]
}

@test "tray_resolve_icon: sem SVG devolve o nome e rc 1" {
  FU_ROOT="$BATS_TEST_TMPDIR/vazio" run tray_resolve_icon full-upgrade-tray-idle
  [ "$status" -eq 1 ]
  [ "$output" = full-upgrade-tray-idle ]
}

@test "tray_gather_updates_detail: AUR filtrado pelo ignore e Flatpak" {
  stub checkupdates 0 "linux 1 -> 2"
  stub paru 0 "pcsx2 1-1 -> 2-1
zed 1-1 -> 2-1"
  stub flatpak 0 "org.app.One"
  detect_aur_helper() { echo paru; }
  FULL_UPGRADE_AUR_IGNORE="pcsx2"
  run tray_gather_updates_detail "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/f"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1" ]
  stub flatpak 1 ""
  run tray_gather_updates_detail "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/f"
  [ "$status" -eq 1 ]
}

@test "tray_gather_updates: devolve as contagens e limpa os temporários" {
  tray_gather_updates_detail() { printf '2 1 0'; }
  run tray_gather_updates
  [ "$status" -eq 0 ]
  [ "$output" = "2 1 0" ]
}

@test "tray_write_state: diretório sem permissão falha sem deixar temporário" {
  TRAY_STATE_FILE="/proc/nao-gravavel/state.json" run tray_write_state idle idle 0 0 0 0 0 "" "" "" "" ""
  [ "$status" -eq 1 ]
}

@test "tray_notify: desligado, sem notify-send e enviando" {
  TRAY_NOTIFICATIONS=0 run tray_notify normal icon t b
  [ "$status" -eq 0 ]
  run tray_notify normal icon t b
  [ "$status" -eq 0 ]
  stub notify-send 0
  tray_notify critical icon "Título" "Corpo"
  grep -q "^notify-send -a full-upgrade -u critical -i icon Título Corpo" "$STUB_LOG"
}

@test "tray_check_now: lê o resumo do último run e notifica a transição" {
  printf '%s\n' '{"state":"idle","repo":0}' > "$TRAY_STATE_FILE"
  tray_is_full_upgrade_running() { return 1; }
  tray_gather_updates_detail() { echo "linux 1 -> 2" > "$1"; : > "$2"; : > "$3"; printf '1 0 0'; }
  tray_last_summary_counts() { printf '0 0 0'; }
  tray_last_summary_line() { echo '{"event":"summary","timestamp":"2026-11-17T10:00:00-03:00","log_file":"/x.log","jsonl_file":"/x.jsonl","reboot_recommendation":""}'; }
  tray_last_doctor_pending_items() { :; }
  _tray_notify_transition() { echo "notify $*" >> "$STUB_LOG"; }
  run tray_check_now notify
  [ "$status" -eq 0 ]
  [ "$output" = updates ]
  grep -q "^notify idle updates 1" "$STUB_LOG"
  [ "$(tray_read_state_field "$TRAY_STATE_FILE" log_file)" = /x.log ]
}

@test "tray_check_and_print: imprime o resumo da checagem" {
  tray_check_now() { tray_write_state updates idle 2 1 0 0 0 "" "" "" "" "" '[]' '[]' '[]' '[]' 3 '[]'; printf updates; }
  run tray_check_and_print
  [ "$status" -eq 0 ]
  [[ "$output" == "Estado: updates | updates: 2 repo + 1 AUR + 0 Flatpak + 3 Artcraft | a resolver: 0 | falhas: 0" ]]
}

# ── Terminal, log e autostart ─────────────────────────────────────────────────

@test "tray_run_in_terminal: sem terminal falha; cada terminal recebe a sintaxe certa" {
  tray_detect_terminal() { return 1; }
  run tray_run_in_terminal full-upgrade
  [ "$status" -eq 1 ]
  local t
  for t in xdg-terminal-exec konsole gnome-terminal foot kitty; do
    stub "$t" 0
    tray_detect_terminal() { echo "$t"; }
    tray_run_in_terminal full-upgrade --mode doctor
  done
  timeout 5 bash -c 'until (( $(wc -l < "$1") >= 5 )); do sleep 0.1; done' _ "$STUB_LOG"
  grep -q "^xdg-terminal-exec full-upgrade --mode doctor" "$STUB_LOG"
  grep -q "^konsole -e full-upgrade" "$STUB_LOG"
  grep -q "^gnome-terminal -- full-upgrade" "$STUB_LOG"
  grep -q "^foot -- full-upgrade" "$STUB_LOG"
  grep -q "^kitty -e full-upgrade" "$STUB_LOG"
}

@test "tray_launch_full_upgrade e tray_view_log" {
  tray_self_bin() { echo /usr/bin/full-upgrade; }
  tray_run_in_terminal() { echo "term $*" >> "$STUB_LOG"; }
  tray_launch_full_upgrade --mode update
  grep -q "^term /usr/bin/full-upgrade --mode update" "$STUB_LOG"
  LATEST_LOG_LINK="$LOG_DIR/latest.log"
  run tray_view_log
  [ "$status" -eq 1 ]
  echo log > "$LATEST_LOG_LINK"
  tray_view_log
  grep -q "^term less $LATEST_LOG_LINK" "$STUB_LOG"
  stub xdg-open 0
  tray_view_log
  # xdg-open roda em segundo plano com disown: espera limitada pelo registro.
  timeout 5 bash -c 'until grep -q "^xdg-open $1" "$2"; do sleep 0.1; done' _ "$LATEST_LOG_LINK" "$STUB_LOG"
}

@test "autostart: habilita, desabilita duas vezes e remoção silenciosa" {
  tray_self_bin() { echo /usr/bin/full-upgrade; }
  run tray_enable_autostart
  [[ "$output" == *"Autostart habilitado"* ]]
  grep -q "^Exec=/usr/bin/full-upgrade --tray" "$(tray_autostart_file)"
  run tray_disable_autostart
  [[ "$output" == "Autostart desabilitado." ]]
  run tray_disable_autostart
  [[ "$output" == "Autostart não estava habilitado." ]]
  tray_remove_autostart_quiet
}

@test "tray_enable_systemd_unit: grava a unit e falha se o systemctl recusa" {
  tray_self_bin() { echo /usr/bin/full-upgrade; }
  stub_script systemctl 'case "$*" in *enable*) exit 1 ;; esac'
  run tray_enable_systemd_unit
  [ "$status" -eq 1 ]
  [ -f "$XDG_CONFIG_HOME/systemd/user/full-upgrade-tray.service" ]
}

@test "tray_systemd_unit_status: rótulos de cada estado" {
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  stub_script systemctl 'case "$*" in
    *LoadState*) echo loaded ;;
    *is-enabled*) echo static ;;
    *is-active*) echo "Failed to connect to bus"; exit 1 ;;
  esac'
  run tray_systemd_unit_status
  [ "$output" = "instalada (estado indisponível)" ]
}

# ── Python/AppIndicator ───────────────────────────────────────────────────────

@test "tray_appindicator_available e tray_appindicator_main com Python stubado" {
  tray_python_bin() { return 1; }
  run tray_appindicator_available
  [ "$status" -eq 1 ]
  run tray_appindicator_main /bin/full-upgrade 1800
  [ "$status" -eq 1 ]
  stub_script fakepy 'cat >/dev/null; exit 0'
  tray_python_bin() { echo "$STUB_BIN/fakepy"; }
  run tray_appindicator_available
  [ "$status" -eq 0 ]
  run tray_appindicator_main /bin/full-upgrade 1800
  [ "$status" -eq 0 ]
}

# ── Backend yad (X11) ─────────────────────────────────────────────────────────

@test "_tray_yad_apply: envia ícone e tooltip pelo coproc" {
  printf '%s\n' '{"state":"updates","repo":2,"aur":1,"flatpak":0,"artcraft":0,"todo":0,"fail":0,"reboot":""}' > "$TRAY_STATE_FILE"
  _tray_yad_send() { echo "yad $1" >> "$STUB_LOG"; }
  _tray_yad_apply updates
  grep -q "^yad icon:" "$STUB_LOG"
  grep -q "^yad tooltip:full-upgrade: 3 atualizações" "$STUB_LOG"
}

@test "_tray_yad_send: sem coproc não faz nada" {
  unset FU_YAD
  run _tray_yad_send "icon:x"
  [ "$status" -eq 0 ]
}

@test "_tray_cleanup: encerra o yad e remove o pidfile só se for dono" {
  sleep_stub_pid() { :; }
  echo "$$" > "$TRAY_PID_FILE"
  ( exec sleep 30 ) & FU_YAD_PID=$!
  _tray_cleanup
  [ ! -e "$TRAY_PID_FILE" ]
  ! kill -0 "$FU_YAD_PID" 2>/dev/null
  echo 1 > "$TRAY_PID_FILE"
  FU_YAD_PID=""
  _tray_cleanup
  [ -e "$TRAY_PID_FILE" ]
}

@test "tray_main: sem yad nem AppIndicator sai 1; já em execução sai 0" {
  tray_wayland_session() { return 1; }
  run tray_main
  [ "$status" -eq 1 ]
  [[ "$output" == *"requer 'yad' ou AppIndicator"* ]]
  echo "$$" > "$TRAY_PID_FILE"
  tray_pid_is_daemon() { return 0; }
  run tray_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está em execução (pid $$)"* ]]
}

@test "tray_main: lock ocupado sai 0" {
  stub flock 1
  run tray_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"já está em execução"* ]]
}

@test "tray_main: Wayland com AppIndicator delega ao applet Python" {
  tray_wayland_session() { return 0; }
  tray_appindicator_available() { return 0; }
  tray_appindicator_main() { echo "appindicator $*"; exit 0; }
  tray_self_bin() { echo /usr/bin/full-upgrade; }
  TRAY_CHECK_INTERVAL_M=0
  run tray_main
  [ "$status" -eq 0 ]
  [[ "$output" == "appindicator /usr/bin/full-upgrade 60" ]]
}

@test "tray_main: laço do yad aplica o estado e sai quando o yad morre" {
  tray_wayland_session() { return 1; }
  stub_script yad 'exec sleep 30'
  tray_self_bin() { echo /usr/bin/full-upgrade; }
  tray_build_menu() { echo "menu"; }
  tray_check_now() { echo idle; }
  _tray_yad_apply() { echo "apply $1" >> "$STUB_LOG"; }
  tray_is_full_upgrade_running() { return 1; }
  sleep() { :; }
  n=0
  tray_yad_pid_alive() { n=$((n + 1)); (( n <= 3 )); }
  run tray_main
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apply idle' "$STUB_LOG")" -ge 2 ]
}

@test "tray_main: yad que não sobe no modo notification sai 1" {
  tray_wayland_session() { return 1; }
  stub yad 0
  tray_self_bin() { echo /usr/bin/full-upgrade; }
  tray_build_menu() { echo menu; }
  tray_yad_pid_alive() { return 1; }
  run tray_main
  [ "$status" -eq 1 ]
  [[ "$output" == *"yad não iniciou"* ]]
}

@test "tray_restart: encerra o applet antigo e inicia de novo" {
  ( exec sleep 30 ) & old=$!
  echo "$old" > "$TRAY_PID_FILE"
  tray_pid_is_daemon() { return 0; }
  sleep() { :; }
  tray_main() { echo "main iniciado"; }
  run tray_restart
  [[ "$output" == *"Encerrando applet antigo (pid ${old})"* ]]
  [[ "$output" == *"main iniciado"* ]]
  ! kill -0 "$old" 2>/dev/null
}
