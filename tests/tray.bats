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
