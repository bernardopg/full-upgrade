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
