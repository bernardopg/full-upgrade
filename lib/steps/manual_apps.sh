#!/usr/bin/env bash
# lib/steps/manual_apps.sh — steps para programas instalados FORA de qualquer
# gerenciador de pacotes (sem pacman/AUR/flatpak/snap por trás). Cada programa
# tem seu próprio step, descobre sua versão e usa o mecanismo de atualização
# nativo (subcomando self-update) ou, quando não há, reporta via RC_TODO.
# Todos rodam por presença do binário (cmd_deps do catálogo + checagem interna)
# e convertem falha de rede em RC_WARN — nunca derrubam o run por flutuação de
# rede ou por uma ferramenta de terceiros.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module

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
  printf '%s\n' "$check" >>"$LOG_FILE"
  if (( check_rc != 0 )); then
    log "  Não foi possível verificar atualização do droid (rede/Factory indisponível)."
    return "$RC_WARN"
  fi
  if printf '%s' "$check" | grep -qiE 'up[- ]?to[- ]?date|already|latest|nenhuma atualiza'; then
    log "  droid já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando droid…"
  if ! run_network_cmd droid update; then
    log "  Falha ao atualizar o droid."
    return "$RC_WARN"
  fi

  hash -r 2>/dev/null || true
  local newver
  newver="$(droid --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  droid atualizado para ${newver:-?}."
  return 0
}

# ── Snyk CLI ────────────────────────────────────────────────────────────────────
# Binário standalone distribuído pela própria Snyk (static.snyk.io), sem pacote e
# sem subcomando de self-update. Estratégia: compara a versão local com
# /cli/latest/version; se desatualizada, baixa o binário do alvo, VERIFICA o
# sha256 publicado (recusa instalar binário não verificado) e substitui no lugar.
# Se o `snyk` for um symlink para uma instalação npm, o step npm global já cobre —
# aqui só reporta. Escrita em diretório protegido usa sudo quando disponível.
update_snyk() {
  has snyk || { log "  snyk não encontrado."; return 0; }
  has curl || { log "  curl ausente; não é possível atualizar o snyk."; return 0; }

  local snyk_bin resolved
  snyk_bin="$(command -v snyk 2>/dev/null || true)"
  resolved="$(readlink -f "$snyk_bin" 2>/dev/null || printf '%s' "$snyk_bin")"
  if [[ "$resolved" == *node_modules* || "$resolved" == *"/npm/"* ]]; then
    log "  snyk gerenciado pelo npm (${resolved}); coberto por 'Atualizar npm global'."
    return 0
  fi

  local arch asset
  case "$(uname -m)" in
    x86_64)        asset="snyk-linux" ;;
    aarch64|arm64) asset="snyk-linux-arm64" ;;
    *) log "  Arquitetura $(uname -m) não suportada pelo atualizador do snyk; pulando."; return 0 ;;
  esac

  local current
  current="$(snyk --version 2>/dev/null | awk 'NR==1{print $1}' | sed 's/[^0-9.].*$//' || true)"
  log "  snyk em: ${snyk_bin} (versão atual: ${current:-desconhecida})"

  local latest
  latest="$(run_network_cmd curl -fsSL https://static.snyk.io/cli/latest/version 2>/dev/null | head -1 | tr -d '[:space:]')"
  if [[ -z "$latest" ]]; then
    log "  Não foi possível determinar a última versão do snyk (rede/Snyk indisponível)."
    return "$RC_WARN"
  fi
  if [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  snyk já está na versão mais recente (${current})."
    return 0
  fi

  # Resolve o prefixo de sudo cedo: se o binário/dir não é escrevível e não há
  # sudo pronto, vira RC_TODO antes de gastar rede no download.
  local dir; dir="$(dirname "$snyk_bin")"
  local -a sudo_pfx=()
  if [[ ! -w "$snyk_bin" || ! -w "$dir" ]]; then
    if has sudo && sudo -n true 2>/dev/null; then
      sudo_pfx=(sudo)
    else
      log "  ${snyk_bin} exige privilégios para escrita e sudo não está pronto."
      STEP_REASON="atualize o snyk com sudo disponível (binário em ${dir})"
      return "$RC_TODO"
    fi
  fi

  log "  Atualizando snyk: ${current:-?} → ${latest}"

  local tmp
  tmp="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "$tmp" || ! -d "$tmp" ]]; then
    log "  mktemp falhou; não é possível atualizar o snyk."
    return "$RC_WARN"
  fi

  local base="https://static.snyk.io/cli/latest"
  if ! run_network_cmd curl -fsSL "${base}/${asset}" -o "${tmp}/snyk" >/dev/null \
     || ! run_network_cmd curl -fsSL "${base}/${asset}.sha256" -o "${tmp}/snyk.sha256" >/dev/null; then
    rm -rf "$tmp"
    log "  Falha de rede ao baixar o binário do snyk."
    return "$RC_WARN"
  fi

  # Verificação de integridade OBRIGATÓRIA. O arquivo .sha256 referencia o nome
  # do asset (ex.: "snyk-linux"); renomeamos a referência para "snyk" para o -c.
  local expected
  expected="$(awk 'NR==1{print $1}' "${tmp}/snyk.sha256" 2>/dev/null || true)"
  if [[ -z "$expected" ]] || ! printf '%s  %s\n' "$expected" "${tmp}/snyk" | sha256sum -c - >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"
    log "  Checksum do snyk não confere; abortando (binário não verificado)."
    return 1
  fi

  chmod +x "${tmp}/snyk" 2>/dev/null || true
  if ! "${sudo_pfx[@]}" install -m755 "${tmp}/snyk" "$snyk_bin" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    log "  Falha ao instalar o binário snyk em ${snyk_bin}."
    return 1
  fi
  rm -rf "$tmp"

  hash -r 2>/dev/null || true
  local newver
  newver="$(snyk --version 2>/dev/null | awk 'NR==1{print $1}' | sed 's/[^0-9.].*$//' || true)"
  log "  snyk atualizado para ${newver:-$latest}."
  return 0
}

# ── OWASP ZAP ───────────────────────────────────────────────────────────────────
# Instalado fora de pacote (ex.: /opt/zaproxy via instalador). O core (jar) é
# atualizado manualmente, mas os add-ons do Marketplace têm atualização headless
# nativa: `zap.sh -cmd -addonupdate`. Este step mantém os add-ons em dia (a parte
# que realmente muda com frequência) e reporta a versão do core.
update_zap() {
  local zap_cmd
  zap_cmd="$(command -v zap 2>/dev/null || command -v zap.sh 2>/dev/null || true)"
  [[ -n "$zap_cmd" ]] || { log "  OWASP ZAP não encontrado."; return 0; }

  # Versão do core: derivada do jar empacotado ao lado do zap.sh resolvido.
  local zap_home core="" j
  zap_home="$(dirname "$(readlink -f "$zap_cmd" 2>/dev/null || printf '%s' "$zap_cmd")")"
  for j in "$zap_home"/zap-*.jar; do
    [[ -e "$j" ]] || continue
    core="${j##*/zap-}"; core="${core%.jar}"
    break
  done
  log "  OWASP ZAP core: ${core:-desconhecido} (${zap_home})"

  log "  Atualizando add-ons do ZAP via Marketplace (headless)…"
  if ! run_network_cmd "$zap_cmd" -cmd -addonupdate; then
    log "  Falha ao atualizar add-ons do ZAP."
    return "$RC_WARN"
  fi
  log "  Add-ons do ZAP atualizados (core ${core:-?} é atualizado manualmente)."
  return 0
}
