#!/usr/bin/env bats
# tests/repair_pure.bats — testes para funções puras de lib/testable/repair_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/repair_pure.sh"
}

@test "repair_command_shadowing: retorna 0 quando local_path não existe" {
  run repair_command_shadowing "_ferramenta_inexistente_xyz_abc_" "/usr/bin/wireshark"
  [ "$status" -eq 0 ]
}

@test "repair_command_shadowing: retorna 0 para segundo cmd inexistente também" {
  run repair_command_shadowing "_ferramenta2_inexistente_xyz_" "/usr/bin/dumpcap"
  [ "$status" -eq 0 ]
}
