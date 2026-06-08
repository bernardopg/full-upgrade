#!/usr/bin/env bash
# steps/self_update.sh — auto-atualização do próprio full-upgrade.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Normaliza uma versão "vX.Y.Z" ou "X.Y.Z[-N-gHASH]" para "X.Y.Z".
# git describe pode anexar "-<commits>-g<hash>"; ficamos só com o core semver.
_self_normalize_version() {
  local v="$1"
  v="${v#v}"                 # remove prefixo v
  v="${v%%-*}"               # corta sufixo de git describe (-N-gHASH)
  printf '%s' "$v"
}

# Compara duas versões semver. Imprime: 0 (iguais), 1 (a > b), 2 (a < b).
# Pura e determinística — testável com bats.
# Uso: self_version_compare "3.0.3" "3.0.4"  -> imprime 2
self_version_compare() {
  local a b
  a="$(_self_normalize_version "$1")"
  b="$(_self_normalize_version "$2")"

  [[ "$a" == "$b" ]] && { printf '0'; return 0; }

  local -a pa pb
  IFS='.' read -ra pa <<< "$a"
  IFS='.' read -ra pb <<< "$b"

  local i max=${#pa[@]}
  (( ${#pb[@]} > max )) && max=${#pb[@]}

  for (( i = 0; i < max; i++ )); do
    local na="${pa[i]:-0}" nb="${pb[i]:-0}"
    # campos não-numéricos viram 0 (defensivo)
    [[ "$na" =~ ^[0-9]+$ ]] || na=0
    [[ "$nb" =~ ^[0-9]+$ ]] || nb=0
    if (( na > nb )); then printf '1'; return 0; fi
    if (( na < nb )); then printf '2'; return 0; fi
  done
  printf '0'
}

# Descobre a última versão publicada no GitHub, sem depender de gh/jq.
# Canal 'release' → tag_name da última release. Canal 'main' → "main".
# Ecoa a versão (ex.: "3.0.4") ou nada em falha. Não loga (uso por notice/update).
self_latest_version() {
  local repo="${FULL_UPGRADE_REPO:-bernardopg/full-upgrade}"
  local channel="${FULL_UPGRADE_UPDATE_CHANNEL:-release}"

  if [[ "$channel" == "main" ]]; then
    printf 'main'
    return 0
  fi

  has curl || { return 1; }

  local api="https://api.github.com/repos/${repo}/releases/latest"
  local body tag
  body="$(curl -fsSL --max-time 10 "$api" 2>/dev/null)" || return 1
  # extrai "tag_name": "vX.Y.Z" sem jq
  tag="$(printf '%s' "$body" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [[ -n "$tag" ]] || return 1
  printf '%s' "${tag#v}"
}

# Checagem passiva: só avisa se há versão nova. Não baixa nada.
# RC_TODO quando há atualização disponível; 0 caso contrário ou indeterminado.
self_update_notice() {
  if ! has curl; then
    log "  curl ausente; não foi possível checar atualizações."
    return 0
  fi

  local current="${SCRIPT_VERSION:-0.0.0}"
  local latest
  latest="$(self_latest_version 2>/dev/null || true)"

  if [[ -z "$latest" ]]; then
    log "  Não foi possível consultar a última versão (rede/API)."
    return 0
  fi

  if [[ "$latest" == "main" ]]; then
    log "  Canal 'main': rode 'full-upgrade --update' para sincronizar com o topo da branch."
    return 0
  fi

  local cmp
  cmp="$(self_version_compare "$current" "$latest")"
  case "$cmp" in
    2)  # current < latest
      log "  ${C_YELLOW}Nova versão disponível: v${current} → v${latest}.${C_RESET}"
      log "  Atualize com: full-upgrade --update"
      STEP_REASON="atualização disponível: v${current} → v${latest}"
      return "$RC_TODO"
      ;;
    *)
      log "  full-upgrade está atualizado (v${current})."
      return 0
      ;;
  esac
}

# Aplica a atualização: baixa o tarball da última tag (ou main), extrai e roda
# o install.sh de lá. Pede confirmação salvo --yes. Falha de rede → RC_WARN.
self_perform_update() {
  if ! has curl; then
    log_always "curl é necessário para atualizar. Instale curl e tente novamente."
    return "$RC_WARN"
  fi
  if ! has tar; then
    log_always "tar é necessário para atualizar."
    return "$RC_WARN"
  fi

  local repo="${FULL_UPGRADE_REPO:-bernardopg/full-upgrade}"
  local channel="${FULL_UPGRADE_UPDATE_CHANNEL:-release}"
  local current="${SCRIPT_VERSION:-0.0.0}"

  local latest ref tarball
  if [[ "$channel" == "main" ]]; then
    latest="main"
    ref="main"
    tarball="https://github.com/${repo}/archive/refs/heads/main.tar.gz"
  else
    latest="$(self_latest_version 2>/dev/null || true)"
    if [[ -z "$latest" ]]; then
      log_always "Não foi possível consultar a última release (rede/API)."
      return "$RC_WARN"
    fi
    ref="v${latest}"
    tarball="https://github.com/${repo}/archive/refs/tags/v${latest}.tar.gz"
  fi

  # Já está na última?
  if [[ "$channel" != "main" ]]; then
    local cmp
    cmp="$(self_version_compare "$current" "$latest")"
    if [[ "$cmp" != "2" ]]; then
      log_always "Já está na versão mais recente (v${current})."
      return 0
    fi
  fi

  log_always "full-upgrade: v${current} → ${ref}"

  # Confirmação (salvo --yes).
  if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
      printf '%b' "${C_YELLOW}Baixar e instalar ${ref} agora? [s/N] ${C_RESET}"
      local answer
      read -r answer
      case "$answer" in
        [sS][iI][mM]|[sS]) ;;
        *) log_always "Atualização cancelada."; return 0 ;;
      esac
    else
      log_always "Execução não interativa sem --yes; pulando atualização."
      return 0
    fi
  fi

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || { log_always "Falha ao criar diretório temporário."; return "$RC_WARN"; }
  # shellcheck disable=SC2064  # expandir tmp agora é intencional
  trap "rm -rf '$tmp'" RETURN

  log_always "Baixando ${tarball} ..."
  if ! run_network_cmd curl -fsSL --max-time 60 -o "${tmp}/src.tar.gz" "$tarball"; then
    return "$RC_WARN"
  fi

  if ! tar -xzf "${tmp}/src.tar.gz" -C "$tmp" 2>/dev/null; then
    log_always "Falha ao extrair o pacote baixado."
    return "$RC_WARN"
  fi

  # O tarball do GitHub extrai em <repo>-<ref>/.
  local extracted
  extracted="$(find "$tmp" -maxdepth 1 -type d -name '*full-upgrade-*' | head -n1)"
  if [[ -z "$extracted" || ! -x "${extracted}/install.sh" ]]; then
    log_always "Pacote inválido: install.sh não encontrado."
    return "$RC_WARN"
  fi

  log_always "Instalando ${ref} ..."
  if ( cd "$extracted" && ./install.sh ); then
    log_always "${C_GREEN}full-upgrade atualizado para ${ref}.${C_RESET}"
    return 0
  fi
  log_always "Falha ao executar o instalador."
  return "$RC_WARN"
}
