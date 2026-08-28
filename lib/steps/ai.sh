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

  # Otimização: o instalador oficial (curl|sh) leva ~20s mesmo quando o Ollama já
  # está atual. Antes de rodá-lo, compara a versão local com a última release no
  # GitHub (via o redirect 302 de /releases/latest, sem API/rate-limit) e pula se
  # já estiver na mais recente. Falha de rede aqui não bloqueia — cai no instalador.
  local effective tag latest
  effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                 "https://github.com/ollama/ollama/releases/latest" 2>/dev/null || true)"
  tag="${effective##*/}"; latest="${tag#v}"
  if [[ -n "$latest" && -n "$before" ]] && ! version_is_outdated "$before" "$latest"; then
    log "  ollama já está na versão mais recente (${before}); pulando instalador."
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
  printf '%s\n' "$out" | grep -v '^$' | log_out || true
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

# H1 — atualiza o pi (pi-coding-agent, pacote npm @earendil-works/pi-coding-agent).
# Como o pi tem self-update nativo (`pi update`, que reexecuta o npm por baixo dos
# panos e nunca pede confiança de projeto), usamos o updater oficial em vez de
# deferir para o step 'Atualizar npm global' — mesma filosofia do opencode/claude.
#
# São três fases, porque `pi update` sozinho cobre só o binário e o próprio pi
# avisa "Extensions are skipped. Run pi update --extensions":
#   1) `pi update`              — self-update do binário;
#   2) `pi update --extensions` — pacotes/extensões instalados no pi;
#   3) `pi update --models`     — catálogos de modelos (a "lista de IA": modelos
#                                 com ferramentas de cada provedor).
# Idempotente (reporta "already up to date" quando nada muda). Falha de rede =>
# RC_WARN; outra falha do updater => RC_WARN (não derruba o run). As fases 2 e 3
# não abortam uma à outra: o binário já foi atualizado na fase 1, então um
# provedor fora do ar não pode mascarar o sucesso do self-update. Loga a versão
# antes/depois.
update_pi() {
  if ! has pi; then
    log "  pi não encontrado no PATH."
    return 0
  fi
  local before after out rc
  before="$(pi --version 2>/dev/null | head -1)"
  log "  pi atual: ${before:-?}"

  # 1) Self-update do binário (reinstala o pacote npm internamente).
  out="$(run_node_network_cmd pi update)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^$' | log_out || true
  if (( rc == RC_WARN )); then
    log "  pi: falha de rede ao atualizar."
    STEP_REASON="rede indisponível para pi update"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  pi: falha ao atualizar (rc=${rc})."
    STEP_REASON="pi update falhou"
    return "$RC_WARN"
  fi

  # 2) Extensões/pacotes instalados no pi. O `pi update` acima NÃO as toca (ele
  # mesmo imprime "Extensions are skipped"), então sem esta fase as extensões
  # ficariam permanentemente defasadas. Best-effort: registra o motivo mas não
  # retorna ainda, para a fase 3 rodar mesmo assim.
  local degraded=""
  log "  Atualizando extensões do pi via 'pi update --extensions'…"
  out="$(run_node_network_cmd pi update --extensions)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^$' | log_out || true
  if (( rc == RC_WARN )); then
    log "  pi: falha de rede ao atualizar extensões."
    degraded="rede indisponível para pi update --extensions"
  elif (( rc != 0 )); then
    log "  pi: falha ao atualizar extensões (rc=${rc}); binário atualizado."
    degraded="pi update --extensions falhou"
  fi

  # 3) Refresca a "lista de IA" — catálogos de modelos com ferramentas por
  # provedor (OpenAI, Anthropic, Google…). Idempotente; falha aqui não derruba o
  # run (o binário já foi atualizado acima).
  log "  Refrescando catálogos de modelos (lista de IA) via 'pi update --models'…"
  out="$(run_node_network_cmd pi update --models)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^$' | log_out || true
  if (( rc == RC_WARN )); then
    log "  pi: falha de rede ao refrescar catálogos de modelos (lista de IA)."
    degraded="rede indisponível para pi update --models"
  elif (( rc != 0 )); then
    # O pi reporta timeout do refresh como "Model catalog refresh timed out" —
    # texto que NÃO casa com NETWORK_TRANSIENT_RE (que exige "connection/operation
    # /request timed out"), então run_network_cmd não o classifica como rede.
    # Não é transitório nem de rede: é o limite interno de 15s hardcoded do
    # 'pi update --models' (package-manager-cli.js do pi, AbortController) para
    # refrescar TODOS os catálogos de provedores — máquinas com vários provedores
    # estouram sempre. Binário e extensões já foram atualizados acima; o catálogo
    # fica levemente defasado até o upstream do pi subir o limite.
    if grep -qiE 'timed out|timeout|tempo esgotado' <<<"$out"; then
      log "  pi: timeout ao refrescar catálogos de modelos (limite interno de 15s do pi); binário atualizado."
      degraded="timeout no refresh de catálogos do pi (limite interno de 15s do pi; conhecido upstream)"
    else
      log "  pi: falha ao refrescar catálogos de modelos (rc=${rc}); binário atualizado."
      degraded="pi update --models falhou"
    fi
  fi

  after="$(pi --version 2>/dev/null | head -1)"
  log "  pi agora: ${after:-?}"

  if [[ -n "$degraded" ]]; then
    STEP_REASON="$degraded"
    return "$RC_WARN"
  fi
  return 0
}

# Diretório de versões do instalador nativo do Claude Code. O updater baixa o
# binário completo (~300 MB) para <dir>/<versão> e só no fim move o symlink
# ~/.local/bin/claude. Parametrizável para teste.
CLAUDE_NATIVE_VERSIONS_DIR="${CLAUDE_NATIVE_VERSIONS_DIR:-${HOME}/.local/share/claude/versions}"

# Remove binários de versão truncados (vazios ou sem bit de execução) deixados
# por um download interrompido. Quando o timeout do catálogo mata o step no meio
# do download, o arquivo parcial sobrevive — e o instalador nativo passa a ver a
# versão como "já baixada", nunca retentando: o CLI congela na versão antiga
# enquanto o step reporta apenas o timeout. Varrer antes e depois torna o step
# idempotente mesmo tendo sido morto com SIGKILL (quando nenhum trap roda).
# Parâmetro: $1 = diretório de versões (default: CLAUDE_NATIVE_VERSIONS_DIR).
claude_prune_partial_versions() {
  local dir="${1:-$CLAUDE_NATIVE_VERSIONS_DIR}"
  local f pruned=0
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    # -s cobre o stub de 0 byte; -x cobre o download que morreu antes do chmod.
    if [[ ! -s "$f" || ! -x "$f" ]]; then
      rm -f -- "$f" && pruned=$((pruned + 1))
    fi
  done
  if ((pruned > 0)); then
    log "  Removido(s) ${pruned} binário(s) truncado(s) em ${dir} (download interrompido)."
  fi
  return 0
}

# H1 — atualiza o Claude Code CLI pelo instalador nativo (`claude update`).
# Falha de rede => RC_WARN e falha do updater => RC_WARN, alinhado aos steps
# irmãos (opencode/pi/ollama): uma queda de rede transitória não pode marcar o
# run inteiro como falho. Varre binários truncados antes e depois e valida o
# symlink no fim (ver claude_prune_partial_versions).
update_claude_code() {
  local claude_bin
  claude_bin="$(command -v claude || true)"
  if [[ -z "$claude_bin" ]]; then
    log "  claude não encontrado no PATH."
    return 0
  fi

  # Limpa o lixo de um run anterior interrompido antes de tentar de novo; sem
  # isso o updater nativo pula o download e o CLI nunca sai da versão velha.
  # O diretório vai explícito (e não pelo default do parâmetro) para o step
  # continuar legível sobre o que está varrendo.
  claude_prune_partial_versions "$CLAUDE_NATIVE_VERSIONS_DIR"

  local output rc
  output="$(run_network_cmd claude update)"
  rc=$?
  printf '%s\n' "$output" | grep -v '^$' | log_out || true

  claude_prune_partial_versions "$CLAUDE_NATIVE_VERSIONS_DIR"

  # Pós-condição barata: confere o symlink no filesystem em vez de executar o
  # binário de ~300 MB só para ler a versão. Se a varredura acima apagou o alvo,
  # o symlink fica pendurado e cai aqui como aviso acionável.
  local target
  target="$(readlink -f -- "$claude_bin" 2>/dev/null || true)"
  if [[ "$target" == "$CLAUDE_NATIVE_VERSIONS_DIR"/* ]] && [[ ! -s "$target" || ! -x "$target" ]]; then
    log "  Instalação do Claude Code incompleta: ${claude_bin} não aponta para um binário utilizável."
    STEP_REASON="download do Claude Code ficou incompleto; rode 'claude update' novamente"
    return "$RC_WARN"
  fi

  # O instalador nativo falha por rede com ECONNREFUSED/fetch failed cru; o
  # run_network_cmd já traduz isso em RC_WARN. Qualquer outra falha do updater
  # também vira aviso: o CLI antigo continua utilizável.
  if (( rc == RC_WARN )); then
    log "  claude: falha de rede ao atualizar."
    STEP_REASON="rede indisponível para claude update"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  claude: falha ao atualizar (rc=${rc})."
    STEP_REASON="claude update falhou"
    return "$RC_WARN"
  fi

  return 0
}

# H5 — detecta se o kimi (bin) é um pacote npm global do prefixo npm ATIVO (o
# que `npm ls -g` enxerga — tipicamente o node gerenciado pelo nvm). Retorna o
# spec npm ("@moonshot-ai/kimi-code") ou vazio. Impuro (consulta `npm ls -g`).
kimi_npm_package() {
  npm ls -g --depth=0 2>/dev/null | grep -oE '@moonshot-ai/kimi-code' | head -1
}

# H5 — detecta instalação npm global em prefixo ESTRANGEIRO ao npm ativo.
# `npm ls -g` só enxerga o prefixo do npm em uso; uma instalação em
# ~/.npm-global (prefixo próprio, comum com NPM_CONFIG_PREFIX) passa
# despercebida e o kimi ficava parado para sempre (o updater oficial `kimi
# update` detecta esse layout como "unsupported package manager or layout").
# Resolve o caminho real do bin: se vive em
# <prefixo>/lib/node_modules/@moonshot-ai/kimi-code/…, emite o prefixo;
# caso contrário, vazio. Impuro (command -v + readlink).
kimi_foreign_npm_prefix() {
  local bin real
  bin="$(command -v kimi 2>/dev/null)" || return 0
  real="$(readlink -f "$bin" 2>/dev/null)" || return 0
  [[ "$real" =~ ^(.*)/lib/node_modules/@moonshot-ai/kimi-code/ ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Extrai, da saída de `npm install -g`, os pacotes cujos scripts de install
# foram bloqueados pelo allowScripts (linhas "npm warn install-scripts
# <pkg>@<ver> (script: …)"). Um por linha, sem a versão. Entrada: stdin.
_npm_blocked_script_pkgs() {
  grep -oE 'install-scripts[[:space:]]+[^ ]+@[0-9][^ ]*' \
    | awk '{print $2}' | sed -E 's/@[^/@]+$//' | sort -u
}

# H5 — atualiza o kimi (Moonshot Kimi Code CLI). O kimi é publicado no npm como
# @moonshot-ai/kimi-code (bin "kimi"), então quando instalado via npm global
# no prefixo ATIVO já é coberto por 'Atualizar npm global' — este step evita
# duplicar o 'npm install' e apenas confirma a cobertura. Instalações em OUTRO
# prefixo npm (ex.: ~/.npm-global) não são vistas pelo npm do run: são
# atualizadas aqui com 'npm install -g --prefix' — exatamente o que o próprio
# `kimi update` recomenda quando não reconhece o layout. Instalações
# standalone caem no updater oficial `kimi update`; se ele também não souber
# como foi instalado, RC_TODO com remediação manual.
update_kimi() {
  if ! has kimi; then
    log "  kimi não encontrado no PATH."
    return 0
  fi
  local before after
  before="$(kimi --version 2>/dev/null | head -1)"
  log "  kimi atual: ${before:-?}"
  if [[ -n "$(kimi_npm_package)" ]]; then
    log "  kimi é pacote npm global (@moonshot-ai/kimi-code); já coberto por 'Atualizar npm global'."
    return 0
  fi

  local foreign_prefix out rc
  foreign_prefix="$(kimi_foreign_npm_prefix)"
  if [[ -n "$foreign_prefix" ]]; then
    log "  kimi é npm global no prefixo ${foreign_prefix} (fora do npm ativo); verificando registry…"
    # No-op quando já está na latest: `npm install -g pkg@latest` REINSTALA
    # mesmo na mesma versão (re-download + postinstall bloqueável pelo
    # allowScripts) — sem este short-circuito o step reinstalaria a cada run.
    local latest
    latest="$(npm view @moonshot-ai/kimi-code version 2>/dev/null | head -1)"
    if [[ -n "$latest" && "${before//[[:space:]]/}" == "${latest//[[:space:]]/}" ]]; then
      log "  kimi já na versão mais recente (${latest}); nada a fazer."
      return 0
    fi
    log "  atualizando ${before:-?} → ${latest:-latest}"
    out="$(run_network_cmd npm install -g --prefix "$foreign_prefix" @moonshot-ai/kimi-code@latest)"
    rc=$?
    printf '%s\n' "$out" | grep -v '^$' | log_out || true
    if (( rc == RC_WARN )); then
      log "  kimi: falha de rede ao atualizar."
      STEP_REASON="rede indisponível para npm install do kimi"
      return "$RC_WARN"
    fi
    if (( rc != 0 )); then
      log "  kimi: falha ao atualizar (rc=${rc})."
      STEP_REASON="npm install do kimi falhou"
      return "$RC_WARN"
    fi
    # allowScripts pode bloquear o postinstall (node-pty fica sem binding
    # nativo). Igual ao step 'Atualizar npm global': reporta e deixa a decisão
    # de --allow-scripts para o usuário.
    local -a blocked=()
    mapfile -t blocked < <(printf '%s\n' "$out" | _npm_blocked_script_pkgs)
    if (( ${#blocked[@]} > 0 )); then
      local blocked_csv
      # Junta com vírgula sem mexer no IFS (evita efeito colateral de escopo).
      blocked_csv="$(printf '%s\n' "${blocked[@]}" | paste -sd, -)"
      log "  npm bloqueou script(s) de install em: ${blocked[*]}"
      remediation "npm install -g --prefix ${foreign_prefix} --allow-scripts=${blocked_csv} @moonshot-ai/kimi-code@latest  # revise antes; executa scripts do pacote"
      STEP_REASON="script(s) de install do kimi bloqueado(s) pelo allowScripts"
      after="$(kimi --version 2>/dev/null | head -1)"
      log "  kimi agora: ${after:-?} (rebuild manual recomendado)"
      return "$RC_TODO"
    fi
    after="$(kimi --version 2>/dev/null | head -1)"
    log "  kimi agora: ${after:-?}"
    return 0
  fi

  log "  kimi instalado fora do npm; usando updater oficial 'kimi update'."
  out="$(run_network_cmd kimi update)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^$' | log_out || true
  if (( rc == RC_WARN )); then
    log "  kimi: falha de rede ao atualizar."
    STEP_REASON="rede indisponível para kimi update"
    return "$RC_WARN"
  fi
  if (( rc != 0 )); then
    log "  kimi: falha ao atualizar (rc=${rc})."
    STEP_REASON="kimi update falhou"
    return "$RC_WARN"
  fi
  # O updater sai 0 mesmo quando não reconhece a instalação ("unsupported
  # package manager or layout") — trata como pendência manual, não como ok.
  if grep -qiE 'unsupported (package manager|install)|to update manually' <<<"$out"; then
    log "  kimi update não reconhece esta instalação; método de update manual necessário."
    remediation "reinstale com o instalador oficial ou: npm install -g @moonshot-ai/kimi-code@latest"
    STEP_REASON="updater do kimi não suporta este layout de instalação"
    return "$RC_TODO"
  fi
  after="$(kimi --version 2>/dev/null | head -1)"
  log "  kimi agora: ${after:-?}"
  return 0
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
