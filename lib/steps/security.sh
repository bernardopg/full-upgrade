#!/usr/bin/env bash
# lib/steps/security.sh — ferramentas de segurança instaladas fora de gestor de
# pacote (Snyk CLI, OWASP ZAP). Wireshark e Burp Suite vivem em steps.d/ porque
# são integrações opt-in (ENABLE_CUSTOM_TOOLS).
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)


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
  local -a sudo_pfx=() ; local pfx
  if ! pfx="$(_manual_write_prefix "$snyk_bin")"; then
    log "  ${snyk_bin} exige privilégios para escrita e sudo não está pronto."
    STEP_REASON="atualize o snyk com sudo disponível (binário em $(dirname "$snyk_bin"))"
    return "$RC_TODO"
  fi
  [[ -n "$pfx" ]] && sudo_pfx=("$pfx")

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

# Lê o JSON de releases do GitHub e retorna: versão<TAB>url<TAB>sha256.
# Só aceita o tar oficial Linux com digest publicado pela própria release.
zap_release_asset_info() {
  python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
    version = str(data.get("tag_name", "")).lstrip("v")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", version):
        raise ValueError("invalid tag")
    wanted = f"ZAP_{version}_Linux.tar.gz"
    asset = next(a for a in data.get("assets", []) if a.get("name") == wanted)
    digest = str(asset.get("digest") or "")
    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        raise ValueError("missing digest")
    print(version, asset["browser_download_url"], digest.split(":", 1)[1].lower(), sep="\t")
except Exception:
    raise SystemExit(1)
'
}


zap_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}


# Atualiza uma instalação manual do core em /opt (ou outro diretório gravável)
# por troca atômica com rollback, após verificar o sha256 do asset oficial.
zap_update_core() {
  local zap_home="$1" current="$2"
  local meta info latest url expected tmp archive extracted actual backup write_prefix

  meta="$(curl -fsSL --connect-timeout 15 https://api.github.com/repos/zaproxy/zaproxy/releases/latest 2>/dev/null || true)"
  info="$(printf '%s\n' "$meta" | zap_release_asset_info 2>/dev/null || true)"
  if [[ -z "$info" ]]; then
    log "  ZAP core: não foi possível obter release Linux com sha256 verificável."
    return "$RC_WARN"
  fi
  IFS=$'\t' read -r latest url expected <<< "$info"
  if [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  ZAP core ${current} já na versão mais recente."
    return 0
  fi

  if ! write_prefix="$(_manual_write_prefix "$zap_home/zap.sh")"; then
    log "  ZAP core ${current:-?} → ${latest}, mas ${zap_home} exige sudo indisponível."
    return "$RC_WARN"
  fi

  tmp="$(mktemp -d)" || return "$RC_WARN"
  archive="${tmp}/ZAP_${latest}_Linux.tar.gz"
  log "  Atualizando ZAP core: ${current:-?} → ${latest} (asset oficial verificado)..."
  if ! run_logged curl -fL --retry 2 --connect-timeout 15 -o "$archive" "$url"; then
    rm -rf -- "$tmp"
    return "$RC_WARN"
  fi
  actual="$(sha256sum "$archive" 2>/dev/null | awk '{print tolower($1)}')"
  if [[ "$actual" != "$expected" ]]; then
    log "  ZAP core: sha256 inválido; instalação abortada (${actual:-ausente} != ${expected})."
    rm -rf -- "$tmp"
    return "$RC_WARN"
  fi
  if ! tar -xzf "$archive" -C "$tmp"; then
    rm -rf -- "$tmp"
    return "$RC_WARN"
  fi
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name "ZAP_${latest}" -print -quit)"
  if [[ -z "$extracted" || ! -x "$extracted/zap.sh" || ! -f "$extracted/zap-${latest}.jar" ]]; then
    log "  ZAP core: conteúdo extraído não possui zap.sh/jar esperados."
    rm -rf -- "$tmp"
    return "$RC_WARN"
  fi

  backup="${zap_home}.full-upgrade-backup-${RUN_ID:-$$}"
  local -a priv=()
  [[ -n "$write_prefix" ]] && priv=("$write_prefix")
  if ! "${priv[@]}" mv -- "$zap_home" "$backup"; then
    rm -rf -- "$tmp"
    return "$RC_WARN"
  fi
  if ! "${priv[@]}" mv -- "$extracted" "$zap_home"; then
    "${priv[@]}" mv -- "$backup" "$zap_home" 2>/dev/null || true
    rm -rf -- "$tmp"
    return "$RC_WARN"
  fi
  "${priv[@]}" chown -R root:root "$zap_home" 2>/dev/null || true
  if [[ ! -x "$zap_home/zap.sh" || ! -f "$zap_home/zap-${latest}.jar" ]]; then
    "${priv[@]}" rm -rf -- "$zap_home" 2>/dev/null || true
    "${priv[@]}" mv -- "$backup" "$zap_home" 2>/dev/null || true
    rm -rf -- "$tmp"
    log "  ZAP core: validação pós-instalação falhou; versão anterior restaurada."
    return "$RC_WARN"
  fi
  "${priv[@]}" rm -rf -- "$backup" 2>/dev/null || true
  rm -rf -- "$tmp"
  log "  ZAP core atualizado para ${latest}."
  return 0
}


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

  local core_rc=0
  zap_update_core "$zap_home" "$core" || core_rc=$?
  # O diretório pode ter sido trocado; use o launcher recém-instalado.
  [[ -x "$zap_home/zap.sh" ]] && zap_cmd="$zap_home/zap.sh"
  core="$(find "$zap_home" -maxdepth 1 -type f -name 'zap-*.jar' -printf '%f\n' 2>/dev/null | sed -nE 's/^zap-(.+)\.jar$/\1/p' | sort -V | tail -1)"

  log "  Atualizando add-ons do ZAP via Marketplace (headless)…"
  # ZAP 2.16 tratava `-port 0` como a porta padrão em alguns caminhos. Reserve
  # explicitamente uma porta alta livre para não colidir com Burp/ZAP já aberto.
  local out rc port
  port="$(zap_free_port 2>/dev/null || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || port=49152
  out="$(run_network_cmd "$zap_cmd" -cmd -port "$port" -addonupdate 2>&1)"; rc=$?

  if grep -qiE 'add-?on.*(compl|finish)|atualiza.*add-on.*compl|add-on (baixado|downloaded)|no (add-?on )?updates|nenhuma atualiza' <<<"$out"; then
    log "  Add-ons do ZAP atualizados (core ${core:-?})."
    return "$core_rc"
  fi
  if (( rc != 0 )); then
    log "  Falha ao atualizar add-ons do ZAP."
    return "$RC_WARN"
  fi
  log "  Add-ons do ZAP atualizados (core ${core:-?})."
  return "$core_rc"
}


# ── Scanners de segredos (binários de release do GitHub) ──────────────────────
# Instalados em ~/.local/bin a partir do tar.gz oficial, sem gestor de pacote.
# O trufflehog tem auto-update embutido, mas só roda durante um scan; aqui ele é
# atualizado mesmo sem uso. Helper em manual_apps.sh.
update_gitleaks() { _github_release_bin_update "gitleaks" gitleaks gitleaks/gitleaks x64 arm64; }
update_trufflehog() { _github_release_bin_update "trufflehog" trufflehog trufflesecurity/trufflehog amd64 arm64; }
