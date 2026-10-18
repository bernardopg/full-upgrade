#!/usr/bin/env bats
# Regressões de fluxo: todos os comandos Docker são mocks, sem acesso ao daemon.
setup() {
  load test_helper
  load_libs
  source "${FU_LIB}/steps/packages.sh"
  has() { [[ "$1" == docker ]]; }
  docker_daemon_accessible() { return 0; }
  MOCK_PULL_RC=0
  MOCK_IMAGES='caddy:2.11-alpine'
  MOCK_IMAGES_FAIL=0
  MOCK_STALE=0
  MOCK_INSPECT_FAIL=0
  MOCK_DIGESTS=1
  MOCK_COMPOSE_PROJECT=''
  STEP_REASON=''
  _retry() { printf 'mock pull\n'; return "$MOCK_PULL_RC"; }
  docker() {
    case "$*" in
      'images '*) (( MOCK_IMAGES_FAIL )) && return 1; printf '%s\n' "$MOCK_IMAGES" ;;
      'image ls '*) : ;;
      'image inspect '*com.docker.compose.project*) printf '%s\n' "$MOCK_COMPOSE_PROJECT" ;;
      'image inspect '*RepoDigests*)
        (( MOCK_DIGESTS )) && printf 'caddy@sha256:digest\n'
        return 0 ;;
      'image inspect '*)
        (( MOCK_INSPECT_FAIL )) && return 1
        printf 'sha256:new\n' ;;
      'ps -q') printf 'container123\n' ;;
      'container inspect '*)
        (( MOCK_INSPECT_FAIL )) && return 1
        if (( MOCK_STALE )); then
          printf '/web\tcaddy:2.11-alpine\tsha256:old\n'
        else
          printf '/web\tcaddy:2.11-alpine\tsha256:new\n'
        fi ;;
      *) printf 'Docker não mockado: %s\n' "$*" >&2; return 90 ;;
    esac
  }
}

@test "Docker: falha transitória preserva RC_WARN e motivo" {
  MOCK_PULL_RC="$RC_WARN"
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *caddy* ]]
}

@test "Docker: falha definitiva retorna fail com motivo" {
  MOCK_PULL_RC=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$STEP_REASON" == *caddy* ]]
}

@test "Docker: imagem com RepoDigest remoto não é ignorada" {
  run _docker_has_remote_digest caddy:2.11-alpine
  [ "$status" -eq 0 ]
}

@test "Docker: build sem RepoDigest não é presumido remoto pelo nome" {
  MOCK_DIGESTS=0
  run _docker_has_remote_digest empresa/build:dev
  [ "$status" -ne 0 ]
}

@test "Docker: RepoDigest gerado por build local não torna nome curto desconhecido remoto" {
  run _docker_has_remote_digest streamworks-local:1.12.0
  [ "$status" -eq 1 ]
}

@test "Docker: imagem qualificada construída por Compose não é puxada do registry" {
  MOCK_COMPOSE_PROJECT='meu-projeto'
  run _docker_has_remote_digest empresa/build:dev
  [ "$status" -eq 1 ]
}

@test "Docker: archlinux oficial com digest é atualizada" {
  run _docker_has_remote_digest archlinux:base
  [ "$status" -eq 0 ]
}

@test "Docker: container com imagem igual permanece OK" {
  run update_docker_images
  [ "$status" -eq 0 ]
  [[ "$output" != *'Docker não mockado'* ]]
}

@test "Docker: container com imagem antiga requer recriação e retorna TODO" {
  MOCK_STALE=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *recriar* ]]
}

@test "Docker: inspect falho não é falso OK" {
  MOCK_INSPECT_FAIL=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *verific* ]]
}

@test "Docker: inventário falhado não vira falso OK" {
  MOCK_IMAGES_FAIL=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *inventário* ]]
}

@test "Docker: só builds locais ainda verificam containers com imagem antiga" {
  MOCK_IMAGES='streamworks-local:1.12.0'
  MOCK_STALE=1
  MOCK_PULL_RC=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
}

@test "Docker: falha definitiva tem precedência sobre container antigo" {
  MOCK_PULL_RC=1
  MOCK_STALE=1
  run update_docker_images
  [ "$status" -eq 1 ]
}
