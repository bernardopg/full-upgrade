#!/usr/bin/env bats
# tests/doctor_packages_cov.bats — Devel do paru (config descartável), Flatpak
# ausente, saída longa do pacman -Qk e o inventário de apps manuais com todos os
# tipos (coberto, backup, auxiliar, candidato) em /usr/local/bin, /opt e
# ~/.local/opt — todos diretórios descartáveis. PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export PARU_SYSTEM_CONF="$BATS_TEST_TMPDIR/paru.conf"
}

@test "paru Devel: sem paru, ativo e inativo" {
  run doctor_paru_devel_mode
  [[ "$output" == *"paru não instalado"* ]]
  stub paru 0 ""
  printf '[options]\nDevel\n' > "$PARU_SYSTEM_CONF"
  run doctor_paru_devel_mode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"paru tem Devel ativo"* ]]
  printf '[options]\n#Devel\n' > "$PARU_SYSTEM_CONF"
  run doctor_paru_devel_mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"Devel global não está ativo"* ]]
}

@test "flatpak ausente e pacman -Qk com mais de 60 problemas" {
  run doctor_flatpak_repair_dry_run
  [[ "$output" == *"flatpak não instalado"* ]]
  stub_privilege
  stub_script pacman 'for i in $(seq 1 70); do echo "pkg$i /usr/bin/x$i (No such file)"; done; exit 1'
  run doctor_pacman_health
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"Saída completa registrada no log"* ]]
}

_big() { mkdir -p "$(dirname "$1")"; truncate -s 2M "$1"; chmod +x "$1"; }

@test "apps manuais: nada encontrado" {
  stub pacman 1 ""
  MANUAL_APPS_SYSTEM_BIN_DIR="$BATS_TEST_TMPDIR/nada" MANUAL_APPS_OPT_DIR="$BATS_TEST_TMPDIR/nada" run doctor_manual_apps
  [[ "$output" == *"Nenhum app fora de gerenciador de pacotes detectado"* ]]
}

@test "apps manuais: todos os tipos em bin, /opt e ~/.local/opt, lista truncada" {
  stub pacman 1 ""
  local bin="$BATS_TEST_TMPDIR/usr-local-bin" opt="$BATS_TEST_TMPDIR/opt"
  _big "$bin/rtk"; _big "$bin/foo.manual.1"; _big "$bin/tshark"
  for i in $(seq 1 27); do _big "$bin/app$i"; done
  _big "$opt/antigravity/bin/x"; _big "$opt/velho.bak/x"; _big "$opt/sharkd/x"; _big "$opt/jogo/x"
  mkdir -p "$opt/vazio"; ln -s "$opt/jogo" "$opt/atalho"
  mkdir -p "$HOME/.local/opt"/{handy,ori,tor.orig,tshark}
  MANUAL_APPS_SYSTEM_BIN_DIR="$bin" MANUAL_APPS_OPT_DIR="$opt" run doctor_manual_apps
  [ "$status" -eq 0 ]
  [[ "$output" == *"… e mais"* ]]
  [[ "$output" == *"Backups/remanescentes detectados (3)"* ]]
  [[ "$output" == *"rm '$bin/foo.manual.1'"* ]]
  [[ "$output" == *"Binários auxiliares conhecidos (3)"* ]]
  [[ "$output" == *"com step: 3"* ]]
}

@test "apps manuais: binário Go instalado com go install conta como coberto" {
  stub pacman 1 ""
  stub go 0 ""
  go_tool_module() { echo example.com/x; }
  local bin="$BATS_TEST_TMPDIR/ulb"; _big "$bin/meutool"
  MANUAL_APPS_SYSTEM_BIN_DIR="$bin" MANUAL_APPS_OPT_DIR="$BATS_TEST_TMPDIR/nada" run doctor_manual_apps
  [[ "$output" == *"com step: 1"* ]]
}
