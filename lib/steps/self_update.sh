#!/usr/bin/env bash
# steps/self_update.sh — auto-atualização do próprio full-upgrade.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Normaliza uma versão "vX.Y.Z" ou "X.Y.Z[-N-gHASH]" para "X.Y.Z".
# git describe pode anexar "-<commits>-g<hash>"; ficamos só com o core semver.
_self_normalize_version() {
  normalize_version "$1"
}

# Compara duas versões semver. Imprime: 0 (iguais), 1 (a > b), 2 (a < b).
# Pura e determinística — testável com bats.
# Uso: self_version_compare "3.0.3" "3.0.4"  -> imprime 2
self_version_compare() {
  version_compare "$1" "$2"
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

  # Canal release: instala o STANDALONE publicado, com verificação de checksum
  # ponta-a-ponta (asset .sha256). É a via segura e preferida.
  if [[ "$channel" != "main" ]]; then
    self_install_verified_standalone "$repo" "$latest" "$ref" "$tmp"
    return $?
  fi

  # Canal main: não há release nem checksum publicado para o topo da branch.
  # Cai no tarball-fonte + install.sh, avisando que a integridade NÃO é
  # verificada criptograficamente (apenas TLS do GitHub).
  log_always "${C_YELLOW}Canal 'main': integridade não verificada por checksum (somente TLS).${C_RESET}"
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

# Baixa o standalone publicado na release v<latest> + seu .sha256, VERIFICA o
# checksum e só então instala o binário em ~/.local/bin/full-upgrade (com
# backup do anterior). Abortar antes de instalar se o checksum não bater é o
# ponto central de segurança (C2): tarball/binário adulterado em trânsito não
# é executado.
# Args: <repo> <latest_sem_v> <ref> <tmpdir>. Retorna 0 ok / RC_WARN falha.
self_install_verified_standalone() {
  local repo="$1" latest="$2" ref="$3" tmp="$4"
  local base="https://github.com/${repo}/releases/download/v${latest}"
  local bin_url="${base}/full-upgrade-standalone.sh"
  local sum_url="${base}/full-upgrade-standalone.sh.sha256"
  local bin="${tmp}/full-upgrade-standalone.sh"
  local sum="${tmp}/full-upgrade-standalone.sh.sha256"

  log_always "Baixando standalone ${ref} ..."
  if ! run_network_cmd curl -fsSL --max-time 60 -o "$bin" "$bin_url"; then
    log_always "Falha ao baixar o standalone (release sem asset?). Tente o canal 'main'."
    return "$RC_WARN"
  fi
  if ! run_network_cmd curl -fsSL --max-time 30 -o "$sum" "$sum_url"; then
    log_always "${C_YELLOW}Checksum (.sha256) indisponível na release; abortando por segurança.${C_RESET}"
    log_always "Não instalando binário não verificado. Verifique a release de ${ref}."
    return "$RC_WARN"
  fi

  if ! has sha256sum && ! has shasum; then
    log_always "Sem sha256sum/shasum para verificar integridade; abortando por segurança."
    return "$RC_WARN"
  fi

  local expected
  expected="$(parse_sha256_field "$(cat "$sum" 2>/dev/null)" 2>/dev/null || true)"
  if [[ -z "$expected" ]]; then
    log_always "Arquivo de checksum inválido; abortando por segurança."
    return "$RC_WARN"
  fi

  if ! verify_sha256 "$bin" "$expected"; then
    log_always "${C_RED}ERRO: checksum do standalone NÃO confere — download corrompido ou adulterado.${C_RESET}"
    log_always "Esperado: ${expected}"
    log_always "Obtido:   $(file_sha256 "$bin" 2>/dev/null || echo '?')"
    log_always "Atualização ABORTADA. Nada foi instalado."
    return "$RC_WARN"
  fi
  log_always "Checksum verificado (SHA-256 confere)."

  # Sanidade extra: o binário verificado deve ter sintaxe Bash válida.
  if ! bash -n "$bin" 2>/dev/null; then
    log_always "Standalone verificado falhou no bash -n; abortando."
    return "$RC_WARN"
  fi

  # Instala em ~/.local/bin/full-upgrade, fazendo backup do anterior.
  local bin_dir="${HOME}/.local/bin"
  local dest="${bin_dir}/full-upgrade"
  mkdir -p "$bin_dir" 2>/dev/null || { log_always "Não foi possível criar ${bin_dir}."; return "$RC_WARN"; }

  if [[ -e "$dest" || -L "$dest" ]]; then
    cp -a -- "$dest" "${dest}.bak" 2>/dev/null \
      && log_always "Backup do binário anterior: ${dest}.bak"
  fi

  if ! install -m 0755 -- "$bin" "$dest" 2>/dev/null; then
    # install pode não existir em ambientes mínimos; fallback cp+chmod.
    cp -f -- "$bin" "$dest" && chmod 0755 "$dest" || {
      log_always "Falha ao instalar o standalone em ${dest}."
      return "$RC_WARN"
    }
  fi

  log_always "${C_GREEN}full-upgrade atualizado para ${ref} (standalone verificado): ${dest}${C_RESET}"
  return 0
}
