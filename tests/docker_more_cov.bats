#!/usr/bin/env bats
# tests/docker_more_cov.bats — Docker ausente/daemon fora, inventário vazio,
# origem não verificável, prune de dangling, ps falho, container sem imagem,
# Compose em diretório que sumiu e o update do Flatpak. Mesmo docker() falso
# de tests/docker_update.bats; nada fala com um daemon de verdade.
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
  STEP_REASON='' QUIET=0
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


@test "Docker: ausente, daemon fora e inventário vazio" {
  has() { return 1; }
  run update_docker_images
  [[ "$output" == *"docker não encontrado"* ]]
  has() { [[ "$1" == docker ]]; }
  docker_daemon_accessible() { return 1; }
  run update_docker_images
  [[ "$output" == *"Docker daemon não acessível após 5s"* ]]
  docker_daemon_accessible() { return 0; }
  MOCK_IMAGES='<none>:<none>'
  run update_docker_images
  [[ "$output" == *"Sem imagens Docker locais"* ]]
}

@test "Docker: origem da imagem não verificável vira warn" {
  _real_docker="$(declare -f docker)"
  docker() { [[ "$*" == *com.docker.compose.project* ]] && return 1; eval "${_real_docker/docker ()/_d ()}"; _d "$@"; }
  update_docker_images >/dev/null || rc=$?
  [ "${rc:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "Docker: não foi possível verificar a origem de caddy:2.11-alpine" ]
}

@test "Docker: dangling removidas, ps falho e container sem imagem não verificados" {
  eval "$(declare -f docker | sed '1s/docker ()/_docker_base ()/')"
  docker() {
    case "$*" in
      'image ls '*) printf 'abc\ndef\n' ;;
      'image prune -f') echo podado >> "$BATS_TEST_TMPDIR/prune" ;;
      'ps -q') [[ -n "${PS_FAIL:-}" ]] && return 1; printf 'c1\n' ;;
      'container inspect '*) printf '/semimg\x1f\x1f\n' ;;
      *) _docker_base "$@" ;;
    esac
  }
  update_docker_images >/dev/null || rc=$?
  [ "${rc:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "Docker: imagem de container não verificada: /semimg" ]
  [ -s "$BATS_TEST_TMPDIR/prune" ]
  unset rc
  PS_FAIL=1 update_docker_images >/dev/null || rc=$?
  [[ "$STEP_REASON" == *"listagem de containers"* ]]
}

@test "Docker: Compose em diretório que sumiu não é recriado" {
  MOCK_STALE=1 AUTO_RECREATE_STALE_CONTAINERS=1
  MOCK_COMPOSE_DIR="$BATS_TEST_TMPDIR/sumiu" MOCK_COMPOSE_SVC=web
  run update_docker_images
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"sumiu);"*"recriação manual"* ]]
  [ ! -e "${MOCK_RECREATED}.args" ]
}

@test "flatpak: appstream e update" {
  flatpak() { echo "flatpak $*" >> "$BATS_TEST_TMPDIR/fp"; [[ "$1 $2" == "update --appstream" ]] && printf 'Atualizando\nNothing to do.\n'; return 0; }
  run update_flatpak
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando"* ]]
  [[ "$output" != *"Nothing to do"* ]]
  grep -qx "flatpak update -y" "$BATS_TEST_TMPDIR/fp"
}

@test "docker_daemon_accessible consulta o docker info com teto" {
  load stub_helper
  stub_path_init
  stub_script docker '[[ "$1" == info ]] && exit "${INFO_RC:-0}"'
  unset -f docker docker_daemon_accessible
  source "${FU_LIB}/steps/packages.sh"
  run docker_daemon_accessible
  [ "$status" -eq 0 ]
  INFO_RC=1 run docker_daemon_accessible
  [ "$status" -eq 1 ]
}
