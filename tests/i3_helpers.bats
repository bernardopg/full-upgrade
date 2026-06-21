#!/usr/bin/env bats
# tests/i3_helpers.bats — detecção de helper AUR e elevador (I3).

load test_helper

setup() {
  load_libs
  # detect_aur_helper/detect_priv_cmd vivem em config.sh, que não é carregado
  # por load_libs (ele tem efeitos de I/O via load_config). Sourceamos só as
  # funções puras de detecção, que dependem apenas de `has` (de core.sh).
  # shellcheck source=/dev/null
  source "${FU_LIB}/config.sh"
  AUR_HELPER=""
  PRIV_CMD=""
}

@test "aur_helper: paru tem prioridade quando instalado" {
  has() { [[ "$1" == paru || "$1" == yay ]]; }
  out="$(detect_aur_helper)"
  [ "$out" = "paru" ]
}

@test "aur_helper: cai para yay se só yay instalado" {
  has() { [[ "$1" == yay ]]; }
  out="$(detect_aur_helper)"
  [ "$out" = "yay" ]
}

@test "aur_helper: pikaur é o último recurso" {
  has() { [[ "$1" == pikaur ]]; }
  out="$(detect_aur_helper)"
  [ "$out" = "pikaur" ]
}

@test "aur_helper: AUR_HELPER explícito é respeitado (mesmo com outros presentes)" {
  AUR_HELPER="yay"
  has() { [[ "$1" == paru || "$1" == yay ]]; }
  out="$(detect_aur_helper)"
  [ "$out" = "yay" ]
}

@test "aur_helper: AUR_HELPER explícito ausente ignora e autodetecta" {
  AUR_HELPER="yay"
  has() { [[ "$1" == paru ]]; }   # yay não está instalado de fato
  out="$(detect_aur_helper)"
  [ "$out" = "paru" ]
}

@test "aur_helper: nenhum instalado => rc 1 e vazio" {
  has() { return 1; }
  run detect_aur_helper
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "priv_cmd: sudo tem prioridade" {
  has() { [[ "$1" == sudo || "$1" == doas ]]; }
  out="$(detect_priv_cmd)"
  [ "$out" = "sudo" ]
}

@test "priv_cmd: cai para doas se só doas instalado" {
  has() { [[ "$1" == doas ]]; }
  out="$(detect_priv_cmd)"
  [ "$out" = "doas" ]
}

@test "priv_cmd: PRIV_CMD explícito é respeitado" {
  PRIV_CMD="doas"
  has() { [[ "$1" == sudo || "$1" == doas ]]; }
  out="$(detect_priv_cmd)"
  [ "$out" = "doas" ]
}

@test "priv_cmd: nenhum instalado => rc 1 e vazio" {
  has() { return 1; }
  run detect_priv_cmd
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
