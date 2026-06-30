#!/usr/bin/env bats
# tests/doctor.bats — funções puras de auditoria (lib/steps/doctor.sh).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
}

@test "systemd_running_version: extrai versão Arch completa do parêntese" {
  run systemd_running_version "systemd 261 (261-1-arch)"
  [ "$status" -eq 0 ]
  [ "$output" = "261-1" ]
}

@test "systemd_running_version: preserva minor (257.8-1)" {
  run systemd_running_version "systemd 257 (257.8-1-arch)"
  [ "$output" = "257.8-1" ]
}

@test "systemd_running_version: parêntese sem sufixo -arch" {
  run systemd_running_version "systemd 254 (254)"
  [ "$output" = "254" ]
}

@test "systemd_running_version: sem parêntese cai no major do token" {
  run systemd_running_version "systemd 261"
  [ "$output" = "261" ]
}

@test "systemd_running_version: regressão — não falso-positiva após reboot" {
  # Versão em execução (parêntese) deve bater com a do pacman ("261-1"),
  # evitando 'reboot pendente' permanente que o antigo cut -d. -f1 causava.
  running="$(systemd_running_version "systemd 261 (261-1-arch)")"
  installed="261-1"
  [ "$running" = "$installed" ]
}

# ── usage_pct_severity (classificação de uso disco/inodes) ────────────────────
@test "usage_pct_severity: >=95 => todo" {
  run usage_pct_severity 95;  [ "$output" = "todo" ]
  run usage_pct_severity 99;  [ "$output" = "todo" ]
  run usage_pct_severity 100; [ "$output" = "todo" ]
}

@test "usage_pct_severity: 90..94 => warn" {
  run usage_pct_severity 90; [ "$output" = "warn" ]
  run usage_pct_severity 94; [ "$output" = "warn" ]
}

@test "usage_pct_severity: <90 => ok" {
  run usage_pct_severity 0;  [ "$output" = "ok" ]
  run usage_pct_severity 89; [ "$output" = "ok" ]
}

@test "usage_pct_severity: aceita sufixo % e ignora não-numérico" {
  run usage_pct_severity "96%"; [ "$output" = "todo" ]
  run usage_pct_severity "-";   [ "$output" = "ok" ]
  run usage_pct_severity "";    [ "$output" = "ok" ]
}

# ── http_code_class (classificação de status HTTP) ────────────────────────────
@test "http_code_class: 2xx/3xx => ok" {
  run http_code_class 200; [ "$output" = "ok" ]
  run http_code_class 204; [ "$output" = "ok" ]
  run http_code_class 301; [ "$output" = "ok" ]
}

@test "http_code_class: 4xx/5xx/vazio => fail" {
  run http_code_class 404; [ "$output" = "fail" ]
  run http_code_class 500; [ "$output" = "fail" ]
  run http_code_class "";  [ "$output" = "fail" ]
}
