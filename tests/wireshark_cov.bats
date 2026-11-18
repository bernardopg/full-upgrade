#!/usr/bin/env bats
# tests/wireshark_cov.bats — pacote wireshark-qt e permissões de captura do
# dumpcap (arquivo descartável). PATH isolado; sudo só executa o stub.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/repair.sh"
  source "${FU_ROOT}/steps.d/50-wireshark.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export WIRESHARK_DUMPCAP="$BATS_TEST_TMPDIR/dumpcap" REPAIR_LOCAL_BIN_DIR="$BATS_TEST_TMPDIR/local-bin"
}

@test "ensure: já na mais recente, atualiza e falha" {
  stub_script pacman 'case "$1" in -Q) echo "wireshark-qt 4.4.0-1" ;; -Si) echo "Version         : ${AVAIL:-4.4.0-1}" ;; -S) exit "${S_RC:-0}" ;; esac'
  run ensure_wireshark
  [[ "$output" == *"já na versão mais recente"* ]]
  AVAIL=4.4.1-1 run ensure_wireshark
  [ "$status" -eq 0 ]
  [[ "$output" == *"wireshark-qt: 4.4.0-1 → 4.4.1-1"* ]]
  AVAIL=4.4.1-1 S_RC=1 run ensure_wireshark
  [ "$status" -eq 1 ]
  [[ "$output" == *"Falha ao garantir wireshark-qt"* ]]
}

@test "permissões: sem dumpcap, sem grupo, sem setcap e completo" {
  run repair_wireshark_capture_permissions
  [ "$status" -eq 1 ]
  [[ "$output" == *"dumpcap não encontrado"* ]]
  touch "$WIRESHARK_DUMPCAP"
  stub getent 2 ""
  run repair_wireshark_capture_permissions
  [[ "$output" == *"Grupo wireshark não encontrado"* ]]
  stub getent 0 "wireshark:x:150:"
  stub chgrp 0 ""
  run repair_wireshark_capture_permissions
  [ "$status" -eq 1 ]
  [[ "$output" == *"setcap não instalado"* ]]
  stub setcap 0 ""
  run repair_wireshark_capture_permissions
  [ "$status" -eq 0 ]
  [ "$(stub_calls setcap)" = "cap_net_raw,cap_net_admin,cap_dac_override+eip $WIRESHARK_DUMPCAP" ]
}

@test "permissões: sombra em /usr/local/bin que não pode ser reparada aborta" {
  mkdir -p "$REPAIR_LOCAL_BIN_DIR"; touch "$REPAIR_LOCAL_BIN_DIR/dumpcap"
  run repair_wireshark_capture_permissions
  [ "$status" -eq 1 ]
  [[ "$output" == *"Binario gerenciado não encontrado para dumpcap"* ]]
}
