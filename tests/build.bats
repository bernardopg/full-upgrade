#!/usr/bin/env bats
# tests/build.bats — metadados do artefato standalone de release.

@test "build: override de release prevalece sobre git describe" {
  local root
  root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  run env FULL_UPGRADE_BUILD_VERSION=v9.8.7 bash "${root}/build.sh"

  [ "$status" -eq 0 ]
  run bash "${root}/dist/full-upgrade-standalone.sh" --version
  [ "$status" -eq 0 ]
  [ "$output" = "9.8.7" ]
}

@test "build: rejeita override de versão inválido" {
  local root
  root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  run env FULL_UPGRADE_BUILD_VERSION='release/latest' bash "${root}/build.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"FULL_UPGRADE_BUILD_VERSION inválida"* ]]
}
