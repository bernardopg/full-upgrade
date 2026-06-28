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
