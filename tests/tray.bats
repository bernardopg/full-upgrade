#!/usr/bin/env bats
# tests/tray.bats — funções puras do daemon do systray (lib/tray.sh).

load test_helper

setup() {
  load_libs
  # tray.sh só define funções em source-time; as puras testadas aqui não
  # dependem de detect_aur_helper/json_escape (ausentes neste shell).
  # shellcheck source=/dev/null
  source "${FU_LIB}/tray.sh"
}

@test "count_list: conta linhas não-vazias" {
  run tray_count_list <<'EOF'
foo
bar

baz
EOF
  [ "$output" = "3" ]
}

@test "count_list: vazio => 0" {
  result=$(printf '' | tray_count_list)
  [ "$result" = "0" ]
}

@test "total_updates: soma inteiros" {
  [ "$(tray_total_updates 3 5)" = "8" ]
  [ "$(tray_total_updates 3 5 2)" = "10" ]
  [ "$(tray_total_updates 0 0)" = "0" ]
}

@test "total_updates: ignora não-numéricos" {
  [ "$(tray_total_updates 3 "" 2)" = "5" ]
}

@test "extract_json_field: numérico" {
  local line='{"event":"summary","ok":80,"fail":2,"todo":1}'
  [ "$(tray_extract_json_field "$line" fail)" = "2" ]
  [ "$(tray_extract_json_field "$line" todo)" = "1" ]
  [ "$(tray_extract_json_field "$line" ok)" = "80" ]
}

@test "extract_json_field: string" {
  local line='{"state":"updates","reboot":"Kernel X"}'
  [ "$(tray_extract_json_field "$line" state)" = "updates" ]
  [ "$(tray_extract_json_field "$line" reboot)" = "Kernel X" ]
}

@test "extract_json_field: ausente => rc 1" {
  run tray_extract_json_field '{"a":1}' missing
  [ "$status" -eq 1 ]
}

@test "summary_counts: linha vazia => 0 0 0" {
  [ "$(tray_summary_counts "")" = "0 0 0" ]
}

@test "summary_counts: extrai todo/fail/reboot" {
  local line='{"event":"summary","todo":3,"fail":1,"reboot_recommendation":"Kernel atualizado"}'
  [ "$(tray_summary_counts "$line")" = "3 1 1" ]
}

@test "summary_counts: sem reboot => reboot flag 0" {
  local line='{"event":"summary","todo":0,"fail":0,"reboot_recommendation":""}'
  [ "$(tray_summary_counts "$line")" = "0 0 0" ]
}

@test "summary_has_reboot / reboot_reason" {
  local line='{"reboot_recommendation":"Kernel 6.6 atualizado"}'
  run tray_summary_has_reboot "$line"
  [ "$status" -eq 0 ]
  [ "$(tray_summary_reboot_reason "$line")" = "Kernel 6.6 atualizado" ]
}

@test "compute_state: running tem prioridade máxima" {
  [ "$(tray_compute_state 1 5 3 20)" = "running" ]
}

@test "compute_state: error > attention > updates > idle" {
  [ "$(tray_compute_state 0 1 3 20)" = "error" ]
  [ "$(tray_compute_state 0 0 3 20)" = "attention" ]
  [ "$(tray_compute_state 0 0 0 20)" = "updates" ]
  [ "$(tray_compute_state 0 0 0 0)" = "idle" ]
}

@test "compute_state: entradas inválidas viram 0" {
  [ "$(tray_compute_state 0 "" "" "")" = "idle" ]
  [ "$(tray_compute_state 0 "" 2 "")" = "attention" ]
}

@test "icon_name_for_state: mapeia todos os estados" {
  [ "$(tray_icon_name_for_state running)" = "full-upgrade-tray-running" ]
  [ "$(tray_icon_name_for_state error)" = "full-upgrade-tray-error" ]
  [ "$(tray_icon_name_for_state attention)" = "full-upgrade-tray-attention" ]
  [ "$(tray_icon_name_for_state updates)" = "full-upgrade-tray-updates" ]
  [ "$(tray_icon_name_for_state idle)" = "full-upgrade-tray-idle" ]
  [ "$(tray_icon_name_for_state desconhecido)" = "full-upgrade-tray-idle" ]
}

@test "tooltip: running" {
  [ "$(tray_tooltip_for_state running 0 0 0)" = "full-upgrade: executando…" ]
}

@test "tooltip: error mostra contagem" {
  [ "$(tray_tooltip_for_state error 0 0 2)" = "full-upgrade: último run com 2 falha(s)" ]
}

@test "tooltip: idle" {
  [ "$(tray_tooltip_for_state idle 0 0 0)" = "full-upgrade: sistema atualizado" ]
}

@test "tooltip: updates + todo + reboot combinados" {
  local t
  t=$(tray_tooltip_for_state attention 12 2 1 "Kernel atualizado")
  echo "$t" | grep -q "Reboot pendente"
  echo "$t" | grep -q "2 doctor todo"
  echo "$t" | grep -q "12 atualização"
}

@test "tooltip: updates apenas" {
  [ "$(tray_tooltip_for_state updates 7 0 0)" = "full-upgrade: 7 atualização(ões)" ]
}

@test "wayland_session: detecta Wayland por tipo de sessão" {
  XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=""
  run tray_wayland_session
  [ "$status" -eq 0 ]
}

@test "wayland_session: detecta Wayland por WAYLAND_DISPLAY" {
  XDG_SESSION_TYPE="" WAYLAND_DISPLAY=wayland-1
  run tray_wayland_session
  [ "$status" -eq 0 ]
}

@test "wayland_session: X11 não força AppIndicator" {
  XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY=""
  run tray_wayland_session
  [ "$status" -eq 1 ]
}

@test "yad_pid_alive: PID vazio não é considerado vivo" {
  FU_YAD_PID=""
  run tray_yad_pid_alive
  [ "$status" -eq 1 ]
}

@test "yad_pid_alive: PID real é considerado vivo" {
  FU_YAD_PID="$$"
  run tray_yad_pid_alive
  [ "$status" -eq 0 ]
}

# ── badge_text (rótulo do painel) ───────────────────────────────────────────────
@test "badge_text: updates mostra total" {
  run tray_badge_text updates 12 0 0
  [ "$output" = "12" ]
}

@test "badge_text: attention com todo mostra contagem" {
  run tray_badge_text attention 0 3 0
  [ "$output" = "3" ]
}

@test "badge_text: attention só reboot mostra '!'" {
  run tray_badge_text attention 0 0 0
  [ "$output" = "!" ]
}

@test "badge_text: error mostra falhas" {
  run tray_badge_text error 0 0 2
  [ "$output" = "2" ]
}

@test "badge_text: idle e running ficam vazios" {
  run tray_badge_text idle 0 0 0
  [ -z "$output" ]
  run tray_badge_text running 5 0 0
  [ -z "$output" ]
}

# ── relative_time ───────────────────────────────────────────────────────────────
@test "relative_time: < 1 min => agora" {
  now=$(date -d "2026-06-25T10:00:30" +%s)
  run tray_relative_time "2026-06-25T10:00:00" "$now"
  [ "$output" = "agora" ]
}

@test "relative_time: minutos" {
  now=$(date -d "2026-06-25T10:05:00" +%s)
  run tray_relative_time "2026-06-25T10:00:00" "$now"
  [ "$output" = "há 5 min" ]
}

@test "relative_time: horas" {
  now=$(date -d "2026-06-25T12:00:00" +%s)
  run tray_relative_time "2026-06-25T10:00:00" "$now"
  [ "$output" = "há 2 h" ]
}

@test "relative_time: dias" {
  now=$(date -d "2026-06-27T10:00:00" +%s)
  run tray_relative_time "2026-06-25T10:00:00" "$now"
  [ "$output" = "há 2 d" ]
}

@test "relative_time: timestamp inválido => vazio" {
  run tray_relative_time "not-a-date" 1000
  [ -z "$output" ]
}

@test "json_array_from_lines: serializa linhas não-vazias" {
  run bash -c 'source "$1"/globals.sh; source "$1"/json.sh; source "$1"/tray.sh; printf "pkg 1 -> 2\n\nfoo\n" | tray_json_array_from_lines' _ "$FU_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = '["pkg 1 -> 2","foo"]' ]
}

@test "latest_completed_real_jsonl: ignora dry-run e run real incompleto" {
  LOG_DIR="$(mktemp -d)"
  local old incomplete dry latest
  old="${LOG_DIR}/full-upgrade-20260625-100000-1.jsonl"
  incomplete="${LOG_DIR}/full-upgrade-20260625-110000-2.jsonl"
  dry="${LOG_DIR}/full-upgrade-20260625-120000-3.jsonl"
  printf '%s\n%s\n' \
    '{"event":"run_start","dry_run":false}' \
    '{"event":"summary","timestamp":"2026-06-25T10:00:00","todo":1,"fail":0,"reboot_recommendation":"","log_file":"/tmp/old.log","jsonl_file":"/tmp/old.jsonl"}' > "$old"
  printf '%s\n' '{"event":"run_start","dry_run":false}' > "$incomplete"
  printf '%s\n%s\n' \
    '{"event":"run_start","dry_run":true}' \
    '{"event":"summary","timestamp":"2026-06-25T12:00:00","todo":0,"fail":0,"reboot_recommendation":""}' > "$dry"
  touch -d '2026-06-25 10:00:00' "$old"
  touch -d '2026-06-25 11:00:00' "$incomplete"
  touch -d '2026-06-25 12:00:00' "$dry"

  latest="$(tray_latest_completed_real_jsonl)"
  [ "$latest" = "$old" ]
  [ "$(tray_last_summary_counts)" = "1 0 0" ]
}

@test "last_doctor_pending_items: lista Doctor warn/todo/fail do último run real" {
  LOG_DIR="$(mktemp -d)"
  local f out
  f="${LOG_DIR}/full-upgrade-20260625-100000-1.jsonl"
  cat > "$f" <<'EOF'
{"event":"run_start","dry_run":false}
{"event":"step","step":"Doctor: reboot pendente","status":"todo","reason":"Kernel atualizado","category":"doctor"}
{"event":"step","step":"Doctor: units systemd falhadas","status":"warn","reason":"foo.service","category":"doctor"}
{"event":"step","step":"Atualizar pacotes do sistema e AUR","status":"todo","reason":"x","category":"pacman"}
{"event":"summary","timestamp":"2026-06-25T10:00:00","todo":2,"fail":0,"reboot_recommendation":"Kernel atualizado"}
EOF
  out="$(tray_last_doctor_pending_items)"
  echo "$out" | grep -q 'todo: Doctor: reboot pendente — Kernel atualizado'
  echo "$out" | grep -q 'warn: Doctor: units systemd falhadas — foo.service'
  ! echo "$out" | grep -q 'Atualizar pacotes do sistema e AUR'
}

# ── tray_read_state_field ──────────────────────────────────────────────────────

@test "read_state_field: extrai campo string" {
  local f="${BATS_TEST_TMPDIR}/state.json"
  printf '{"state":"updates","prev_state":"idle"}\n' > "$f"
  run tray_read_state_field "$f" state
  [ "$output" = "updates" ]
}

@test "read_state_field: extrai campo numérico" {
  local f="${BATS_TEST_TMPDIR}/state.json"
  printf '{"repo":5,"aur":3,"todo":1}\n' > "$f"
  [ "$(tray_read_state_field "$f" repo)" = "5" ]
  [ "$(tray_read_state_field "$f" aur)" = "3" ]
  [ "$(tray_read_state_field "$f" todo)" = "1" ]
}

@test "read_state_field: campo ausente => rc 1" {
  local f="${BATS_TEST_TMPDIR}/state.json"
  printf '{"state":"idle"}\n' > "$f"
  run tray_read_state_field "$f" missing
  [ "$status" -eq 1 ]
}

@test "read_state_field: arquivo inexistente => rc 1" {
  run tray_read_state_field "/nonexistent/file.json" state
  [ "$status" -eq 1 ]
}

@test "read_state_field: campo vazio retorna string vazia" {
  local f="${BATS_TEST_TMPDIR}/state.json"
  printf '{"state":""}\n' > "$f"
  run tray_read_state_field "$f" state
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── tray_resolve_icon ─────────────────────────────────────────────────────────

@test "resolve_icon: retorna nome quando nenhum SVG encontrado" {
  run tray_resolve_icon "full-upgrade-tray-idle"
  # Pode retornar o path ou o nome, dependendo do sistema
  [ -n "$output" ]
}

@test "resolve_icon: encontra SVG em FU_ROOT/icons" {
  FU_ROOT="${BATS_TEST_TMPDIR}/fu-root-icons"
  mkdir -p "$FU_ROOT/icons"
  touch "$FU_ROOT/icons/full-upgrade-tray-idle.svg"
  run tray_resolve_icon "full-upgrade-tray-idle"
  [ "$status" -eq 0 ]
  [ "$output" = "$FU_ROOT/icons/full-upgrade-tray-idle.svg" ]
}

@test "resolve_icon: encontra SVG em FU_ROOT/assets/icons" {
  FU_ROOT="${BATS_TEST_TMPDIR}/fu-root-assets"
  mkdir -p "$FU_ROOT/assets/icons"
  touch "$FU_ROOT/assets/icons/full-upgrade-tray-error.svg"
  run tray_resolve_icon "full-upgrade-tray-error"
  [ "$status" -eq 0 ]
  [ "$output" = "$FU_ROOT/assets/icons/full-upgrade-tray-error.svg" ]
}

# ── tray_build_menu ────────────────────────────────────────────────────────────

@test "build_menu: contém itens essenciais" {
  local menu
  menu="$(tray_build_menu "/usr/bin/fu" 1234)"
  [[ "$menu" == *"Atualizar sistema completo"* ]]
  [[ "$menu" == *"Executar Doctor"* ]]
  [[ "$menu" == *"Sair do tray"* ]]
  [[ "$menu" == *"/usr/bin/fu --tray-launch"* ]]
  [[ "$menu" == *"kill -USR2 1234"* ]]
}

@test "build_menu: separador vazio presente" {
  local menu
  menu="$(tray_build_menu "/usr/bin/fu" 1234)"
  # Deve ter um separador vazio (||) antes de "Sair do tray"
  [[ "$menu" == *"||Sair do tray"* ]]
}

# ── tray_autostart_file ────────────────────────────────────────────────────────

@test "autostart_file: usa XDG_CONFIG_HOME padrão" {
  unset XDG_CONFIG_HOME
  local result
  result="$(tray_autostart_file)"
  [[ "$result" == *"/.config/autostart/full-upgrade-tray.desktop" ]]
}

@test "autostart_file: usa XDG_CONFIG_HOME custom" {
  XDG_CONFIG_HOME="$MOCKDIR/config"
  local result
  result="$(tray_autostart_file)"
  [ "$result" = "$MOCKDIR/config/autostart/full-upgrade-tray.desktop" ]
}

# ── tray_daemon_status ────────────────────────────────────────────────────────

@test "daemon_status: sem PID file => parado" {
  TRAY_PID_FILE="${BATS_TEST_TMPDIR}/nonexistent.pid"
  run tray_daemon_status
  [ "$output" = "parado" ]
}

@test "daemon_status: PID file com PID morto => parado" {
  TRAY_PID_FILE="${BATS_TEST_TMPDIR}/dead.pid"
  echo "99999999" > "$TRAY_PID_FILE"
  run tray_daemon_status
  [ "$output" = "parado" ]
}

@test "daemon_status: PID file com PID vivo => rodando" {
  TRAY_PID_FILE="${BATS_TEST_TMPDIR}/alive.pid"
  echo "$$" > "$TRAY_PID_FILE"
  run tray_daemon_status
  [[ "$output" == *"rodando"* ]]
  [[ "$output" == *"$$"* ]]
}

# ── tray_self_bin ──────────────────────────────────────────────────────────────

@test "self_bin: retorna full-upgrade quando comando existe" {
  has() { [[ "$1" == "full-upgrade" ]]; }
  run tray_self_bin
  [ "$output" = "full-upgrade" ]
}

@test "self_bin: retorna SCRIPT_PATH quando definido" {
  has() { return 1; }
  SCRIPT_PATH="/opt/fu/full-upgrade.sh"
  run tray_self_bin
  [ "$output" = "/opt/fu/full-upgrade.sh" ]
}

@test "self_bin: fallback para FU_ROOT/full-upgrade.sh" {
  has() { return 1; }
  unset SCRIPT_PATH
  run tray_self_bin
  [[ "$output" == *"full-upgrade.sh" ]]
}

# ── tooltip: edge cases adicionais ────────────────────────────────────────────

@test "tooltip: attention com reboot mas sem updates e sem todo" {
  local t
  t=$(tray_tooltip_for_state attention 0 0 0 "Kernel X")
  [[ "$t" == *"Reboot pendente"* ]]
  [[ "$t" != *"atualização"* ]]
}

@test "tooltip: idle sem nada => sistema atualizado" {
  [ "$(tray_tooltip_for_state idle 0 0 0)" = "full-upgrade: sistema atualizado" ]
}

# ── relative_time: delta negativo (futuro) ────────────────────────────────────

@test "relative_time: timestamp futuro => agora (delta negativo tratado como 0)" {
  now=$(date -d "2026-06-25T10:00:00" +%s)
  run tray_relative_time "2026-06-25T10:05:00" "$now"
  [ "$output" = "agora" ]
}

@test "relative_time: timestamp vazio => vazio" {
  run tray_relative_time "" 1000
  [ -z "$output" ]
}

# ── tray_detect_terminal (seleção de emulador) ────────────────────────────────
@test "detect_terminal: respeita TRAY_TERMINAL quando disponível" {
  has() { [[ "$1" == "myterm" ]]; }
  TRAY_TERMINAL=myterm run tray_detect_terminal
  [ "$status" -eq 0 ]
  [ "$output" = "myterm" ]
}

@test "detect_terminal: ignora TRAY_TERMINAL inexistente e cai no fallback" {
  has() { [[ "$1" == "kitty" ]]; }
  TRAY_TERMINAL=naoexiste run tray_detect_terminal
  [ "$status" -eq 0 ]
  [ "$output" = "kitty" ]
}

@test "detect_terminal: prefere xdg-terminal-exec quando presente" {
  has() { [[ "$1" == "xdg-terminal-exec" ]]; }
  run tray_detect_terminal
  [ "$output" = "xdg-terminal-exec" ]
}

@test "detect_terminal: nenhum terminal => rc 1" {
  has() { return 1; }
  run tray_detect_terminal
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ── tray_python_bin ───────────────────────────────────────────────────────────
@test "python_bin: prefere python3" {
  has() { [[ "$1" == "python3" || "$1" == "python" ]]; }
  run tray_python_bin
  [ "$output" = "python3" ]
}

@test "python_bin: cai para python quando só ele existe" {
  has() { [[ "$1" == "python" ]]; }
  run tray_python_bin
  [ "$output" = "python" ]
}

@test "python_bin: nenhum => rc 1" {
  has() { return 1; }
  run tray_python_bin
  [ "$status" -ne 0 ]
}

# ── tray_num_or_zero (coerção defensiva do estado JSON) ───────────────────────

@test "tray_num_or_zero: inteiro passa" {
  [ "$(tray_num_or_zero 42)" = "42" ]
}

@test "tray_num_or_zero: vazio vira 0" {
  [ "$(tray_num_or_zero "")" = "0" ]
}

@test "tray_num_or_zero: lixo vira 0" {
  [ "$(tray_num_or_zero "abc")" = "0" ]
  [ "$(tray_num_or_zero "-3")" = "0" ]
}

@test "tray_write_state: campo numérico vazio não quebra o JSON" {
  # json_escape vive em lib/json.sh (não carregado pelo helper); stub simples
  # basta aqui (sem caracteres especiais nos campos deste teste).
  json_escape() { printf '"%s"' "$1"; }
  LOG_DIR="$BATS_TEST_TMPDIR"
  TRAY_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  tray_write_state idle "" "" "x" 2 "" 1 "" "2026-07-02T12:00:00-03:00" "" "" "" '[]' '[]' '[]'
  run python3 -c "import json,sys; d=json.load(open('$BATS_TEST_TMPDIR/state.json')); print(d['repo'], d['aur'], d['flatpak'], d['todo'], d['fail'])"
  [ "$status" -eq 0 ]
  [ "$output" = "0 0 2 0 1" ]
}

# ── unit systemd user (XDG + Hyprland/sway) ───────────────────────────────────
# Compositores Wayland não processam XDG autostart; a unit systemd garante o
# daemon. Aqui testamos as funções puras de caminho/status sem tocar no D-Bus.

@test "tray_systemd_unit_file: respeita XDG_CONFIG_HOME" {
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  [ "$(tray_systemd_unit_file)" = "$BATS_TEST_TMPDIR/xdg/systemd/user/full-upgrade-tray.service" ]
}

@test "tray_systemd_unit_file: fallback para ~/.config quando XDG ausente" {
  unset XDG_CONFIG_HOME
  HOME="$BATS_TEST_TMPDIR/fakehome"
  [ "$(tray_systemd_unit_file)" = "$BATS_TEST_TMPDIR/fakehome/.config/systemd/user/full-upgrade-tray.service" ]
}

@test "tray_systemd_unit_status: unit não escrita => 'não instalada'" {
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-empty"
  run tray_systemd_unit_status
  [ "$status" -eq 0 ]
  [ "$output" = "não instalada" ]
}

@test "tray_systemd_unit_status: unit escrita e serviço ativo => 'habilitada (ativa)'" {
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-active"
  mkdir -p "$(tray_systemd_unit_file | xargs dirname)"
  touch "$(tray_systemd_unit_file)"
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 0; }   # is-active sucesso
  run tray_systemd_unit_status
  [ "$status" -eq 0 ]
  [ "$output" = "habilitada (ativa)" ]
}

@test "tray_systemd_unit_status: unit escrita e serviço parado => 'habilitada (inativa)'" {
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-inactive"
  mkdir -p "$(tray_systemd_unit_file | xargs dirname)"
  touch "$(tray_systemd_unit_file)"
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 3; }   # is-active falha (inativo)
  run tray_systemd_unit_status
  [ "$status" -eq 0 ]
  [ "$output" = "habilitada (inativa)" ]
}

@test "tray_systemd_user_available: systemctl ausente => rc 1" {
  has() { return 1; }
  run tray_systemd_user_available
  [ "$status" -eq 1 ]
}

@test "tray_enable_systemd_unit: systemd user indisponível => rc 1, sem escrever unit" {
  has() { return 1; }   # systemctl ausente
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-no-systemd"
  run tray_enable_systemd_unit
  [ "$status" -eq 1 ]
  [ ! -e "$(tray_systemd_unit_file)" ]
}

@test "tray_enable_systemd_unit: disponível => escreve a unit com ExecStart correto" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 0; }   # show-environment e enable --now ambos ok
  tray_self_bin() { printf '/usr/bin/full-upgrade'; }
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-ok"
  run tray_enable_systemd_unit
  [ "$status" -eq 0 ]
  local unit
  unit="$(tray_systemd_unit_file)"
  [ -f "$unit" ]
  grep -q 'ExecStart=/usr/bin/full-upgrade --tray' "$unit"
  grep -q 'WantedBy=graphical-session.target' "$unit"
}

@test "tray_disable_systemd_unit: remove unit escrita" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 0; }
  XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-rm"
  mkdir -p "$(dirname "$(tray_systemd_unit_file)")"
  touch "$(tray_systemd_unit_file)"
  [ -f "$(tray_systemd_unit_file)" ]
  run tray_disable_systemd_unit
  [ "$status" -eq 0 ]
  [ ! -e "$(tray_systemd_unit_file)" ]
  [[ "$output" == *"removida"* ]]
}
