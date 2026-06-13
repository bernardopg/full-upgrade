#!/usr/bin/env bats
# tests/containers.bats — helpers puros de steps/containers.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/containers.sh"
}

@test "docker_info_timeout_seconds: default defensivo é 5s" {
  unset DOCKER_INFO_TIMEOUT_S
  run docker_info_timeout_seconds
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "docker_info_timeout_seconds: aceita inteiro positivo configurado" {
  DOCKER_INFO_TIMEOUT_S=2
  run docker_info_timeout_seconds
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "docker_info_timeout_seconds: valor inválido cai para 5s" {
  DOCKER_INFO_TIMEOUT_S=abc
  run docker_info_timeout_seconds
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "docker_info_timeout_seconds: zero cai para 5s" {
  DOCKER_INFO_TIMEOUT_S=0
  run docker_info_timeout_seconds
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "_docker_is_remote_image: imagem oficial simples é remota" {
  run _docker_is_remote_image "postgres:latest"
  [ "$status" -eq 0 ]
}

@test "_docker_is_remote_image: build local desconhecido é ignorado" {
  run _docker_is_remote_image "minha-imagem:dev"
  [ "$status" -ne 0 ]
}
