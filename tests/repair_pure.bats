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

@test "repair_known_command_shadowing: executa sem crash (wireshark/dumpcap não em /usr/local/bin)" {
  run repair_known_command_shadowing
  [ "$status" -eq 0 ]
}

@test "repair_command_shadowing: local_path existe mas managed não => return 1" {
  local tmplocal
  tmplocal=$(mktemp)
  run repair_command_shadowing "teste" "/tmp/nonexistent_managed_xyz_abc_$$" "$tmplocal"
  local rc="$status"
  rm -f "$tmplocal"
  [ "$rc" -eq 1 ]
}

@test "repair_command_shadowing: local e managed existem, local owned by pacman => return 0" {
  local tmplocal tmpmanaged mockdir
  tmplocal=$(mktemp)
  tmpmanaged=$(mktemp)
  mockdir=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' > "$mockdir/pacman"
  chmod +x "$mockdir/pacman"
  PATH="$mockdir:$PATH" run repair_command_shadowing "teste" "$tmpmanaged" "$tmplocal"
  local rc="$status"
  rm -f "$tmplocal" "$tmpmanaged" "$mockdir/pacman"
  rmdir "$mockdir"
  [ "$rc" -eq 0 ]
}

@test "repair_command_shadowing: local não owned, managed também não => return 1" {
  local tmplocal tmpmanaged mockdir
  tmplocal=$(mktemp)
  tmpmanaged=$(mktemp)
  mockdir=$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n' > "$mockdir/pacman"
  chmod +x "$mockdir/pacman"
  PATH="$mockdir:$PATH" run repair_command_shadowing "teste" "$tmpmanaged" "$tmplocal"
  local rc="$status"
  rm -f "$tmplocal" "$tmpmanaged" "$mockdir/pacman"
  rmdir "$mockdir"
  [ "$rc" -eq 1 ]
}

@test "repair_command_shadowing: local não owned, managed owned => return 2" {
  local tmplocal tmpmanaged mockdir
  tmplocal=$(mktemp)
  tmpmanaged=$(mktemp)
  mockdir=$(mktemp -d)
  # pacman -Qo $tmplocal → fail (not owned), -Qo $tmpmanaged → success (owned)
  printf '#!/bin/sh\n[ "$2" = "%s" ] && exit 1 || exit 0\n' "$tmplocal" > "$mockdir/pacman"
  chmod +x "$mockdir/pacman"
  PATH="$mockdir:$PATH" run repair_command_shadowing "teste" "$tmpmanaged" "$tmplocal"
  local rc="$status"
  rm -f "$tmplocal" "$tmpmanaged" "$mockdir/pacman"
  rmdir "$mockdir"
  [ "$rc" -eq 2 ]
}
