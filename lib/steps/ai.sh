#!/usr/bin/env bash
# steps/ai.sh — CLIs de IA genéricos (claude code)
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module (STEP_REASON etc.)

# H2 — helper puro: extrai a versão de `ollama --version`
# ("ollama version is X.Y.Z" → "X.Y.Z"). Vazio se não casar.
parse_ollama_version() {
  sed -nE 's/.*version is[[:space:]]+([0-9][^[:space:]]*).*/\1/p' | head -1
}

# H2 — atualiza o Ollama, instalado por script próprio em /usr/local/bin (fora do
# pacman e do npm). Default: só reporta a versão (não muta), pois o update oficial
# é `curl … install.sh | sh` (script remoto + sudo). Sob OLLAMA_SELF_UPDATE=1,
# reexecuta o instalador oficial. Sem rede → RC_WARN; falha do instalador → RC_WARN.
update_ollama() {
  if ! has ollama; then
    log "  ollama não encontrado no PATH."
    return 0
  fi
  local before
  before="$(ollama --version 2>/dev/null | parse_ollama_version)"
  log "  ollama atual: ${before:-?}"

  if (( ${OLLAMA_SELF_UPDATE:-0} == 0 )); then
    log "  OLLAMA_SELF_UPDATE=0; atualização automática desligada."
    log "  Para atualizar manualmente: curl -fsSL https://ollama.com/install.sh | sh"
    return 0
  fi
  if ! has curl; then
    log "  curl não instalado; não é possível rodar o instalador do Ollama."
    return 0
  fi

  log "  Baixando e executando o instalador oficial do Ollama..."
  local script rc
  script="$(run_network_cmd curl -fsSL https://ollama.com/install.sh)"
  rc=$?
  if (( rc == RC_WARN )); then
    log "  Ollama: falha de rede ao baixar o instalador."
    STEP_REASON="rede indisponível para o instalador do Ollama"
    return "$RC_WARN"
  fi
  if (( rc != 0 )) || [[ -z "${script//[[:space:]]/}" ]]; then
    log "  Ollama: não foi possível obter o instalador."
    STEP_REASON="instalador do Ollama indisponível"
    return "$RC_WARN"
  fi
  if printf '%s' "$script" | sh; then
    local after
    after="$(ollama --version 2>/dev/null | parse_ollama_version)"
    log "  ollama agora: ${after:-?}"
    return 0
  fi
  log "  Ollama: instalador retornou erro."
  STEP_REASON="instalador do Ollama falhou"
  return "$RC_WARN"
}

# H1 — atualiza o opencode, instalado fora do npm (~/.opencode/bin) via seu
# subcomando próprio `opencode upgrade`. Falha de rede → RC_WARN; outra falha do
# upgrade também → RC_WARN (não-fatal, não derruba o run). Loga versão antes/depois.
update_opencode() {
  if ! has opencode; then
    log "  opencode não encontrado no PATH."
    return 0
  fi
  local before after out rc
  before="$(opencode --version 2>/dev/null | head -1)"
  log "  opencode atual: ${before:-?}"
  out="$(run_network_cmd opencode upgrade)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^$' || true
  if (( rc == RC_WARN )); then
    log "  opencode: falha de rede ao atualizar."
    STEP_REASON="rede indisponível para opencode upgrade"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  opencode: falha ao atualizar (rc=${rc})."
    STEP_REASON="opencode upgrade falhou"
    return "$RC_WARN"
  fi
  after="$(opencode --version 2>/dev/null | head -1)"
  log "  opencode agora: ${after:-?}"
  return 0
}

update_claude_code() {
  local claude_bin
  claude_bin="$(command -v claude || true)"
  if [[ -z "$claude_bin" ]]; then
    log "  claude não encontrado no PATH."
    return 0
  fi
  local output rc
  output="$(claude update 2>&1)"
  rc=$?
  log_raw "$output"
  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
}

# H5 — detecta se o kimi (bin) é um pacote npm global. Retorna o spec npm
# ("@moonshot-ai/kimi-code") ou vazio. Impuro (consulta `npm ls -g`).
kimi_npm_package() {
  npm ls -g --depth=0 2>/dev/null | grep -oE '@moonshot-ai/kimi-code' | head -1
}

# H5 — atualiza o kimi (Moonshot Kimi Code CLI). O kimi é publicado no npm como
# @moonshot-ai/kimi-code (bin "kimi"), então quando instalado via npm global JÁ
# É coberto pelo step "Atualizar npm global" — este step evita duplicar o
# 'npm install' e apenas confirma a cobertura. Para instalações standalone
# futuras (sem método conhecido), retorna RC_TODO.
update_kimi() {
  if ! has kimi; then
    log "  kimi não encontrado no PATH."
    return 0
  fi
  local before
  before="$(kimi --version 2>/dev/null | head -1)"
  log "  kimi atual: ${before:-?}"
  if [[ -n "$(kimi_npm_package)" ]]; then
    log "  kimi é pacote npm global (@moonshot-ai/kimi-code); já coberto por 'Atualizar npm global'."
    return 0
  fi
  log "  kimi instalado fora do npm; sem método de update automático conhecido."
  STEP_REASON="método de update do kimi não detectado (não-npm)"
  return "$RC_TODO"
}



# Atualiza as "agent skills" globais via o CLI `skills` (rodado por npx). As
# skills ficam em ~/.agents/skills e são compartilhadas entre agentes (Claude
# Code, Codex, Cline, Amp…); inclui caveman/cavecrew, 9router-*, last30days e
# quaisquer outras adicionadas pelo usuário. Roda por presença de npx + do
# diretório de skills; é idempotente (reporta "up to date" quando nada muda).
# Cobre o pedido "atualizar o caveman" num único passo. Falha de rede => RC_WARN.
update_agent_skills() {
  has npx || { log "  npx não encontrado; pulando update de agent skills."; return 0; }
  if [[ ! -d "${HOME}/.agents/skills" ]]; then
    log "  Nenhuma agent skill global instalada (~/.agents/skills ausente)."
    return 0
  fi

  log "  Atualizando agent skills globais (caveman, cavecrew, 9router-*…) via 'npx skills update --global'…"
  local output rc
  output="$(npx --yes skills update --global 2>&1)"
  rc=$?
  printf '%s\n' "$output" | _strip_ansi >> "$LOG_FILE"

  # Resumo limpo no terminal: descarta ruído ("Checking…") e linhas vazias.
  local clean
  clean="$(printf '%s\n' "$output" | _strip_ansi | grep -ivE '^[[:space:]]*$|Checking skills from source|Checking for skill updates' | tail -6)"
  if [[ -n "${clean//[[:space:]]/}" ]]; then
    while IFS= read -r _l; do [[ -n "${_l//[[:space:]]/}" ]] && log "  ${_l}"; done <<< "$clean"
  fi

  if (( rc != 0 )); then
    log "  Falha ao atualizar agent skills (rede/registro indisponível)."
    return "$RC_WARN"
  fi
  return 0
}
