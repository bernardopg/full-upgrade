#!/usr/bin/env bash
# lib/steps/manual_apps.sh — helpers compartilhados pelos steps de programas
# instalados FORA de qualquer gerenciador de pacotes (sem pacman/AUR/flatpak/
# snap por trás). Os steps em si vivem no arquivo do seu domínio: CLIs de IA em
# ai.sh, segurança em security.sh, utilitários em tools.sh, e o inventário
# read-only em doctor/packages.sh (Série T4).
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

_manual_write_prefix() {
  local target="$1" dir
  dir="$(dirname "$target")"
  if [[ -w "$target" && -w "$dir" ]]; then
    printf ''
    return 0
  fi
  if has sudo && sudo -n true 2>/dev/null; then
    printf 'sudo'
    return 0
  fi
  return 1
}

# ── CLIs com update nativo que já checa sozinho ──────────────────────────────
# `pool update` (Poolside, ~/.local/bin/pool) e `purple update` comparam a versão
# instalada com a última release, verificam checksum e só baixam se houver
# novidade; atualizados, apenas dizem "already at vX". Não há --check separado,
# então chamar o update direto já é idempotente. rc: 0 ok · RC_WARN rede/falha.
_selfupdate_direct() {
  local label="$1" bin="$2"
  shift 2
  has "$bin" || { log "  ${label} não encontrado."; return 0; }
  local out rc
  out="$(run_network_cmd "$bin" update "$@")"
  rc=$?
  printf '%s\n' "$out" | log_out
  if ((rc != 0)); then
    log "  Falha ao atualizar o ${label}."
    STEP_REASON="${bin} update falhou (rc=${rc})"
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  return 0
}

# ── Binário de release do GitHub (goreleaser) sem self-update ─────────────────
# gitleaks e trufflehog saem como tar.gz com `<nome>_<versão>_checksums.txt` ao
# lado. Descobre a última tag pelo redirect de /releases/latest (sem API, sem
# rate limit), compara versão, baixa, VERIFICA o sha256 publicado e troca o
# binário no mesmo caminho. Args: <label> <bin> <owner/repo> <arch_amd64>
# <arch_arm64> — nomes de arquitetura do asset (gitleaks usa x64, trufflehog
# amd64). rc: 0 ok · RC_WARN rede · RC_TODO sem permissão · 1 checksum/instalação.
_github_release_bin_update() {
  local label="$1" bin="$2" repo="$3" arch_amd64="$4" arch_arm64="$5"
  has "$bin" || { log "  ${label} não encontrado."; return 0; }
  if ! has curl || ! has tar || ! has sha256sum; then
    log "  curl, tar e sha256sum são necessários para atualizar o ${label}."
    return 0
  fi

  local arch
  case "$(uname -m)" in
    x86_64)        arch="$arch_amd64" ;;
    aarch64|arm64) arch="$arch_arm64" ;;
    *) log "  Arquitetura $(uname -m) não suportada pelo atualizador do ${label}; pulando."; return 0 ;;
  esac

  local bin_path current
  bin_path="$(command -v "$bin")"
  current="$("$bin" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -1 || true)"
  log "  ${label} em: ${bin_path} (versão atual: ${current:-desconhecida})"

  local effective tag latest
  effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                 "https://github.com/${repo}/releases/latest" 2>/dev/null || true)"
  tag="${effective##*/}"
  latest="${tag#v}"
  if [[ ! "$latest" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    log "  Não foi possível determinar a última versão do ${label} (rede/GitHub indisponível)."
    STEP_REASON="última versão do ${label} indisponível"
    return "$RC_WARN"
  fi
  if [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  ${label} já está na versão mais recente (${current})."
    return 0
  fi

  local pfx
  if ! pfx="$(_manual_write_prefix "$bin_path")"; then
    STEP_REASON="atualize o ${label} com sudo disponível (binário em $(dirname "$bin_path"))"
    return "$RC_TODO"
  fi
  local -a sudo_pfx=()
  [[ -n "$pfx" ]] && sudo_pfx=("$pfx")

  log "  Atualizando ${label}: ${current:-?} → ${latest}"
  local tmp
  tmp="$(mktemp -d)" || { log "  mktemp falhou."; return "$RC_WARN"; }

  local base="https://github.com/${repo}/releases/download/${tag}"
  local asset="${bin}_${latest}_linux_${arch}.tar.gz" sums="${bin}_${latest}_checksums.txt"
  if ! run_network_cmd curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" >/dev/null \
     || ! run_network_cmd curl -fsSL "${base}/${sums}" -o "${tmp}/${sums}" >/dev/null; then
    rm -rf "$tmp"
    log "  Falha de rede ao baixar o release do ${label}."
    STEP_REASON="download do ${label} ${latest} falhou"
    return "$RC_WARN"
  fi

  # Integridade OBRIGATÓRIA: sem linha do asset no checksums, sha256sum -c falha.
  if ! (cd "$tmp" && grep -F " ${asset}" "$sums" | sha256sum -c -) >>"$LOG_FILE" 2>&1 \
     || ! tar -xzf "${tmp}/${asset}" -C "$tmp" "$bin" >>"$LOG_FILE" 2>&1 \
     || ! "${sudo_pfx[@]}" install -m755 "${tmp}/${bin}" "$bin_path" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    log "  Checksum, extração ou instalação do ${label} falhou; binário mantido."
    STEP_REASON="${label} ${latest} não verificado/instalado"
    return 1
  fi
  rm -rf "$tmp"
  hash -r 2>/dev/null || true
  log "  ${label} atualizado para ${latest}."
  return 0
}
