#!/usr/bin/env bats
# tests/containers_pure.bats — testes para funções puras de lib/testable/containers_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/containers_pure.sh"
}

@test "_docker_is_remote_image: imagem com / é remota" {
  run _docker_is_remote_image "ghcr.io/user/app:tag"
  [ "$status" -eq 0 ]
}

@test "_docker_is_remote_image: imagem local sem / não é remota" {
  run _docker_is_remote_image "minha-imagem:dev"
  [ "$status" -ne 0 ]
}

@test "_docker_is_remote_image: postgres é oficial remota" {
  run _docker_is_remote_image "postgres:latest"
  [ "$status" -eq 0 ]
}

@test "_docker_is_remote_image: redis é oficial remota" {
  run _docker_is_remote_image "redis"
  [ "$status" -eq 0 ]
}

@test "_docker_is_remote_image: nginx é oficial remota" {
  run _docker_is_remote_image "nginx:alpine"
  [ "$status" -eq 0 ]
}

@test "_docker_is_remote_image: alpine é oficial remota" {
  run _docker_is_remote_image "alpine:3.19"
  [ "$status" -eq 0 ]
}

@test "_docker_is_remote_image: imagem local custom não é remota" {
  run _docker_is_remote_image "meu-app"
  [ "$status" -ne 0 ]
}

@test "_docker_is_remote_image: imagem com registry e porta é remota" {
  run _docker_is_remote_image "registry.local:5000/myapp:latest"
  [ "$status" -eq 0 ]
}

@test "docker_info_timeout_seconds: default é 5" {
  unset DOCKER_INFO_TIMEOUT_S
  run docker_info_timeout_seconds
  [ "$output" = "5" ]
}

@test "docker_info_timeout_seconds: valor válido preservado" {
  DOCKER_INFO_TIMEOUT_S=10
  run docker_info_timeout_seconds
  [ "$output" = "10" ]
}

@test "docker_info_timeout_seconds: zero cai para 5" {
  DOCKER_INFO_TIMEOUT_S=0
  run docker_info_timeout_seconds
  [ "$output" = "5" ]
}

@test "docker_info_timeout_seconds: não-numérico cai para 5" {
  DOCKER_INFO_TIMEOUT_S=abc
  run docker_info_timeout_seconds
  [ "$output" = "5" ]
}
