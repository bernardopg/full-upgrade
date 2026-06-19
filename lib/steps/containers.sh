#!/usr/bin/env bash
# steps/containers.sh — docker, flatpak, snap
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

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
    selenium|firefox|chrome|chromium) return 0 ;;
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
  mapfile -t images < <(
    docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
      | grep -v '<none>' \
      | sort -u
  )

  if (( ${#images[@]} == 0 )); then
    log "  Sem imagens Docker locais."
    return 0
  fi

  local -a remote_images=() pulled=() failed=() skipped=()
  local img

  for img in "${images[@]}"; do
    if _docker_is_remote_image "$img"; then
      remote_images+=("$img")
    else
      skipped+=("$img")
    fi
  done

  if (( ${#remote_images[@]} == 0 )); then
    log "  Sem imagens Docker remotas para atualizar (${#skipped[@]} locais ignoradas)."
    return 0
  fi

  log "  Atualizando ${#remote_images[@]} imagem(ns) Docker remota(s)..."
  (( ${#skipped[@]} > 0 )) && log "  Imagens locais (builds) ignoradas: ${skipped[*]}"

  local output rc
  for img in "${remote_images[@]}"; do
    log "  docker pull ${img}"
    output="$(_retry 2 docker pull "$img" 2>&1)"
    rc=$?
    if (( rc == RC_WARN )); then
      log "  docker pull ${img}: falha de rede transitória após 2 tentativas."
      failed+=("$img")
      continue
    fi
    if (( rc != 0 )); then
      log "  Falha ao pull ${img}"
      failed+=("$img")
    else
      if printf '%s\n' "$output" | grep -q 'Downloaded newer image'; then
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
    docker image prune -f >> "$LOG_FILE" 2>&1 || true
  fi

  # Alertar containers usando imagem stale
  local -a stale_containers=()
  local container_name container_img container_imgid current_id
  while IFS=$'\t' read -r container_name container_img container_imgid; do
    current_id="$(docker image inspect "$container_img" --format '{{.Id}}' 2>/dev/null || true)"
    [[ -n "$current_id" ]] || continue
    if [[ "sha256:${container_imgid}" != "$current_id" ]]; then
      stale_containers+=("${container_name}(${container_img})")
    fi
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}\t{{.ImageID}}' 2>/dev/null)

  if (( ${#stale_containers[@]} > 0 )); then
    log "  ${C_YELLOW}Aviso: containers usando imagem desatualizada (restart necessário):${C_RESET}"
    local sc
    for sc in "${stale_containers[@]}"; do
      log "    ${sc}"
    done
  fi

  (( ${#failed[@]} > 0 )) && { log "  Falha ao pull: ${failed[*]}"; return 1; }
  return 0
}


update_flatpak() {
  # Atualizar metadados appstream antes do upgrade de apps
  local appstream_output
  appstream_output="$(flatpak update --appstream 2>&1)"
  log_raw "$appstream_output"
  printf '%s\n' "$appstream_output" | grep -v '^$' | grep -v 'Nothing to do' || true
  run_logged flatpak update -y
}


update_snap() {
  run_logged sudo snap refresh
}


