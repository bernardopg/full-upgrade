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
  if (( rc != 0 )) || [[ $script != *[![:space:]]* ]]; then
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
#
# kilo (~/.kilo) e mimo (~/.mimocode) são forks do opencode com o mesmo
# `<bin> upgrade`. Esse upgrade imprime "Upgrade failed" e ainda sai com 0 quando
# o instalador falha (visto no kilo 7.3.16: a URL do instalador devolvia HTML e o
# bash quebrava no `<!DOCTYPE`), então o texto também decide, não só o rc.
_opencode_style_upgrade() {
  local label="$1" bin="$2"
  if ! has "$bin"; then
    log "  ${label} não encontrado no PATH."
    return 0
  fi
  local before after out rc
  before="$("$bin" --version 2>/dev/null | head -1)"
  log "  ${label} atual: ${before:-?}"
  out="$(run_network_cmd "$bin" upgrade)"
  rc=$?
  # A linha é cortada na tela: o erro do kilo despejava 200KB de HTML numa só
  # linha. O log já tem a saída íntegra (run_network_cmd).
  printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:]│]*$' | awk '{ print substr($0, 1, 300) }' | log_out || true
  if (( rc == RC_WARN )); then
    log "  ${label}: falha de rede ao atualizar."
    STEP_REASON="rede indisponível para ${bin} upgrade"
    return "$RC_WARN"
  fi
  if (( rc != 0 )) || grep -qi 'upgrade failed' <<<"$out"; then
    log "  ${label}: falha ao atualizar (rc=${rc})."
    STEP_REASON="${bin} upgrade falhou"
    return "$RC_WARN"
  fi
  after="$("$bin" --version 2>/dev/null | head -1)"
  log "  ${label} agora: ${after:-?}"
  return 0
}

update_opencode() { _opencode_style_upgrade opencode opencode; }
update_kilo() { _opencode_style_upgrade "kilo (Kilo Code CLI)" kilo; }
update_mimo() { _opencode_style_upgrade "mimo (MiMo Code)" mimo; }


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
  if [[ $clean == *[![:space:]]* ]]; then
    while IFS= read -r _l; do [[ $_l == *[![:space:]]* ]] && log "  ${_l}"; done <<< "$clean"
  fi

  if (( rc != 0 )); then
    log "  Falha ao atualizar agent skills (rede/registro indisponível)."
    return "$RC_WARN"
  fi
  return 0
}


# ── Factory droid ───────────────────────────────────────────────────────────────
# CLI de IA da Factory, instalada via instalador próprio em ~/.local/bin (sem
# pacote). Possui self-update nativo: `droid update` (e `--check` só verifica).
update_droid() {
  has droid || { log "  droid não encontrado."; return 0; }

  local current
  current="$(droid --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  droid versão atual: ${current:-desconhecida}"

  # `droid update --check` é read-only: evita o download/instalação quando já
  # está atualizado (e poupa rede). rc 0 + saída sem "update" => já atual.
  local check
  check="$(run_network_cmd droid update --check 2>&1)"
  local check_rc=$?
  if (( check_rc != 0 )); then
    log "  Não foi possível verificar atualização do droid (rede/Factory indisponível)."
    return "$RC_WARN"
  fi
  if grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza' <<<"$check"; then
    log "  droid já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando droid…"
  if ! run_network_cmd droid update | log_out; then
    log "  Falha ao atualizar o droid."
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  local newver
  newver="$(droid --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  droid atualizado para ${newver:-?}."
  return 0
}


# ── CodeRabbit CLI ──────────────────────────────────────────────────────────────
# Binário standalone em ~/.local/bin (sem pacote), com self-update nativo:
# `coderabbit update` checa e instala a última versão no lugar. Sem sudo (destino
# escrevível pelo usuário). Falha de rede vira RC_WARN.
update_coderabbit() {
  has coderabbit || { log "  coderabbit não encontrado."; return 0; }

  local current
  current="$(coderabbit --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  coderabbit versão atual: ${current:-desconhecida}"

  log "  Verificando atualização do CodeRabbit CLI…"
  local out rc
  out="$(run_network_cmd coderabbit update 2>&1)"; rc=$?
  if (( rc != 0 )); then
    log "  Falha ao atualizar o coderabbit."
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  local newver
  newver="$(coderabbit --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  if [[ -n "$newver" && "$newver" != "$current" ]]; then
    log "  coderabbit atualizado: ${current:-?} → ${newver}."
  else
    log "  coderabbit já está na versão mais recente (${newver:-${current:-?}})."
  fi
  return 0
}


# ── Amazon Kiro CLI ─────────────────────────────────────────────────────────────
# CLI da IDE Kiro (Amazon), instalada fora de pacote em ~/.local/bin. Tem
# self-update nativo: `kiro-cli update --non-interactive` (sem prompt). Não
# confundir com 'Atualizar Kimi CLI' (Moonshot). Falha de rede vira RC_WARN.
update_kiro_cli() {
  has kiro-cli || { log "  kiro-cli não encontrado."; return 0; }

  local current
  current="$(kiro-cli --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  kiro-cli versão atual: ${current:-desconhecida}"

  log "  Atualizando Kiro CLI…"
  local out rc
  out="$(run_network_cmd kiro-cli update --non-interactive 2>&1)"; rc=$?
  if (( rc != 0 )); then
    log "  Falha ao atualizar o kiro-cli."
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  local newver
  newver="$(kiro-cli --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  if [[ -n "$newver" && "$newver" != "$current" ]]; then
    log "  kiro-cli atualizado: ${current:-?} → ${newver}."
  else
    log "  kiro-cli já está na versão mais recente (${newver:-${current:-?}})."
  fi
  return 0
}


# ── Helper genérico p/ CLIs self-download com "update --check" textual ───────────
# Muitos CLIs de IA instalados por instalador próprio em ~/.<tool> seguem o mesmo
# contrato: `<bin> update --check` (read-only) diz se há versão nova; `<bin> update`
# aplica. Centraliza o fluxo check→apply e a conversão de falha de rede em RC_WARN.
# Args: <label> <bin> [update_arg...]  — os update_arg extras (ex.: --force) vão só
# no apply, nunca no --check. rc: 0 ok · RC_WARN rede/falha.
_selfupdate_check_apply() {
  local label="$1" bin="$2"
  shift 2
  has "$bin" || { log "  ${label} não encontrado."; return 0; }

  local current
  current="$("$bin" --version 2>/dev/null | grep -oE 'v?[0-9]+(\.[0-9]+){1,3}' | head -1 | sed 's/^v//' || true)"
  log "  ${label} versão atual: ${current:-desconhecida}"

  local check check_rc
  check="$(run_network_cmd "$bin" update --check 2>&1)"
  check_rc=$?
  if ((check_rc != 0)); then
    log "  Não foi possível verificar atualização do ${label} (rede/upstream indisponível)."
    return "$RC_WARN"
  fi
  local check_latest
  check_latest="$(printf '%s' "$check" | sed -nE 's/.*latest:[[:space:]]*v?([0-9]+(\.[0-9]+){1,3}).*/\1/p' | head -1)"
  if grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza' <<<"$check" \
    || [[ -n "$current" && -n "$check_latest" && "$current" == "$check_latest" ]]; then
    log "  ${label} já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando ${label}…"
  if ! run_network_cmd "$bin" update "$@" | log_out; then
    log "  Falha ao atualizar o ${label}."
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  local newver
  newver="$("$bin" --version 2>/dev/null | grep -oE 'v?[0-9]+(\.[0-9]+){1,3}' | head -1 | sed 's/^v//' || true)"
  log "  ${label} atualizado para ${newver:-?}."
  return 0
}


# ── pool (Poolside) ─────────────────────────────────────────────────────────────
# CLI de agente self-download em ~/.local/bin/pool; helper em manual_apps.sh.
update_pool() { _selfupdate_direct "pool (Poolside)" pool; }

# ── muse (Muse Code, Meta) ──────────────────────────────────────────────────────
# `muse` em ~/.local/bin é um launcher bash que baixa o binário real
# (muse-bin-<versão>) e só se atualiza em background ao ser aberto, no máximo
# de hora em hora. Sem uso, ficava parado na versão instalada (0.1.0 por um mês,
# com a 1.4.0 disponível). MUSE_LAUNCHER_INSTALL=1 é o modo do próprio
# instalador: atualiza o binário e sai sem abrir a TUI. As leituras de versão
# usam MUSE_NO_AUTO_UPDATE=1 para não disparar o update em background.
update_muse() {
  has muse || { log "  muse não encontrado."; return 0; }
  local before after out rc
  before="$(MUSE_NO_AUTO_UPDATE=1 muse --version 2>/dev/null | head -1)"
  log "  muse atual: ${before:-?}"
  out="$(MUSE_LAUNCHER_INSTALL=1 run_network_cmd muse </dev/null)"
  rc=$?
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | log_out
  if ((rc != 0)); then
    log "  Falha ao atualizar o muse."
    STEP_REASON="muse (MUSE_LAUNCHER_INSTALL=1) falhou (rc=${rc})"
    return "$RC_WARN"
  fi
  after="$(MUSE_NO_AUTO_UPDATE=1 muse --version 2>/dev/null | head -1)"
  log "  muse agora: ${after:-?}"
  return 0
}

# ── grok (xAI CLI) ──────────────────────────────────────────────────────────────
# Instalada via instalador próprio em ~/.grok (self-download). `grok update --check`
# é read-only; `grok update` aplica. Falha de rede vira RC_WARN.
update_grok() { _selfupdate_check_apply "grok" grok; }

# ── jcode ───────────────────────────────────────────────────────────────────────
# CLI de IA self-download em ~/.jcode/builds. Diferente de grok/qoder, o `jcode
# update` atual não possui `--check`; por isso fazemos o check read-only contra a
# última release do GitHub e só chamamos `jcode update` quando a versão local está
# atrasada. Falha de rede → RC_WARN.

update_jcode() {
  has jcode || { log "  jcode não encontrado."; return 0; }
  has curl || { log "  curl ausente; não é possível verificar atualização do jcode."; return 0; }

  local current latest meta
  current="$(jcode version --json 2>/dev/null | sed -nE 's/.*"semver"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
  [[ -n "$current" ]] || current="$(jcode --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){2}' | head -1 || true)"
  log "  jcode versão atual: ${current:-desconhecida}"

  meta="$(run_network_cmd curl -fsSL https://api.github.com/repos/1jehuang/jcode/releases/latest 2>/dev/null)"
  if [[ -z "$meta" ]]; then
    log "  Não foi possível consultar a última release do jcode (rede/GitHub indisponível)."
    return "$RC_WARN"
  fi
  latest="$(printf '%s\n' "$meta" | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([0-9][^"]*)".*/\1/p' | head -1)"
  if [[ -z "$latest" ]]; then
    log_raw "$meta"
    log "  Não foi possível parsear a versão mais recente do jcode."
    return "$RC_WARN"
  fi

  if [[ -z "$current" ]]; then
    log "  Não foi possível determinar a versão local do jcode; não vou executar update mutante sem confirmação de atraso."
    return "$RC_WARN"
  fi

  if ! version_is_outdated "$current" "$latest"; then
    log "  jcode já está na versão mais recente (${current})."
    return 0
  fi

  log "  Atualizando jcode: ${current:-?} → ${latest}…"
  if ! run_network_cmd jcode update | log_out; then
    log "  Falha ao atualizar o jcode."
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  local newver
  newver="$(jcode version --json 2>/dev/null | sed -nE 's/.*"semver"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
  log "  jcode atualizado para ${newver:-$latest}."
  return 0
}


# ── qodercli (Qoder) ────────────────────────────────────────────────────────────
# CLI self-download em ~/.qoder/bin. `qodercli update --check` verifica; sem flag
# aplica. Falha de rede → RC_WARN.
update_qodercli() { _selfupdate_check_apply "qodercli" qodercli; }

# ── qoderwake ───────────────────────────────────────────────────────────────────
# Daemon/CLI companheiro do Qoder, self-download em ~/.qoderwake. Mesmo contrato:
# `qoderwake update --check` verifica; `qoderwake update` aplica. Rede → RC_WARN.

update_qoderwake() { _selfupdate_check_apply "qoderwake" qoderwake; }

# ── kimchi ──────────────────────────────────────────────────────────────────────
# CLI self-download em ~/.local/bin. Atualização do próprio binário: `kimchi update
# self` (com `--dry-run` p/ checar e `--force` p/ pular confirmação). Usamos o
# subcomando `self` (não mexe em extensões/pacotes do usuário). Rede → RC_WARN.

update_kimchi() {
  has kimchi || { log "  kimchi não encontrado."; return 0; }
  local kimchi_config="${XDG_CONFIG_HOME:-${HOME}/.config}/kimchi/config.json" mode
  if [[ -f "$kimchi_config" ]]; then
    mode="$(stat -c '%a' "$kimchi_config" 2>/dev/null || true)"
    if [[ "$mode" =~ ^[0-7]{3,4}$ && "${mode: -2}" != "00" ]]; then
      if chmod 600 -- "$kimchi_config" 2>/dev/null; then
        log "  Permissões do config Kimchi endurecidas: ${mode} → 600 (protege chaves de API)."
      else
        log "  Não foi possível restringir ${kimchi_config}; aplique chmod 600."
        STEP_REASON="config Kimchi expõe chaves para grupo/outros (${mode})"
        return "$RC_WARN"
      fi
    fi
  fi
  local current
  current="$(kimchi --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  kimchi versão atual: ${current:-desconhecida}"

  local check check_rc
  check="$(run_network_cmd kimchi update self --dry-run 2>&1)"
  check_rc=$?
  if ((check_rc != 0)); then
    log "  Não foi possível verificar atualização do kimchi (rede/upstream indisponível)."
    return "$RC_WARN"
  fi
  if grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza' <<<"$check"; then
    log "  kimchi já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando kimchi…"
  if ! run_network_cmd kimchi update self --force | log_out; then
    log "  Falha ao atualizar o kimchi."
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  local newver
  newver="$(kimchi --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  kimchi atualizado para ${newver:-?}."
  return 0
}
