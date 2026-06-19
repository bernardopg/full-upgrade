#!/usr/bin/env bash
# steps.d/rtk — RTK (Rust Token Killer), proxy de CLI do autor
# shellcheck shell=bash

# Atualiza o rtk para a última release publicada no GitHub.
# O rtk é distribuído como binário de release (não está no crates.io sob o nome
# "rtk" — há colisão com outro crate) e não possui subcomando de self-update.
# Estratégia: descobre a última tag pelo redirect 302 de /releases/latest (sem
# API, sem rate limit); só atualiza se a versão local estiver desatualizada;
# baixa o tarball do alvo (uname -m) + checksums.txt, VERIFICA o sha256 (recusa
# instalar binário não verificado) e substitui o binário no diretório atual.
update_rtk() {
  local rtk_bin
  rtk_bin="${RTK_BIN:-$(command -v rtk 2>/dev/null || true)}"

  if [[ -z "$rtk_bin" || ! -x "$rtk_bin" ]]; then
    log "  rtk não encontrado no PATH (defina RTK_BIN no config se necessário)."
    return 0
  fi

  if ! has curl; then
    log "  curl ausente; não é possível atualizar o rtk."
    return 0
  fi

  local repo="rtk-ai/rtk"
  local current
  # "rtk 0.39.0" -> "0.39.0". O rtk pode crashar (bug conhecido); || true protege.
  current="$("$rtk_bin" --version 2>/dev/null | awk 'NR==1{print $2}' || true)"
  log "  rtk em: ${rtk_bin} (versão atual: ${current:-desconhecida})"

  # Alvo de release por arquitetura (Linux). Espelha o install.sh oficial.
  local arch target
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  target="x86_64-unknown-linux-musl" ;;
    aarch64) target="aarch64-unknown-linux-gnu" ;;
    *)
      log "  Arquitetura ${arch} não suportada pelo atualizador do rtk; pulando."
      return 0
      ;;
  esac

  # Última versão: segue o redirect 302 de /releases/latest e pega o último
  # segmento da URL efetiva (ex.: .../releases/tag/v0.42.4 -> v0.42.4).
  local effective tag latest
  effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                 "https://github.com/${repo}/releases/latest" 2>/dev/null || true)"
  tag="${effective##*/}"            # ex.: v0.42.4
  latest="${tag#v}"

  if [[ -z "$latest" ]]; then
    log "  Não foi possível determinar a última versão do rtk (rede/GitHub indisponível)."
    return "$RC_WARN"
  fi

  if [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  rtk já está na versão mais recente (${current})."
    return 0
  fi

  log "  Atualizando rtk: ${current:-?} → ${latest}"

  local tmp
  tmp="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "$tmp" || ! -d "$tmp" ]]; then
    log "  mktemp falhou; não é possível atualizar o rtk."
    return "$RC_WARN"
  fi

  local base="https://github.com/${repo}/releases/download/${tag}"
  local asset="rtk-${target}.tar.gz"

  if ! run_network_cmd curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" >/dev/null \
     || ! run_network_cmd curl -fsSL "${base}/checksums.txt" -o "${tmp}/checksums.txt" >/dev/null; then
    rm -rf "$tmp"
    log "  Falha de rede ao baixar o release do rtk."
    return "$RC_WARN"
  fi

  # Verificação de integridade OBRIGATÓRIA: recusa instalar binário não verificado.
  if ! ( cd "$tmp" && grep -F "$asset" checksums.txt | sha256sum -c - ) >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"
    log "  Checksum do rtk não confere; abortando (binário não verificado)."
    return 1
  fi

  if ! tar -xzf "${tmp}/${asset}" -C "$tmp" rtk 2>>"$LOG_FILE" || [[ ! -f "${tmp}/rtk" ]]; then
    rm -rf "$tmp"
    log "  Falha ao extrair o binário rtk do tarball."
    return 1
  fi
  chmod +x "${tmp}/rtk" 2>/dev/null || true

  # Substitui no mesmo diretório do rtk atual. Em Linux, trocar o arquivo de um
  # binário em execução é seguro (processos vivos mantêm o inode antigo).
  if ! mv -f "${tmp}/rtk" "$rtk_bin" 2>>"$LOG_FILE" \
     && ! cp -f "${tmp}/rtk" "$rtk_bin" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    log "  Falha ao instalar o binário rtk em ${rtk_bin}."
    return 1
  fi
  rm -rf "$tmp"

  hash -r 2>/dev/null || true
  local newver
  newver="$("$rtk_bin" --version 2>/dev/null | awk 'NR==1{print $2}' || true)"
  log "  rtk atualizado para ${newver:-$latest}."
  return 0
}
