#!/usr/bin/env bash
# lib/testable/containers_pure.sh — funções puras extraídas de lib/steps/containers.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# _docker_is_remote_image — classifica se imagem Docker é remota (deve ser puxada)
# $1 = imagem (ex: postgres:latest, minha-imagem:dev, ghcr.io/user/app:tag)
_docker_is_remote_image() {
  local img="$1"
  # Corta APENAS a tag (último ':'), preservando registries com porta
  local repo="${img%:*}"
  # Remota = contém '/' OU é imagem oficial Docker Hub conhecida
  [[ "$repo" == *"/"* ]] && return 0
  case "$repo" in
    redis|postgres|mongo|mysql|mariadb|nginx|apache|alpine|ubuntu|debian|python|node|golang|rust|ruby|php|java|openjdk|eclipse-temurin|selenium|firefox|chrome|chromium)
      return 0 ;;
  esac
  return 1
}

# docker_info_timeout_seconds — timeout para docker info (configurável)
docker_info_timeout_seconds() {
  local timeout_s="${DOCKER_INFO_TIMEOUT_S:-5}"
  if [[ "$timeout_s" =~ ^[0-9]+$ ]] && (( timeout_s > 0 )); then
    printf '%s\n' "$timeout_s"
  else
    printf '5\n'
  fi
}