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

# Resolve como escrever em <path> (binário existente): ecoa o prefixo de comando
# a usar — "sudo" quando o destino é protegido e há sudo pronto, ou vazio quando
# já é escrevível direto. rc 1 = precisa de privilégio e sudo não está disponível
# (o caller deve devolver RC_TODO). Centraliza a lógica compartilhada por
# update_snyk/update_gk e é coberta por teste.
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
  log_raw "$check"
  if (( check_rc != 0 )); then
    log "  Não foi possível verificar atualização do droid (rede/Factory indisponível)."
    return "$RC_WARN"
  fi
  if printf '%s' "$check" | grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza'; then
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
  log_raw "$out"
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
  log_raw "$out"
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
  log_raw "$out"

  if printf '%s' "$out" | grep -qiE 'add-?on.*(compl|finish)|atualiza.*add-on.*compl|add-on (baixado|downloaded)|no (add-?on )?updates|nenhuma atualiza'; then
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

# ── GitKraken CLI (gk) ──────────────────────────────────────────────────────────
# Binário standalone instalado fora de pacote, sem subcomando de self-update. Tem
# releases públicos no GitHub (gitkraken/gk-cli) com assets .zip + gk_checksums.txt.
# Estratégia idêntica ao rtk: descobre a última tag pelo redirect 302, compara
# versão, baixa o zip do alvo, VERIFICA o sha256 publicado e substitui o binário
# (sudo só quando o destino é protegido).
update_gk() {
  has gk || { log "  gk (GitKraken CLI) não encontrado."; return 0; }
  if ! has curl || ! has unzip; then
    log "  curl e unzip são necessários para atualizar o gk."
    return 0
  fi

  local gk_bin
  gk_bin="$(command -v gk 2>/dev/null || true)"

  local arch asset_arch
  case "$(uname -m)" in
    x86_64)        asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    i?86)          asset_arch="386" ;;
    *) log "  Arquitetura $(uname -m) não suportada pelo atualizador do gk; pulando."; return 0 ;;
  esac

  local current
  current="$(gk version 2>/dev/null | awk '/Core/{print $NF; exit}' | tr -d '[:space:]' || true)"
  log "  gk em: ${gk_bin} (versão atual: ${current:-desconhecida})"

  local effective tag latest
  effective="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                 "https://github.com/gitkraken/gk-cli/releases/latest" 2>/dev/null || true)"
  tag="${effective##*/}"          # ex.: v3.1.68
  latest="${tag#v}"
  if [[ -z "$latest" ]]; then
    log "  Não foi possível determinar a última versão do gk (rede/GitHub indisponível)."
    return "$RC_WARN"
  fi
  if [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  gk já está na versão mais recente (${current})."
    return 0
  fi

  local -a sudo_pfx=() ; local pfx
  if ! pfx="$(_manual_write_prefix "$gk_bin")"; then
    log "  ${gk_bin} exige privilégios para escrita e sudo não está pronto."
    STEP_REASON="atualize o gk com sudo disponível (binário em $(dirname "$gk_bin"))"
    return "$RC_TODO"
  fi
  [[ -n "$pfx" ]] && sudo_pfx=("$pfx")

  log "  Atualizando gk: ${current:-?} → ${latest}"

  local tmp
  tmp="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "$tmp" || ! -d "$tmp" ]]; then
    log "  mktemp falhou; não é possível atualizar o gk."
    return "$RC_WARN"
  fi

  local base="https://github.com/gitkraken/gk-cli/releases/download/${tag}"
  local asset="gk_${latest}_linux_${asset_arch}.zip"
  if ! run_network_cmd curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" >/dev/null \
     || ! run_network_cmd curl -fsSL "${base}/gk_checksums.txt" -o "${tmp}/gk_checksums.txt" >/dev/null; then
    rm -rf "$tmp"
    log "  Falha de rede ao baixar o release do gk."
    return "$RC_WARN"
  fi

  # Verificação de integridade OBRIGATÓRIA contra o checksum publicado.
  if ! ( cd "$tmp" && grep -F "$asset" gk_checksums.txt | sha256sum -c - ) >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"
    log "  Checksum do gk não confere; abortando (binário não verificado)."
    return 1
  fi

  if ! unzip -o -q "${tmp}/${asset}" -d "${tmp}/x" >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"
    log "  Falha ao descompactar o release do gk."
    return 1
  fi
  local new_bin
  new_bin="$(find "${tmp}/x" -type f -name gk -perm -u+x 2>/dev/null | head -1)"
  [[ -n "$new_bin" ]] || new_bin="$(find "${tmp}/x" -type f -name gk 2>/dev/null | head -1)"
  if [[ -z "$new_bin" ]]; then
    rm -rf "$tmp"
    log "  Binário gk não encontrado dentro do zip."
    return 1
  fi
  chmod +x "$new_bin" 2>/dev/null || true

  if ! "${sudo_pfx[@]}" install -m755 "$new_bin" "$gk_bin" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    log "  Falha ao instalar o binário gk em ${gk_bin}."
    return 1
  fi
  rm -rf "$tmp"

  hash -r 2>/dev/null || true
  local newver
  newver="$(gk version 2>/dev/null | awk '/Core/{print $NF; exit}' | tr -d '[:space:]' || true)"
  log "  gk atualizado para ${newver:-$latest}."
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
  log_raw "$check"
  if ((check_rc != 0)); then
    log "  Não foi possível verificar atualização do ${label} (rede/upstream indisponível)."
    return "$RC_WARN"
  fi
  local check_latest
  check_latest="$(printf '%s' "$check" | sed -nE 's/.*latest:[[:space:]]*v?([0-9]+(\.[0-9]+){1,3}).*/\1/p' | head -1)"
  if printf '%s' "$check" | grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza' \
    || [[ -n "$current" && -n "$check_latest" && "$current" == "$check_latest" ]]; then
    log "  ${label} já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando ${label}…"
  if ! run_network_cmd "$bin" update "$@"; then
    log "  Falha ao atualizar o ${label}."
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  local newver
  newver="$("$bin" --version 2>/dev/null | grep -oE 'v?[0-9]+(\.[0-9]+){1,3}' | head -1 | sed 's/^v//' || true)"
  log "  ${label} atualizado para ${newver:-?}."
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
  if ! run_network_cmd jcode update; then
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
  log_raw "$check"
  if ((check_rc != 0)); then
    log "  Não foi possível verificar atualização do kimchi (rede/upstream indisponível)."
    return "$RC_WARN"
  fi
  if printf '%s' "$check" | grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza'; then
    log "  kimchi já está na versão mais recente (${current:-?})."
    return 0
  fi

  log "  Atualizando kimchi…"
  if ! run_network_cmd kimchi update self --force; then
    log "  Falha ao atualizar o kimchi."
    return "$RC_WARN"
  fi
  hash -r 2>/dev/null || true
  local newver
  newver="$(kimchi --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  kimchi atualizado para ${newver:-?}."
  return 0
}

# ── cua-driver (trycua) ─────────────────────────────────────────────────────────
# Driver de automação self-download em ~/.cua-driver. Tem check/apply com JSON:
# `cua-driver check-update --json` → campo "update_available"; `cua-driver update
# --apply` baixa+instala. Além disso `cua-driver skills update` atualiza as skills.
# Só aplica quando update_available=true. Rede → RC_WARN.
update_cua_driver() {
  has cua-driver || { log "  cua-driver não encontrado."; return 0; }
  local current
  current="$(cua-driver --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
  log "  cua-driver versão atual: ${current:-desconhecida}"

  local check check_rc
  check="$(run_network_cmd cua-driver check-update --json 2>&1)"
  check_rc=$?
  log_raw "$check"
  if ((check_rc != 0)); then
    log "  Não foi possível verificar atualização do cua-driver (rede/GitHub indisponível)."
    return "$RC_WARN"
  fi

  if printf '%s' "$check" | grep -qiE '"update_available"[[:space:]]*:[[:space:]]*true'; then
    log "  Atualizando cua-driver…"
    if ! run_network_cmd cua-driver update --apply; then
      log "  Falha ao atualizar o cua-driver."
      return "$RC_WARN"
    fi
    hash -r 2>/dev/null || true
    local newver
    newver="$(cua-driver --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
    log "  cua-driver atualizado para ${newver:-?}."
  else
    log "  cua-driver já está na versão mais recente (${current:-?})."
  fi

  # Skills do cua-driver (independente da versão do binário). Best-effort.
  local sk
  if sk="$(run_network_cmd cua-driver skills update 2>&1)"; then
    log_raw "$sk"
  else
    log "  Aviso: não foi possível atualizar as skills do cua-driver (rede)."
  fi
  return 0
}

# ── Doctor: inventário de apps manuais ──────────────────────────────────────────
# Read-only. Mapeia programas instalados FORA de qualquer gerenciador de pacotes
# (binários reais em /usr/local/bin e ~/.local/bin sem dono pacman, + diretórios
# de app em /opt) e indica quais já possuem step de atualização dedicado no
# full-upgrade e quais não. NÃO executa binários desconhecidos (evitar abrir GUIs
# como wireshark/cava); só reporta nome, local e cobertura. Sempre rc 0.
_manual_apps_has_step() {
  # Marcadores (basename de binário OU nome de diretório /opt) cobertos por um
  # step de atualização do full-upgrade. Mantido manualmente em sincronia com os
  # steps acima e com ai.sh/self_update.sh/steps.d.
  local marker="$1"
  case "$marker" in
    droid|snyk|zap|zap.sh|zaproxy|rtk|adguardvpn-cli|adguardvpn_cli|openclaw|\
    hermes|ollama|claude|claude-code|opencode|OpenCode|antigravity|antigravity-ide|\
    uv|copilot|kimi|gk|gitkraken|coderabbit|cr|\
    kiro-cli|kiro-cli-chat|kiro-cli-term|\
    grok|jcode|qodercli|qoderwake|kimchi|cua-driver)
      return 0 ;;
    *) return 1 ;;
  esac
}

_manual_apps_kind() {
  local name="$1"
  [[ -n "$name" ]] || { printf 'ignored'; return 0; }

  if _manual_apps_has_step "$name"; then
    printf 'covered'
    return 0
  fi

  case "$name" in
    *.manual.*|*.manual-backup-*|*.manual_backup_*|*-original|*.orig|*.bak)
      printf 'backup' ;;
    sharkd|tshark)
      printf 'auxiliary' ;;
    *)
      printf 'candidate' ;;
  esac
}

doctor_manual_apps() {
  has pacman || { log "  pacman ausente; inventário de apps manuais indisponível."; return 0; }

  local total=0 covered=0 backups=0 auxiliary=0 f d name probe kind
  local -a uncovered=() backup_items=() auxiliary_items=()

  # 1) Binários reais (regular files, não symlinks) em /usr/local/bin e ~/.local/bin
  #    sem dono pacman. pacman -Qo sobre um arquivo é confiável. Filtra por tamanho
  #    mínimo (≥ 1 MiB): apps instalados à mão são binários auto-contidos grandes
  #    (Go/Rust/Node-pkg/Electron); scripts pessoais e wrappers pequenos ficam de
  #    fora para o inventário não virar ruído.
  local bindir min_size=1048576 sz
  for bindir in /usr/local/bin "${HOME}/.local/bin"; do
    [[ -d "$bindir" ]] || continue
    for f in "$bindir"/*; do
      [[ -f "$f" && ! -L "$f" && -x "$f" ]] || continue
      sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
      (( sz >= min_size )) || continue
      pacman -Qo "$f" >/dev/null 2>&1 && continue
      name="${f##*/}"
      total=$((total + 1))
      kind="$(_manual_apps_kind "$name")"
      case "$kind" in
        covered) covered=$((covered + 1)) ;;
        backup) backups=$((backups + 1)); backup_items+=("${name}  (${bindir})") ;;
        auxiliary) auxiliary=$((auxiliary + 1)); auxiliary_items+=("${name}  (${bindir})") ;;
        *) uncovered+=("${name}  (${bindir})") ;;
      esac
    done
  done

  # 2) Diretórios de aplicação em /opt. Convencionalmente instalação manual, mas
  #    pacotes do repo/AUR também usam /opt (google-chrome, spotify, android-studio,
  #    intel-oneapi…). Probe de propriedade: se o 1º arquivo dentro pertence a um
  #    pacote, é gerenciado e não conta. Dirs vazios também são ignorados.
  if [[ -d /opt ]]; then
    for d in /opt/*/; do
      [[ -d "$d" ]] || continue
      [[ -L "${d%/}" ]] && continue          # ignora symlink (ex.: /opt/idea -> idea-X.Y)
      name="${d%/}"; name="${name##*/}"
      probe="$(find "$d" -maxdepth 2 -type f 2>/dev/null | head -1)"
      [[ -n "$probe" ]] || continue
      pacman -Qo "$probe" >/dev/null 2>&1 && continue
      total=$((total + 1))
      kind="$(_manual_apps_kind "$name")"
      case "$kind" in
        covered) covered=$((covered + 1)) ;;
        backup) backups=$((backups + 1)); backup_items+=("${name}  (/opt)") ;;
        auxiliary) auxiliary=$((auxiliary + 1)); auxiliary_items+=("${name}  (/opt)") ;;
        *) uncovered+=("${name}  (/opt)") ;;
      esac
    done
  fi

  if (( total == 0 )); then
    log "  Nenhum app fora de gerenciador de pacotes detectado."
    return 0
  fi

  log "  Apps fora de gerenciador de pacotes: ${total} (com step: ${covered}, candidatos sem step: ${#uncovered[@]}, backups/remanescentes: ${backups}, auxiliares: ${auxiliary})."
  local u shown=0
  for u in "${uncovered[@]}"; do
    if (( shown >= 25 )); then
      log "    … e mais $(( ${#uncovered[@]} - shown )) (lista completa no log)."
      break
    fi
    log "    • ${u}"
    shown=$((shown + 1))
  done

  if (( ${#uncovered[@]} > 0 )); then
    log "  Candidatos sem step atualizam-se sozinhos (GUIs/Electron) ou exigem reinstalação manual."
  fi
  if (( backups > 0 )); then
    log "  Backups/remanescentes detectados (${backups}) foram excluídos da contagem de candidatos; revise/remova manualmente quando tiver certeza."
    for u in "${backup_items[@]}"; do log_raw "manual-app-backup: ${u}"; done
  fi
  if (( auxiliary > 0 )); then
    log "  Binários auxiliares conhecidos (${auxiliary}) foram excluídos da contagem de candidatos."
    for u in "${auxiliary_items[@]}"; do log_raw "manual-app-auxiliar: ${u}"; done
  fi
  return 0
}
