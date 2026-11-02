#!/usr/bin/env bash
# lib/steps/packages.sh — empacotadores alternativos: Docker, Flatpak e Snap
# (renomeado de containers.sh na Série T3).
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

_docker_is_remote_image() {
  local img="$1"
  # Corta APENAS a tag (último ':'), preservando registries com porta como
  # `localhost:5000/app`. Usar '%%' (guloso) cortaria no primeiro ':' e
  # classificaria errado imagens de registry com porta como locais.
  local repo="${img%:*}"
  # Remota = contém / (ghcr.io/..., n8nio/n8n) OU é imagem oficial sem prefixo de usuário
  [[ "$repo" == *"/"* ]] && return 0
  # Imagens oficiais Docker Hub conhecidas (single-name sem usuário)
  case "$repo" in
    redis|postgres|mongo|mysql|mariadb|nginx|apache|alpine|ubuntu|debian|\
    python|node|golang|rust|ruby|php|java|openjdk|eclipse-temurin|\
    selenium|firefox|chrome|chromium|caddy|archlinux) return 0 ;;
  esac
  return 1
}

# Timeout curto para a sondagem inicial. Sem isso, `docker info` pode travar
# ~75s quando o socket existe mas o daemon não responde.
docker_info_timeout_seconds() {
  local timeout_s="${DOCKER_INFO_TIMEOUT_S:-5}"
  if [[ "$timeout_s" =~ ^[0-9]+$ ]] && (( timeout_s > 0 )); then
    printf '%s\n' "$timeout_s"
  else
    printf '5\n'
  fi
}


docker_daemon_accessible() {
  local timeout_s
  timeout_s="$(docker_info_timeout_seconds)"
  timeout "$timeout_s" docker info >/dev/null 2>&1
}


# O image store containerd também cria RepoDigests para builds LOCAIS.
# Exigir nome remoto reconhecido e rejeitar builds Compose; digest sozinho
# não comprova publicação no registry. Nomes curtos desconhecidos ficam locais.
_docker_has_remote_digest() {
  _docker_is_remote_image "$1" || return 1
  local digests compose_project
  compose_project="$(docker image inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)" || return 2
  [[ -z "$compose_project" || "$compose_project" == '<no value>' ]] || return 1
  digests="$(docker image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null)" || return 2
  [[ "$digests" == *'@sha256:'* ]]
}

# Lista os containers em execução cuja imagem não é mais a da tag local (após
# um pull). Preenche DOCKER_STALE_CONTAINERS ("nome(imagem)"), DOCKER_UNVERIFIED
# e DOCKER_STALE_COMPOSE: chave "dir<US>projeto<US>arquivos" → serviços.
# docker ps não oferece .ImageID. O inspect retorna IDs completos e a
# referência usada na criação; restart não troca a imagem do container.
_docker_scan_stale_containers() {
  DOCKER_STALE_CONTAINERS=() DOCKER_UNVERIFIED=()
  unset DOCKER_STALE_COMPOSE
  declare -gA DOCKER_STALE_COMPOSE=()
  local name img imgid dir svc project files current_id ids cid metadata key
  if ! ids="$(docker ps -q 2>/dev/null)"; then
    DOCKER_UNVERIFIED+=("listagem de containers")
  fi
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    # Separador \x1f (US), não tab: tab é espaço para o `read`, e um rótulo
    # vazio no meio deslocaria os campos seguintes (arquivos virando projeto).
    if ! metadata="$(docker container inspect "$cid" --format $'{{.Name}}\x1f{{.Config.Image}}\x1f{{.Image}}\x1f{{index .Config.Labels "com.docker.compose.project.working_dir"}}\x1f{{index .Config.Labels "com.docker.compose.service"}}\x1f{{index .Config.Labels "com.docker.compose.project"}}\x1f{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)"; then
      DOCKER_UNVERIFIED+=("$cid")
      continue
    fi
    dir="" svc="" project="" files=""
    IFS=$'\x1f' read -r name img imgid dir svc project files <<<"$metadata"
    if [[ -z "$img" || -z "$imgid" ]] \
        || ! current_id="$(docker image inspect "$img" --format '{{.Id}}' 2>/dev/null)" \
        || [[ -z "$current_id" ]]; then
      DOCKER_UNVERIFIED+=("${name:-$cid}")
      continue
    fi
    [[ "${imgid#sha256:}" != "${current_id#sha256:}" ]] || continue
    DOCKER_STALE_CONTAINERS+=("${name#/}(${img})")
    if [[ -n "$dir" && -n "$svc" ]]; then
      key="${dir}"$'\x1f'"${project}"$'\x1f'"${files}"
      DOCKER_STALE_COMPOSE["$key"]+="${DOCKER_STALE_COMPOSE[$key]:+ }${svc}"
    fi
  done <<<"${ids:-}"
}

# Comando (texto) que recria os serviços de um grupo do Compose. Usa o nome de
# projeto e os arquivos gravados nos rótulos do container: `--project-directory`
# sozinho erra quando o projeto subiu com `-p` ou `-f` fora do padrão.
# `up -d` sozinho nem sempre recria: o Compose compara a configuração, e um
# repull da mesma tag não a altera (visto com postgres:18-alpine e redis:8-alpine).
_docker_compose_recreate_args() {
  local key="$1" svcs="$2" dir project files f
  IFS=$'\x1f' read -r dir project files <<<"$key"
  DOCKER_COMPOSE_ARGS=(compose --project-directory "$dir")
  [[ -n "$project" ]] && DOCKER_COMPOSE_ARGS+=(-p "$project")
  if [[ -n "$files" ]]; then
    local -a file_list=()
    IFS=',' read -r -a file_list <<<"$files"
    for f in "${file_list[@]}"; do
      [[ -n "$f" ]] && DOCKER_COMPOSE_ARGS+=(-f "$f")
    done
  fi
  local -a svc_list=()
  read -r -a svc_list <<<"$svcs"
  DOCKER_COMPOSE_ARGS+=(up -d --no-deps --force-recreate "${svc_list[@]}")
}

_docker_compose_recreate_cmd() {
  _docker_compose_recreate_args "$1" "$2"
  printf 'docker %s' "${DOCKER_COMPOSE_ARGS[*]}"
}

# AUTO_RECREATE_STALE_CONTAINERS=1: recria os serviços de Compose com imagem
# antiga (volumes e configuração preservados). Containers fora do Compose não
# têm receita de recriação e seguem como TODO. Arquivo de Compose ausente = o
# projeto mudou de lugar; não adivinha, segue TODO.
_docker_recreate_stale_compose() {
  local key dir project files f missing
  for key in "${!DOCKER_STALE_COMPOSE[@]}"; do
    IFS=$'\x1f' read -r dir project files <<<"$key"
    missing=""
    if [[ ! -d "$dir" ]]; then
      missing="$dir"
    elif [[ -n "$files" ]]; then
      local -a file_list=()
      IFS=',' read -r -a file_list <<<"$files"
      for f in "${file_list[@]}"; do
        [[ -z "$f" || -r "$f" ]] || { missing="$f"; break; }
      done
    fi
    if [[ -n "$missing" ]]; then
      log "  Compose de ${project:-$dir} não encontrado (${missing}); recriação manual."
      continue
    fi
    _docker_compose_recreate_args "$key" "${DOCKER_STALE_COMPOSE[$key]}"
    log "  Recriando ${DOCKER_STALE_COMPOSE[$key]} (${project:-$dir}) na imagem atual..."
    if ! run_logged docker "${DOCKER_COMPOSE_ARGS[@]}"; then
      log "  ${C_YELLOW}Recriação de ${DOCKER_STALE_COMPOSE[$key]} falhou; segue pendente.${C_RESET}"
    fi
  done
}

update_docker_images() {
  if ! has docker; then
    log "  docker não encontrado."
    return 0
  fi

  if ! docker_daemon_accessible; then
    log "  Docker daemon não acessível após $(docker_info_timeout_seconds)s; pulando."
    return 0
  fi

  local -a images=()
  local inventory
  if ! inventory="$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null)"; then
    STEP_REASON="Docker: inventário de imagens não verificado"
    return "$RC_WARN"
  fi
  mapfile -t images < <(
    printf '%s\n' "$inventory" | awk 'NF && !/<none>/' | LC_ALL=C sort -u
  )

  if (( ${#images[@]} == 0 )); then
    log "  Sem imagens Docker locais."
    return 0
  fi

  local -a remote_images=() pulled=() failed=() transient=() skipped=()
  local img digest_rc

  for img in "${images[@]}"; do
    _docker_has_remote_digest "$img" && digest_rc=0 || digest_rc=$?
    if (( digest_rc == 0 )); then
      remote_images+=("$img")
    elif (( digest_rc == 2 )); then
      STEP_REASON="Docker: não foi possível verificar a origem de ${img}"
      return "$RC_WARN"
    else
      skipped+=("$img")
    fi
  done

  if (( ${#remote_images[@]} == 0 )); then
    log "  Sem imagens Docker remotas para atualizar (${#skipped[@]} locais ignoradas)."
  else
    log "  Atualizando ${#remote_images[@]} imagem(ns) Docker remota(s)..."
  fi
  (( ${#skipped[@]} > 0 )) && log "  Imagens locais (builds) ignoradas: ${skipped[*]}"

  local output rc
  for img in "${remote_images[@]}"; do
    log "  docker pull ${img}"
    output="$(_retry 2 docker pull "$img" 2>&1)"
    rc=$?
    if (( rc == RC_WARN )); then
      log "  docker pull ${img}: falha de rede transitória após 2 tentativas."
      transient+=("$img")
      continue
    fi
    if (( rc != 0 )); then
      log "  Falha ao pull ${img}"
      failed+=("$img")
    else
      if grep -q 'Downloaded newer image' <<<"$output"; then
        log "  Atualizado: ${img}"
        pulled+=("$img")
      else
        log "  Já atualizado: ${img}"
      fi
    fi
  done

  # Remover imagens dangling geradas pelos pulls
  local dangling
  dangling="$(docker image ls --filter 'dangling=true' --format '{{.ID}}' 2>/dev/null | wc -l)"
  if (( dangling > 0 )); then
    log "  Removendo ${dangling} imagem(ns) dangling..."
    docker image prune -f 2>&1 | _strip_ansi >> "$LOG_FILE" || true
  fi

  _docker_scan_stale_containers

  if (( ${#DOCKER_STALE_CONTAINERS[@]} > 0 )) && (( ${AUTO_RECREATE_STALE_CONTAINERS:-0} )) \
      && (( ${#DOCKER_STALE_COMPOSE[@]} > 0 )); then
    _docker_recreate_stale_compose
    # Reverifica: só sai do TODO o que o inspect confirma na imagem atual.
    _docker_scan_stale_containers
  fi

  if (( ${#DOCKER_STALE_CONTAINERS[@]} > 0 )); then
    log "  ${C_YELLOW}Containers com imagem antiga: recriar pelo projeto/Compose, preservando volumes e configuração:${C_RESET}"
    local sc key
    for sc in "${DOCKER_STALE_CONTAINERS[@]}"; do
      log "    ${sc}"
    done
    for key in "${!DOCKER_STALE_COMPOSE[@]}"; do
      remediation "$(_docker_compose_recreate_cmd "$key" "${DOCKER_STALE_COMPOSE[$key]}")"
    done
    (( ${AUTO_RECREATE_STALE_CONTAINERS:-0} )) \
      || log "  Dica: AUTO_RECREATE_STALE_CONTAINERS=1 recria sozinho os containers de Compose."
  fi

  if (( ${#failed[@]} > 0 )); then
    STEP_REASON="Docker: falha ao pull: ${failed[*]}"
    log "  ${STEP_REASON}"
    return 1
  fi
  if (( ${#transient[@]} > 0 )); then
    STEP_REASON="Docker: pull adiado por falha transitória: ${transient[*]}"
    return "$RC_WARN"
  fi
  if (( ${#DOCKER_UNVERIFIED[@]} > 0 )); then
    STEP_REASON="Docker: imagem de container não verificada: ${DOCKER_UNVERIFIED[*]}"
    return "$RC_WARN"
  fi
  if (( ${#DOCKER_STALE_CONTAINERS[@]} > 0 )); then
    STEP_REASON="Docker: recriar containers com imagem antiga: ${DOCKER_STALE_CONTAINERS[*]}"
    return "$RC_TODO"
  fi
  return 0
}


update_flatpak() {
  # Atualizar metadados appstream antes do upgrade de apps
  local appstream_output
  appstream_output="$(flatpak update --appstream 2>&1)"
  log_raw "$appstream_output"
  printf '%s\n' "$appstream_output" | grep -v '^$' | grep -v 'Nothing to do' | log_out || true
  run_logged flatpak update -y
}


# Atualiza snaps instalados. Autorremedia os dois modos de falha reais do snapd
# no Arch: (a) nenhum snap instalado — `snap refresh` ainda assim consulta a
# store e falha por rede/proxy sem nada a ganhar; (b) o kernel foi atualizado
# neste mesmo run, os módulos do kernel em execução sumiram e o snapd não
# consegue montar o squashfs ("cannot setup loop device"). O (b) não é um erro
# do sistema: é um reboot pendente, e virava `fail` sem motivo no resumo.
update_snap() {
  local listing
  listing="$(snap list 2>&1)"
  if grep -qiE 'no snaps are installed|nenhum snap' <<<"$listing"; then
    log "  Nenhum snap instalado; refresh dispensado."
    return 0
  fi

  local out rc
  out="$(sudo snap refresh 2>&1)"
  rc=$?
  printf '%s\n' "$out" | log_stream
  (( rc == 0 )) && return 0

  if grep -qiE 'cannot mount squashfs|loop device|does not fully support snapd' <<<"$out"; then
    # Tentativa de remediação: o módulo `loop` costuma só não estar carregado.
    if sudo modprobe loop >/dev/null 2>&1; then
      log "  Módulo 'loop' carregado; repetindo o refresh..."
      if run_logged sudo snap refresh; then
        return 0
      fi
    fi
    log "  ${C_YELLOW}snapd não consegue montar squashfs — o módulo 'loop' do kernel em execução não está disponível.${C_RESET}"
    remediation "reinicie para carregar os módulos do kernel novo; o refresh dos snaps entra no próximo run"
    STEP_REASON="snapd sem módulo loop (reboot pendente após upgrade de kernel)"
    return "$RC_WARN"
  fi

  return "$rc"
}


