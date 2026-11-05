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
  MOCK_COMPOSE_DIR=''
  MOCK_COMPOSE_SVC=''
  MOCK_COMPOSE_NAME=''
  MOCK_COMPOSE_FILES=''
  MOCK_RECREATED="${BATS_TEST_TMPDIR}/recreated"
  MOCK_COMPOSE_RC=0
  STEP_REASON=''
  MOCK_PULL_OUTPUT='mock pull'
  _retry() { printf '%s\n' "$MOCK_PULL_OUTPUT"; return "$MOCK_PULL_RC"; }
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
      'compose '*)
        printf '%s\n' "$*" >>"${MOCK_RECREATED}.args"
        (( MOCK_COMPOSE_RC == 0 )) && : >"$MOCK_RECREATED"
        return "$MOCK_COMPOSE_RC" ;;
      'container inspect '*)
        (( MOCK_INSPECT_FAIL )) && return 1
        if (( MOCK_STALE )) && [[ ! -e "$MOCK_RECREATED" ]]; then
          printf '/web\x1fcaddy:2.11-alpine\x1fsha256:old\x1f%s\x1f%s\x1f%s\x1f%s\n' "$MOCK_COMPOSE_DIR" "$MOCK_COMPOSE_SVC" "$MOCK_COMPOSE_NAME" "$MOCK_COMPOSE_FILES"
        else
          printf '/web\x1fcaddy:2.11-alpine\x1fsha256:new\n'
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

@test "Docker: namespaces local/ e localhost/ são builds locais, registry com porta não" {
  run _docker_is_remote_image local/doctoralia-api:fix
  [ "$status" -eq 1 ]
  run _docker_is_remote_image localhost/app:1
  [ "$status" -eq 1 ]
  run _docker_is_remote_image localhost:5000/app:1
  [ "$status" -eq 0 ]
}

@test "Docker: httpd oficial do Docker Hub é remota" {
  run _docker_is_remote_image httpd:2.4
  [ "$status" -eq 0 ]
}

@test "Docker: build local com RepoDigest do containerd não vira fail no pull" {
  MOCK_IMAGES='empresa/build:dev'
  MOCK_PULL_RC=1
  MOCK_PULL_OUTPUT="Error response from daemon: pull access denied for empresa/build, repository does not exist or may require 'docker login'"
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$STEP_REASON" ]
}

@test "Docker: erro de pull fora do padrão sem-upstream continua fail" {
  MOCK_PULL_RC=1
  MOCK_PULL_OUTPUT='Error response from daemon: failed to register layer: no space left on device'
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq 1 ]
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

@test "Docker: container de Compose com imagem antiga recebe comando exato de recriação" {
  MOCK_STALE=1
  MOCK_COMPOSE_DIR='/srv/app'
  MOCK_COMPOSE_SVC='web'
  REMEDIATIONS=()
  remediation() { REMEDIATIONS+=("$*"); }
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [ "${REMEDIATIONS[0]}" = "docker compose --project-directory /srv/app up -d --no-deps --force-recreate web" ]
}

@test "Docker: container fora do Compose continua TODO sem comando de Compose" {
  MOCK_STALE=1
  REMEDIATIONS=()
  remediation() { REMEDIATIONS+=("$*"); }
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [ "${#REMEDIATIONS[@]}" -eq 0 ]
}

@test "Docker: comando de recriação usa projeto e arquivos dos rótulos do Compose" {
  MOCK_STALE=1
  MOCK_COMPOSE_DIR='/srv/app'
  MOCK_COMPOSE_SVC='web'
  MOCK_COMPOSE_NAME='loja'
  MOCK_COMPOSE_FILES='/srv/app/compose.yml,/srv/app/compose.prod.yml'
  REMEDIATIONS=()
  remediation() { REMEDIATIONS+=("$*"); }
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [ "${REMEDIATIONS[0]}" = "docker compose --project-directory /srv/app -p loja -f /srv/app/compose.yml -f /srv/app/compose.prod.yml up -d --no-deps --force-recreate web" ]
}

@test "Docker: AUTO_RECREATE_STALE_CONTAINERS=1 recria o serviço e fecha OK após reverificar" {
  MOCK_STALE=1
  MOCK_COMPOSE_DIR="$BATS_TEST_TMPDIR"
  MOCK_COMPOSE_SVC='web'
  MOCK_COMPOSE_NAME='loja'
  MOCK_COMPOSE_FILES="$BATS_TEST_TMPDIR/compose.yml"
  : >"$MOCK_COMPOSE_FILES"
  AUTO_RECREATE_STALE_CONTAINERS=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
  [ -e "$MOCK_RECREATED" ]
  grep -q -- "-p loja -f $BATS_TEST_TMPDIR/compose.yml up -d --no-deps --force-recreate web" "${MOCK_RECREATED}.args"
}

@test "Docker: recriação automática que falha mantém TODO" {
  MOCK_STALE=1
  MOCK_COMPOSE_DIR="$BATS_TEST_TMPDIR"
  MOCK_COMPOSE_SVC='web'
  MOCK_COMPOSE_RC=1
  AUTO_RECREATE_STALE_CONTAINERS=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *recriar* ]]
}

@test "Docker: arquivo de Compose sumiu => não recria às cegas, segue TODO" {
  MOCK_STALE=1
  MOCK_COMPOSE_DIR="$BATS_TEST_TMPDIR"
  MOCK_COMPOSE_SVC='web'
  MOCK_COMPOSE_FILES="$BATS_TEST_TMPDIR/nao-existe.yml"
  AUTO_RECREATE_STALE_CONTAINERS=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [ ! -e "${MOCK_RECREATED}.args" ]
}

@test "Docker: container fora do Compose não é recriado nem com AUTO_RECREATE" {
  MOCK_STALE=1
  AUTO_RECREATE_STALE_CONTAINERS=1
  update_docker_images && rc=0 || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [ ! -e "${MOCK_RECREATED}.args" ]
}
