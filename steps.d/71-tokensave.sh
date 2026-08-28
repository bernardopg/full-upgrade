#!/usr/bin/env bash
# steps.d/tokensave — atualização do TokenSave pelo self-updater oficial.
# shellcheck shell=bash
# shellcheck disable=SC2034 # STEP_REASON é consumido pelo framework em core.sh

# Extrai somente a versão semântica de uma linha de versão ou tag GitHub.
_tokensave_version() {
  [[ "$1" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Fallback read-only para quando o updater Rust não alcança GitHub, mas curl sim.
# Não instala nada por este caminho: só evita um aviso falso quando a API oficial
# confirma que o binário local já é a release atual.
_tokensave_latest_version() {
  local payload
  payload="$(curl -fsSL --connect-timeout 10 --max-time 30 \
    'https://api.github.com/repos/aovestdipaperino/tokensave/releases/latest')" || return 1
  [[ "$payload" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"v?([0-9]+\.[0-9]+\.[0-9]+)\" ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

update_tokensave() {
  local tokensave_bin before after output rc installed latest

  tokensave_bin="${TOKENSAVE_BIN:-$(command -v tokensave 2>/dev/null || true)}"

  if [[ -z "$tokensave_bin" || ! -x "$tokensave_bin" ]]; then
    log "  TokenSave não encontrado no PATH (defina TOKENSAVE_BIN no config se necessário)."
    return 0
  fi

  before="$("$tokensave_bin" --version 2>/dev/null | head -1 || true)"
  log "  TokenSave em: ${tokensave_bin} (versão atual: ${before:-desconhecida})"

  output="$(_retry 2 "$tokensave_bin" upgrade 2>&1)"
  rc=$?
  # _retry já gravou a saída crua no log; aqui é só exibição.
  [[ -n "${output//[[:space:]]/}" ]] && printf '%s\n' "$output" | _strip_ansi | log_out

  if (( rc == RC_WARN )); then
    installed="$(_tokensave_version "$before" 2>/dev/null || true)"
    latest="$(_tokensave_latest_version 2>/dev/null || true)"
    if [[ -n "$installed" && "$installed" == "$latest" ]]; then
      log "  Updater do TokenSave sem acesso ao GitHub, mas a API oficial confirma que ${installed} já é a versão atual."
      return 0
    fi
    STEP_REASON="rede indisponível para tokensave upgrade"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  TokenSave: self-update falhou (rc=${rc}); instalação atual foi preservada."
    STEP_REASON="tokensave upgrade falhou"
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  after="$("$tokensave_bin" --version 2>/dev/null | head -1 || true)"
  log "  TokenSave após upgrade: ${after:-versão não detectada}."
  return 0
}
