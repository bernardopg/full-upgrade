#!/usr/bin/env bash
# lib/steps/tools.sh — utilitários de linha de comando fora de gestor de pacote
# (GitKraken CLI, cua-driver, purple, Android CLI, cloudflared). Plugins do OBS ficam em steps.d/85-obs.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)


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


# ── purple (cliente SSH de terminal) ────────────────────────────────────────────
# Binário self-download em ~/.local/bin/purple; `purple update` verifica checksum
# e só baixa release nova. Helper em manual_apps.sh.
update_purple() { _selfupdate_direct "purple" purple; }


# ── Android CLI (Google) ────────────────────────────────────────────────────────
# `android` (~/.local/bin, launcher em ~/.android/bin) tem três updaters
# não-interativos: `android update` (a própria CLI; "Already up-to-date" quando
# nada muda), `android skills update --all` (skills de agente instaladas) e
# `android sdk update` (pacotes do SDK: build-tools, platform-tools, platforms).
# O SDK só é tocado quando `android info` aponta um diretório existente.
# rc: 0 ok · RC_WARN rede/falha de alguma fase.
update_android_cli() {
  has android || { log "  android (Android CLI) não encontrado."; return 0; }
  local -a failed=()
  local out rc sdk

  out="$(run_network_cmd android update)"; rc=$?
  printf '%s\n' "$out" | _strip_ansi | log_out
  ((rc == 0)) || failed+=("cli")

  out="$(run_network_cmd android skills update --all)"; rc=$?
  printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:].]*$' | tail -3 | log_out
  ((rc == 0)) || failed+=("skills")

  sdk="$(android info 2>/dev/null | awk '$1=="sdk:"{print $2; exit}')"
  if [[ -n "$sdk" && -d "$sdk" ]]; then
    out="$(run_network_cmd android sdk update)"; rc=$?
    printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:]]*$' | tail -10 | log_out
    ((rc == 0)) || failed+=("sdk")
  else
    log "  Android SDK não encontrado; pulando android sdk update."
  fi

  if ((${#failed[@]} > 0)); then
    log "  Android CLI: falha em ${failed[*]}."
    STEP_REASON="android update falhou em: ${failed[*]}"
    return "$RC_WARN"
  fi
  log "  Android CLI $(android -V 2>/dev/null | tail -1), skills e SDK atualizados."
  return 0
}


# ── cloudflared fora de pacote ──────────────────────────────────────────────────
# O 9router baixa o cloudflared para ~/.9router/bin só quando ele falta e nunca
# mais o atualiza (fora do PATH, ficou seis meses parado). `cloudflared update`
# troca o binário no lugar; por convenção do upstream sai com 11 quando
# atualizou (para o supervisor reiniciar o túnel), então 0 e 11 são sucesso.
# Um cloudflared do pacman fica com o pacman: só estes caminhos são tocados.
cloudflared_manual_bins() {
  local b
  for b in "${HOME}/.9router/bin/cloudflared" "${HOME}/.local/bin/cloudflared"; do
    [[ -x "$b" && ! -L "$b" ]] && printf '%s\n' "$b"
  done
  return 0
}

# Dono de uma cópia do cloudflared ($1), para o log dizer de quem é o binário
# atualizado (a do 9router fica fora do PATH e confundia a leitura). Puro.
cloudflared_owner() {
  case "$1" in
    "${HOME}/.9router/"*) printf 'cópia embutida do 9router\n' ;;
    *) printf 'instalação manual\n' ;;
  esac
}

update_cloudflared() {
  local -a bins=()
  mapfile -t bins < <(cloudflared_manual_bins)
  ((${#bins[@]} > 0)) || { log "  Nenhum cloudflared fora de pacote."; return 0; }
  local b out rc any_fail=0
  for b in "${bins[@]}"; do
    out="$(run_network_cmd "$b" update)"
    rc=$?
    printf '%s\n' "$out" | grep -v ' INF ' | log_out
    case "$rc" in
      0 | 11) log "  ${b} ($(cloudflared_owner "$b")): $("$b" --version 2>/dev/null | awk '{print $3; exit}')" ;;
      *) log "  Falha ao atualizar ${b} (rc=${rc})."; any_fail=1 ;;
    esac
  done
  if ((any_fail)); then
    STEP_REASON="cloudflared update falhou"
    return "$RC_WARN"
  fi
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
  if ((check_rc != 0)); then
    log "  Não foi possível verificar atualização do cua-driver (rede/GitHub indisponível)."
    return "$RC_WARN"
  fi

  if grep -qiE '"update_available"[[:space:]]*:[[:space:]]*true' <<<"$check"; then
    log "  Atualizando cua-driver…"
    local apply_out apply_rc
    apply_out="$(run_network_cmd cua-driver update --apply)"
    apply_rc=$?
    printf '%s\n' "$apply_out" | log_out
    hash -r 2>/dev/null || true
    # O instalador "stopping any running cua-driver daemons before swap" mata o
    # próprio `cua-driver update --apply` depois de trocar o binário (rc 143).
    # A versão instalada é a prova: mudou, então a atualização aconteceu.
    if ((apply_rc != 0)) && [[ -n "$current" ]] \
      && [[ "$(cua-driver --version 2>/dev/null | awk 'NR==1{print $NF}')" != "$current" ]]; then
      apply_rc=0
    fi
    if ((apply_rc != 0)); then
      # O check-update anuncia a release mais nova mesmo quando o upstream a
      # retirou; o instalador recusa ("was withdrawn and must not be installed").
      # Nada a fazer localmente até sair outra release: não é aviso.
      if grep -qi 'was withdrawn' <<<"$apply_out"; then
        log "  Release anunciada foi retirada pelo upstream; mantendo cua-driver ${current:-?}."
        return 0
      fi
      log "  Falha ao atualizar o cua-driver."
      STEP_REASON="cua-driver update --apply falhou (rc=${apply_rc})"
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
  if ! run_network_cmd cua-driver skills update >/dev/null; then
    log "  Aviso: não foi possível atualizar as skills do cua-driver (rede)."
  fi
  return 0
}

update_artcraft() {
  local rc=0
  run_logged artcraft_run update || rc=$?
  if (( rc != 0 )); then
    STEP_REASON="Artcraft: atualização incompleta; confira o log (versões anteriores preservadas)"
    return "$RC_WARN"
  fi
}


# ── Herdr (herdr-core e herdr-app) ──────────────────────────────────────────────
# Instalados pelos scripts de releases.herdr.dev: o core (`hc`) em
# ~/.local/bin/herdr-core e o app em ~/.local/share/herdr-app (symlink em
# ~/.local/bin). Os manifests <releases>/{core,app}/latest.json dão a versão e,
# no app, URL + sha256 por alvo. O core se atualiza com `herdr-core update
# --version X`, que reinicia o servidor e mantém os terminais vivos; por isso só
# roda quando o manifest é mais novo. O app não tem updater: é trocado como o
# instalador oficial faz (download, sha256, troca atômica do diretório).
HERDR_RELEASES_URL="${HERDR_RELEASES_URL:-https://releases.herdr.dev}"

herdr_core_bin() { manual_bin_path herdr-core "${HOME}/.local/bin/herdr-core"; }
herdr_app_home() { printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/herdr-app"; }
herdr_installed() {
  [[ -n "$(herdr_core_bin)" || -x "$(herdr_app_home)/herdr-app" ]]
}

# Campo de topo de um manifest ($1 = JSON, $2 = campo). Puro, sem jq: o
# manifest é plano o bastante para sed depois de tirar espaços e quebras.
herdr_manifest_field() {
  tr -d '\n ' <<<"$1" | sed -nE "s/^\{(.*,)?\"$2\":\"([^\"]*)\".*/\2/p" | head -1
}

# Campo do alvo ($2, ex.: linux-x86_64) dentro de "targets" ($3 = url|sha256).
herdr_manifest_target_field() {
  local entry
  entry="$(tr -d '\n ' <<<"$1" | sed -n "s/.*\"$2\":{\([^}]*\)}.*/\1/p")"
  sed -nE "s/.*\"$3\":\"([^\"]*)\".*/\1/p" <<<"$entry" | head -1
}

herdr_target() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'linux-x86_64\n' ;;
    aarch64 | arm64) printf 'linux-aarch64\n' ;;
    *) return 1 ;;
  esac
}

# Versão X.Y.Z de uma linha como "hc 0.1.21" ou "herdr-app 0.1.15".
_herdr_version_of() { "$@" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1; }

_herdr_update_core() {
  local core="$1" cur manifest latest rc
  cur="$(_herdr_version_of "$core")"
  manifest="$(fetch_network_text --connect-timeout 10 --max-time 30 "${HERDR_RELEASES_URL}/core/latest.json")" || return "$RC_WARN"
  latest="$(herdr_manifest_field "$manifest" version)"
  if [[ -z "$latest" ]]; then
    log "  herdr-core: manifest sem versão."
    return "$RC_WARN"
  fi
  if [[ -n "$cur" ]] && ! version_is_outdated "$cur" "$latest"; then
    log "  herdr-core já na versão mais recente (${cur})."
    return 0
  fi
  log "  Atualizando herdr-core: ${cur:-?} → ${latest} (o servidor reinicia; os terminais continuam)."
  local out
  out="$(run_network_cmd "$core" update --version "$latest" </dev/null 2>&1)"
  rc=$?
  printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:]]*$' | tail -5 | log_out || true
  ((rc == 0)) || { log "  Falha ao atualizar o herdr-core (rc=${rc})."; return "$RC_WARN"; }
  log "  herdr-core agora: $(_herdr_version_of "$core")"
  return 0
}

_herdr_update_app() {
  local home="$1" app cur manifest latest target url want
  app="${home}/herdr-app"
  cur="$(_herdr_version_of "$app")"
  manifest="$(fetch_network_text --connect-timeout 10 --max-time 30 "${HERDR_RELEASES_URL}/app/latest.json")" || return "$RC_WARN"
  latest="$(herdr_manifest_field "$manifest" version)"
  if [[ -z "$latest" ]]; then
    log "  herdr-app: manifest sem versão."
    return "$RC_WARN"
  fi
  if [[ -n "$cur" ]] && ! version_is_outdated "$cur" "$latest"; then
    log "  herdr-app já na versão mais recente (${cur})."
    return 0
  fi
  target="$(herdr_target)" || { log "  herdr-app: arquitetura $(uname -m) sem build."; return 0; }
  url="$(herdr_manifest_target_field "$manifest" "$target" url)"
  want="$(herdr_manifest_target_field "$manifest" "$target" sha256)"
  if [[ -z "$url" || -z "$want" ]]; then
    log "  herdr-app ${latest}: manifest sem build ${target} ainda."
    return 0
  fi
  if ! has curl || ! has tar || ! has sha256sum; then
    log "  curl, tar e sha256sum são necessários para atualizar o herdr-app."
    return 0
  fi
  log "  Atualizando herdr-app: ${cur:-?} → ${latest}"
  local tmp got
  tmp="$(mktemp -d)" || return "$RC_WARN"
  if ! run_network_cmd curl -fsSL "$url" -o "${tmp}/app.tar.gz" >/dev/null; then
    rm -rf "$tmp"
    log "  Falha ao baixar o herdr-app ${latest}."
    return "$RC_WARN"
  fi
  got="$(sha256sum "${tmp}/app.tar.gz" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    rm -rf "$tmp"
    log "  herdr-app ${latest}: sha256 não confere (esperado ${want}, obtido ${got}); mantendo a versão atual."
    STEP_REASON="herdr-app ${latest}: checksum divergente"
    return 1
  fi
  if ! tar -xzf "${tmp}/app.tar.gz" -C "$tmp" 2>>"$LOG_FILE" || [[ ! -x "${tmp}/herdr-app/herdr-app" ]]; then
    rm -rf "$tmp"
    log "  herdr-app ${latest}: pacote sem herdr-app/herdr-app."
    return 1
  fi
  rm -rf "${home}.new" "${home}.old"
  mv "${tmp}/herdr-app" "${home}.new" \
    && mv "$home" "${home}.old" \
    && mv "${home}.new" "$home" \
    && rm -rf "${home}.old"
  rc=$?
  rm -rf "$tmp"
  if ((rc != 0)); then
    [[ -d "$home" ]] || mv "${home}.old" "$home" 2>/dev/null
    log "  Falha ao trocar ${home}."
    return 1
  fi
  log "  herdr-app agora: $(_herdr_version_of "${home}/herdr-app"). Reabra o Herdr para carregar a versão nova."
  return 0
}

update_herdr() {
  local core home rc worst=0
  core="$(herdr_core_bin)"
  home="$(herdr_app_home)"
  if [[ -n "$core" ]]; then
    _herdr_update_core "$core"
    rc=$?
    ((rc > worst)) && worst=$rc
  fi
  if [[ -x "${home}/herdr-app" ]]; then
    _herdr_update_app "$home"
    rc=$?
    ((rc == 1 || (worst != 1 && rc > worst))) && worst=$rc
  fi
  case "$worst" in
    0) return 0 ;;
    1) return 1 ;;
    *) STEP_REASON="${STEP_REASON:-Herdr: rede/manifest indisponível}"; return "$RC_WARN" ;;
  esac
}


# ── CLIProxyAPI (cli-proxy-api) ─────────────────────────────────────────────────
# Gateway local de modelos (router-for-me/CLIProxyAPI) instalado à mão a partir
# do release do GitHub. Não tem self-update nem pacote: sem este step, a cópia
# para na versão do dia da instalação. Dois layouts são suportados:
#  - versionado: ~/.local/bin/cli-proxy-api é symlink para
#    <home>/versions/<versão>/cli-proxy-api (o layout do instalador nativo do
#    Claude Code). A versão nova ganha diretório próprio e o symlink é trocado
#    de forma atômica; a anterior fica para rollback (CLIPROXYAPI_KEEP_VERSIONS);
#  - binário avulso: o arquivo é trocado por rename no mesmo diretório.
# O serviço systemd de usuário (CLIPROXYAPI_SERVICE) segura o binário antigo
# aberto até reiniciar. Com CLIPROXYAPI_RESTART_SERVICE=1 ele é reiniciado; se
# não volta ativo, o binário anterior é restaurado e o serviço reiniciado de novo.
CLIPROXYAPI_REPO="${CLIPROXYAPI_REPO:-router-for-me/CLIProxyAPI}"
# Espera depois do restart antes de conferir o serviço: com Restart=on-failure,
# um binário que cai no boot passa por "activating (auto-restart)".
CLIPROXYAPI_RESTART_SETTLE_S="${CLIPROXYAPI_RESTART_SETTLE_S:-3}"

cliproxyapi_bin() {
  if [[ -n "${CLIPROXYAPI_BIN:-}" && -x "$CLIPROXYAPI_BIN" ]]; then
    printf '%s\n' "$CLIPROXYAPI_BIN"
    return 0
  fi
  manual_bin_path cli-proxy-api "${HOME}/.local/bin/cli-proxy-api"
}

# Versão X.Y.Z do binário $1. Qualquer invocação imprime
# "CLIProxyAPI Version: 8.0.77, Commit: …" na primeira linha; -h sai logo depois
# do uso e nunca sobe o servidor (sem argumento, ele subiria).
cliproxyapi_version_of() {
  "$1" -h 2>&1 | sed -nE '1s/.*Version: v?([0-9]+(\.[0-9]+)+).*/\1/p'
}

# Arquitetura no nome do asset: CLIProxyAPI_<versão>_linux_<arch>.tar.gz.
cliproxyapi_asset_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    *) return 1 ;;
  esac
}

# Puro: raiz do layout versionado a partir do caminho REAL do binário
# (<raiz>/versions/<versão>/cli-proxy-api => <raiz>); vazio fora dele.
cliproxyapi_versions_root() {
  [[ "$1" =~ ^(.+)/versions/[^/]+/cli-proxy-api$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}

# Puro: versões a remover de <dir versions> mantendo as <keep> mais novas
# (keep < 1 vale 1). A versão em uso ($3) nunca sai, mesmo fora das N.
cliproxyapi_prune_list() {
  local dir="$1" keep="$2" current="$3" v n=0
  [[ "$keep" =~ ^[0-9]+$ ]] && ((keep >= 1)) || keep=1
  [[ -d "$dir" ]] || return 0
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    n=$((n + 1))
    ((n <= keep)) && continue
    [[ "$v" == "$current" ]] && continue
    printf '%s\n' "$v"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -rV)
}

# Reinicia o serviço de usuário e confere que ficou ativo. rc 0 · 1 não subiu.
_cliproxyapi_restart_ok() {
  local unit="$1"
  systemctl --user restart "$unit" 2>>"$LOG_FILE" || return 1
  sleep "$CLIPROXYAPI_RESTART_SETTLE_S"
  systemctl --user is-active --quiet "$unit"
}

# Põe o binário $2 (versão $3) no lugar do atual. Imprime o caminho real
# anterior (para rollback). Args: <bin> <novo> <versão> <real atual> <raiz|vazio>.
_cliproxyapi_install() {
  local bin="$1" new="$2" ver="$3" real="$4" root="$5" mode dest
  mode="$(stat -c '%a' "$real" 2>/dev/null || echo 755)"
  if [[ -n "$root" && -L "$bin" ]]; then
    dest="${root}/versions/${ver}"
    mkdir -p "$dest" && chmod 700 "$dest" || return 1
    install -m "$mode" "$new" "${dest}/cli-proxy-api" || return 1
    ln -sfn "${dest}/cli-proxy-api" "${bin}.new" || return 1
    mv -Tf "${bin}.new" "$bin" || { rm -f "${bin}.new"; return 1; }
  else
    # rename no mesmo diretório: atômico, e o processo em execução mantém o inode antigo.
    cp -p "$real" "${real}.old" || return 1
    install -m "$mode" "$new" "${real}.new" || { rm -f "${real}.new"; return 1; }
    mv -f "${real}.new" "$real" || { rm -f "${real}.new"; return 1; }
  fi
  return 0
}

# Desfaz _cliproxyapi_install: symlink de volta para o real anterior, ou o .old.
_cliproxyapi_rollback() {
  local bin="$1" old_real="$2" root="$3"
  if [[ -n "$root" && -L "$bin" ]]; then
    ln -sfn "$old_real" "${bin}.new" && mv -Tf "${bin}.new" "$bin"
  else
    mv -f "${old_real}.old" "$old_real"
  fi
}

update_cliproxyapi() {
  local bin real root cur arch tag latest
  bin="$(cliproxyapi_bin)"
  [[ -n "$bin" ]] || { log "  cli-proxy-api não encontrado."; return 0; }
  arch="$(cliproxyapi_asset_arch)" || { log "  Arquitetura $(uname -m) sem build do CLIProxyAPI; pulando."; return 0; }
  real="$(readlink -f "$bin")"
  root="$(cliproxyapi_versions_root "$real")"
  cur="$(cliproxyapi_version_of "$real")"
  log "  CLIProxyAPI em: ${bin}${root:+ (versões em ${root}/versions)} — versão atual: ${cur:-desconhecida}"

  tag="$(github_latest_release_tag "$CLIPROXYAPI_REPO")" || {
    log "  Não foi possível determinar a última versão do CLIProxyAPI (rede/GitHub indisponível)."
    STEP_REASON="última versão do CLIProxyAPI indisponível"
    return "$RC_WARN"
  }
  latest="${tag#v}"
  if [[ -n "$cur" ]] && ! version_is_outdated "$cur" "$latest"; then
    log "  CLIProxyAPI já está na versão mais recente (${cur})."
    return 0
  fi

  # Instalação de usuário: sem escrita nos diretórios, a correção é humana (nunca sudo aqui).
  local wdir
  for wdir in "$(dirname "$bin")" "${root:+${root}/versions}" "$(dirname "$real")"; do
    [[ -z "$wdir" || -w "$wdir" ]] && continue
    STEP_REASON="CLIProxyAPI: sem permissão de escrita em ${wdir}"
    return "$RC_TODO"
  done

  local tmp asset base
  asset="CLIProxyAPI_${latest}_linux_${arch}.tar.gz"
  base="https://github.com/${CLIPROXYAPI_REPO}/releases/download/${tag}"
  tmp="$(mktemp -d)" || { log "  mktemp falhou."; return "$RC_WARN"; }
  log "  Atualizando CLIProxyAPI: ${cur:-?} → ${latest}"
  local dl_ok=1
  run_network_cmd curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" >/dev/null || dl_ok=0
  ((dl_ok)) && { run_network_cmd curl -fsSL "${base}/checksums.txt" -o "${tmp}/checksums.txt" >/dev/null || dl_ok=0; }
  if ((dl_ok == 0)); then
    rm -rf "$tmp"
    # A tag sai antes de o CI anexar os binários: asset 404 com o GitHub de pé
    # não é falha, só "ainda não": mantém a versão atual e tenta no próximo run.
    local code
    local -a head_args=(-sIL --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}')
    code="$(curl "${head_args[@]}" "${base}/${asset}" 2>/dev/null || true)"
    if [[ "$code" == 404 ]]; then
      log "  Release ${tag} ainda sem o asset ${asset}; mantendo ${cur:-a versão atual}."
      return 0
    fi
    log "  Falha de rede ao baixar o release do CLIProxyAPI."
    STEP_REASON="download do CLIProxyAPI ${latest} falhou"
    return "$RC_WARN"
  fi

  # Integridade OBRIGATÓRIA: sem a linha do asset no checksums.txt, sha256sum -c falha.
  local got verified=1
  (cd "$tmp" && grep -F "  ${asset}" checksums.txt | sha256sum -c -) >>"$LOG_FILE" 2>&1 || verified=0
  ((verified)) && { tar -xzf "${tmp}/${asset}" -C "$tmp" cli-proxy-api >>"$LOG_FILE" 2>&1 || verified=0; }
  if ((verified == 0)); then
    rm -rf "$tmp"
    log "  Checksum ou extração do CLIProxyAPI ${latest} falhou; binário mantido."
    STEP_REASON="CLIProxyAPI ${latest} não verificado"
    return 1
  fi
  got="$(cliproxyapi_version_of "${tmp}/cli-proxy-api")"
  if [[ "$got" != "$latest" ]]; then
    rm -rf "$tmp"
    log "  O binário do release ${tag} diz ser a versão ${got:-?}; binário mantido."
    STEP_REASON="CLIProxyAPI ${latest}: versão do binário não confere"
    return 1
  fi

  if ! _cliproxyapi_install "$bin" "${tmp}/cli-proxy-api" "$latest" "$real" "$root" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    log "  Falha ao instalar o CLIProxyAPI ${latest}; binário mantido."
    STEP_REASON="instalação do CLIProxyAPI ${latest} falhou"
    return 1
  fi
  rm -rf "$tmp"
  hash -r 2>/dev/null || true

  local unit="${CLIPROXYAPI_SERVICE:-cliproxyapi.service}"
  if has systemctl && systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    if [[ "${CLIPROXYAPI_RESTART_SERVICE:-1}" != 1 ]]; then
      log "  ${unit} segue com ${cur:-a versão anterior} até reiniciar (CLIPROXYAPI_RESTART_SERVICE=0)."
    elif _cliproxyapi_restart_ok "$unit"; then
      log "  ${unit} reiniciado com a versão ${latest}."
    else
      log "  ${unit} não ficou ativo com a ${latest}; restaurando ${cur:-a versão anterior}."
      _cliproxyapi_rollback "$bin" "$real" "$root" 2>>"$LOG_FILE"
      _cliproxyapi_restart_ok "$unit" || log "  ${unit} também não subiu com a versão anterior; veja: journalctl --user -u ${unit}"
      [[ -n "$root" ]] && rm -rf "${root}/versions/${latest}"
      STEP_REASON="CLIProxyAPI ${latest} não subiu o ${unit}; revertido para ${cur:-a anterior}"
      return 1
    fi
  fi
  [[ -z "$root" ]] && rm -f "${real}.old"

  if [[ -n "$root" ]]; then
    local v
    while IFS= read -r v; do
      rm -rf "${root}/versions/${v:?}" && log "  Versão antiga removida: ${v}"
    done < <(cliproxyapi_prune_list "${root}/versions" "${CLIPROXYAPI_KEEP_VERSIONS:-2}" "$latest")
  fi
  log "  CLIProxyAPI atualizado para ${latest}."
  return 0
}


# ── Extensões do GitHub CLI (gh) ────────────────────────────────────────────────
# `gh extension install` clona cada extensão em ~/.local/share/gh/extensions (ou
# baixa o binário do release). O pacote github-cli atualiza o gh, nunca as
# extensões: elas param na versão do dia da instalação. `gh extension upgrade
# --all` resolve, pulando sozinho as fixadas (--pin) e as locais.
# Extensão cujo repositório sumiu (apagado, privado, renomeado) falha em todo
# run e nunca se recupera sozinha: vira todo com a remediação, não fail.
GH_EXT_GONE_RE='(Not Found|HTTP 404|repository not found|could not resolve to a Repository)'
GH_EXT_RATE_RE='(rate limit|HTTP 403|HTTP 429|secondary rate)'

# Puro: nomes das extensões (coluna 1 de `gh extension list`, sem o prefixo "gh ").
gh_extension_names() {
  awk -F'\t' 'NF && $1 != "" { n = $1; sub(/^gh /, "", n); print n }' <<<"$1"
}

update_gh_extensions() {
  local list names n out rc
  list="$(NO_COLOR=1 gh extension list 2>/dev/null)"
  names="$(gh_extension_names "$list")"
  n="$(grep -c . <<<"$names")"
  if ((n == 0)); then
    log "  Nenhuma extensão do gh instalada."
    return 0
  fi
  log "  ${n} extensão(ões) do gh: $(tr '\n' ' ' <<<"$names")"
  out="$(run_network_cmd env GH_PROMPT_DISABLED=1 NO_COLOR=1 gh extension upgrade --all)"
  rc=$?
  printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:]]*$' | log_stream
  ((rc == 0)) && return 0
  if ((rc == RC_WARN)) || grep -qiE "$GH_EXT_RATE_RE" <<<"$out"; then
    STEP_REASON="gh extension upgrade: rede ou limite da API do GitHub"
    return "$RC_WARN"
  fi
  if grep -qiE "$GH_EXT_GONE_RE" <<<"$out"; then
    log "  Extensão com repositório inacessível: remova com 'gh extension remove <nome>' ou reinstale da origem nova."
    STEP_REASON="extensão do gh com repositório inacessível (gh extension remove/install)"
    return "$RC_TODO"
  fi
  STEP_REASON="gh extension upgrade --all falhou (rc=${rc})"
  return 1
}


# ── Proton-GE (compatibilitytools.d do Steam) ──────────────────────────────────
# Build do GloriousEggroll instalado à mão em compatibilitytools.d: nem o Steam
# nem o pacman o atualizam. A versão nova entra AO LADO das antigas, porque o
# Steam fixa a ferramenta por jogo; PROTON_GE_KEEP > 0 poda as mais velhas
# (0 = nunca remove). O tarball é conferido contra o .sha512sum do release.
PROTON_GE_REPO="${PROTON_GE_REPO:-GloriousEggroll/proton-ge-custom}"

# Diretório compatibilitytools.d que já tem algum GE-Proton* (o step não
# instala Proton-GE em máquina que nunca o usou). PROTON_GE_DIR força um.
proton_ge_dir() {
  local -a cands=()
  local d
  if [[ -n "${PROTON_GE_DIR:-}" ]]; then
    cands+=("$PROTON_GE_DIR")
  else
    cands+=("${XDG_DATA_HOME:-$HOME/.local/share}/Steam/compatibilitytools.d")
    cands+=("$HOME/.steam/root/compatibilitytools.d")
    cands+=("$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d")
  fi
  for d in "${cands[@]}"; do
    compgen -G "${d}/GE-Proton*" >/dev/null || continue
    readlink -f "$d"
    return 0
  done
  return 0
}

# Puro: versões GE-Proton* a remover mantendo as <keep> mais novas (0 = nenhuma).
proton_ge_prune_list() {
  local dir="$1" keep="$2"
  [[ "$keep" =~ ^[0-9]+$ ]] && ((keep > 0)) || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'GE-Proton*' -printf '%f\n' | sort -rV | tail -n +"$((keep + 1))"
}

update_proton_ge() {
  local dir tag arch tmp asset base
  dir="$(proton_ge_dir)"
  [[ -n "$dir" ]] || { log "  Nenhum GE-Proton em compatibilitytools.d."; return 0; }
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64) arch=aarch64 ;;
    *) log "  Arquitetura $(uname -m) sem build do Proton-GE; pulando."; return 0 ;;
  esac
  tag="$(github_latest_release_tag "$PROTON_GE_REPO" '^GE-Proton[0-9]+-[0-9]+$')" || {
    STEP_REASON="última versão do Proton-GE indisponível"
    return "$RC_WARN"
  }
  if [[ -d "${dir}/${tag}" ]]; then
    log "  ${tag} já instalado em ${dir}."
  else
    asset="${tag}-${arch}.tar.gz"
    base="https://github.com/${PROTON_GE_REPO}/releases/download/${tag}"
    # Extrai no mesmo sistema de arquivos para o mv final ser atômico.
    tmp="$(mktemp -d "${dir}/.full-upgrade-XXXXXX")" || return "$RC_WARN"
    log "  Baixando ${tag} (~500 MB)…"
    local ok=1
    run_network_cmd curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" >/dev/null || ok=0
    ((ok)) && { run_network_cmd curl -fsSL "${base}/${tag}-${arch}.sha512sum" -o "${tmp}/sum" >/dev/null || ok=0; }
    if ((ok == 0)); then
      rm -rf "${tmp:?}"
      STEP_REASON="download do ${tag} falhou"
      return "$RC_WARN"
    fi
    (cd "$tmp" && sha512sum -c sum) >>"$LOG_FILE" 2>&1 || ok=0
    ((ok)) && { tar -xzf "${tmp}/${asset}" -C "$tmp" >>"$LOG_FILE" 2>&1 || ok=0; }
    [[ -d "${tmp}/${tag}" ]] || ok=0
    if ((ok == 0)); then
      rm -rf "${tmp:?}"
      STEP_REASON="${tag}: checksum ou extração falhou"
      return 1
    fi
    mv "${tmp}/${tag}" "${dir}/${tag}"
    rm -rf "${tmp:?}"
    log "  ${tag} instalado. Reinicie o Steam e escolha-o em Propriedades > Compatibilidade."
  fi
  local v
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    rm -rf "${dir:?}/${v:?}" && log "  Versão antiga removida: ${v}"
  done <<<"$(proton_ge_prune_list "$dir" "${PROTON_GE_KEEP:-0}")"
  return 0
}


# ── Spicetify ───────────────────────────────────────────────────────────────────
# Cada update do Spotify (pacote ou spotify-launcher) troca os arquivos que o
# Spicetify patcheia: o tema e as extensões somem em silêncio. `spicetify apply`
# reaplica; quando o Spotify mudou de versão ele pede um backup novo, e aí o
# caminho é `backup apply`. O CLI instalado pelo script oficial (no $HOME) se
# atualiza com `spicetify upgrade`; o do AUR fica com o pacman.
SPICETIFY_BACKUP_RE='(versions? (are|is) mismatch|Spotify version and backup version|spicetify backup|backup is outdated|no backup)'

update_spicetify() {
  local bin out rc
  bin="$(readlink -f "$(type -P spicetify)")"
  if [[ "$bin" == "$HOME"/* ]]; then
    _native_update "spicetify upgrade" spicetify upgrade || return $?
  fi
  out="$(spicetify -n apply 2>&1)"
  rc=$?
  log_raw "$out"
  if ((rc != 0)) || grep -qiE "$SPICETIFY_BACKUP_RE" <<<"$out"; then
    log "  Spotify mudou desde o último backup do Spicetify; refazendo backup apply."
    out="$(spicetify -n backup apply 2>&1)"
    rc=$?
    log_raw "$out"
  fi
  printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:]]*$' | tail -n 5 | log_stream
  ((rc == 0)) && return 0
  if grep -qiE 'permission denied|permissão negada' <<<"$out"; then
    STEP_REASON="spicetify sem escrita na instalação do Spotify (veja 'spicetify config spotify_path')"
    return "$RC_TODO"
  fi
  STEP_REASON="spicetify apply falhou (rc=${rc})"
  return 1
}


# ── Plugins do kubectl (krew) e do Helm ─────────────────────────────────────────
# O kubectl e o helm vêm do pacman; os plugins instalados por eles não.
krew_installed() { has kubectl && kubectl krew version >/dev/null 2>&1; }

# `krew upgrade` renova o índice antes e atualiza o próprio krew junto.
update_krew_plugins() { _native_update "kubectl krew upgrade" kubectl krew upgrade; }

# Puro: nomes da 1ª coluna de `helm plugin list`, sem o cabeçalho.
helm_plugin_names() { awk 'NR > 1 && NF { print $1 }' <<<"$1"; }

update_helm_plugins() {
  local names p rc worst=0
  names="$(helm_plugin_names "$(helm plugin list 2>/dev/null)")"
  [[ -n "$names" ]] || { log "  Nenhum plugin do Helm instalado."; return 0; }
  while IFS= read -r p; do
    _native_update "helm plugin update ${p}" helm plugin update "$p"
    rc=$?
    ((rc == 1 || (worst != 1 && rc > worst))) && worst=$rc
  done <<<"$names"
  return "$worst"
}


# ── AppImages com informação de update (zsync) ──────────────────────────────────
# AppImages baixados à mão não têm dono. Os que embutem update information
# (zsync) se atualizam por delta com appimageupdatetool, que guarda a cópia
# antiga como <arquivo>.zs-old (apagada no run seguinte). Sem update
# information, o AppImage só é listado. APPIMAGE_DIRS substitui os padrões.
appimage_files() {
  local -a dirs=()
  local d f
  if [[ -n "${APPIMAGE_DIRS:-}" ]]; then
    read -ra dirs <<<"${APPIMAGE_DIRS//,/ }"
  else
    dirs+=("$HOME/Applications" "$HOME/AppImages" "$HOME/.local/bin" "$HOME/.local/opt")
  fi
  for d in "${dirs[@]}"; do
    d="${d/#\~/$HOME}"
    [[ -d "$d" ]] || continue
    for f in "$d"/*.AppImage "$d"/*.appimage; do
      [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"
    done
  done
  return 0
}

update_appimages() {
  local f name rc n_upd=0 n_manual=0 n_fail=0
  local -a files=()
  mapfile -t files <<<"$(appimage_files)"
  [[ -n "${files[0]:-}" ]] || { log "  Nenhum AppImage encontrado."; return 0; }
  for f in "${files[@]}"; do
    name="$(basename "$f")"
    rm -f "${f}.zs-old"
    # -j só checa: rc 1 = update disponível, 0 = em dia; outro = sem update info.
    appimageupdatetool -j "$f" >/dev/null 2>>"$LOG_FILE"
    rc=$?
    case "$rc" in
      0) log "  ${name}: em dia." ;;
      1)
        if _native_update "appimageupdatetool ${name}" appimageupdatetool "$f"; then
          n_upd=$((n_upd + 1))
          log "  ${name}: atualizado (cópia anterior em ${name}.zs-old)."
        else
          n_fail=$((n_fail + 1))
        fi
        ;;
      *)
        n_manual=$((n_manual + 1))
        log "  ${name}: sem informação de update embutida; atualize pelo site do projeto."
        ;;
    esac
  done
  log "  AppImages: ${n_upd} atualizado(s), ${n_manual} sem update automático, ${n_fail} falha(s)."
  if ((n_fail > 0)); then
    STEP_REASON="${n_fail} AppImage(s) não atualizado(s); veja o log"
    return "$RC_WARN"
  fi
  return 0
}


# ── Nerd Fonts instaladas à mão ─────────────────────────────────────────────────
# Fontes de ryanoasis/nerd-fonts copiadas para ~/.local/share/fonts não têm
# dono. O step cuida das famílias em NERD_FONTS_DIR/<Família>/, onde <Família>
# é o nome do asset do release (JetBrainsMono, FiraCode, Hack…). A versão
# instalada fica em <Família>/.nf-version; sem o arquivo, a família é
# reinstalada (só pula quando PROVA que está em dia). Conferência pelo
# SHA-256.txt do release, troca atômica do diretório e fc-cache no fim.
NERD_FONTS_REPO="${NERD_FONTS_REPO:-ryanoasis/nerd-fonts}"

nerd_fonts_dir() { printf '%s\n' "${NERD_FONTS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fonts/NerdFonts}"; }

# Famílias gerenciadas: subdiretórios com algum *NerdFont* dentro.
nerd_font_families() {
  local root d
  root="$(nerd_fonts_dir)"
  [[ -d "$root" ]] || return 0
  for d in "$root"/*/; do
    compgen -G "${d}*NerdFont*" >/dev/null && basename "$d"
  done
  return 0
}

_nerd_font_install() {
  local root="$1" fam="$2" tag="$3" sums="$4" tmp ok=1
  tmp="$(mktemp -d "${root}/.full-upgrade-XXXXXX")" || return "$RC_WARN"
  if ! run_network_cmd curl -fsSL "https://github.com/${NERD_FONTS_REPO}/releases/download/${tag}/${fam}.tar.xz" -o "${tmp}/${fam}.tar.xz" >/dev/null; then
    rm -rf "${tmp:?}"
    log "  ${fam}: download falhou."
    return "$RC_WARN"
  fi
  (cd "$tmp" && grep -E "  ${fam}\.tar\.xz$" "$sums" | sha256sum -c -) >>"$LOG_FILE" 2>&1 || ok=0
  ((ok)) && { mkdir "${tmp}/${fam}" && tar -xJf "${tmp}/${fam}.tar.xz" -C "${tmp}/${fam}" >>"$LOG_FILE" 2>&1 || ok=0; }
  if ((ok == 0)); then
    rm -rf "${tmp:?}"
    log "  ${fam}: checksum ou extração falhou; mantendo a versão atual."
    return 1
  fi
  printf '%s\n' "${tag#v}" >"${tmp}/${fam}/.nf-version"
  rm -rf "${root:?}/${fam:?}.old"
  mv "${root}/${fam}" "${root}/${fam}.old" && mv "${tmp}/${fam}" "${root}/${fam}" && rm -rf "${root:?}/${fam:?}.old"
  rm -rf "${tmp:?}"
  log "  ${fam}: atualizada para ${tag#v}."
  return 0
}

update_nerd_fonts() {
  local root tag latest fam cur rc worst=0 changed=0 sums
  root="$(nerd_fonts_dir)"
  local -a fams=()
  mapfile -t fams <<<"$(nerd_font_families)"
  [[ -n "${fams[0]:-}" ]] || { log "  Nenhuma família Nerd Font em ${root}."; return 0; }
  tag="$(github_latest_release_tag "$NERD_FONTS_REPO")" || {
    STEP_REASON="última versão das Nerd Fonts indisponível"
    return "$RC_WARN"
  }
  latest="${tag#v}"
  sums="$(mktemp)" || return "$RC_WARN"
  if ! run_network_cmd curl -fsSL "https://github.com/${NERD_FONTS_REPO}/releases/download/${tag}/SHA-256.txt" -o "$sums" >/dev/null; then
    rm -f "$sums"
    STEP_REASON="SHA-256.txt das Nerd Fonts ${latest} indisponível"
    return "$RC_WARN"
  fi
  for fam in "${fams[@]}"; do
    cur="$(cat "${root}/${fam}/.nf-version" 2>/dev/null)"
    if [[ -n "$cur" ]] && ! version_is_outdated "$cur" "$latest"; then
      log "  ${fam}: em dia (${cur})."
      continue
    fi
    if ! grep -qE "  ${fam}\.tar\.xz$" "$sums"; then
      log "  ${fam}: o release ${latest} não tem ${fam}.tar.xz (use o nome do asset no diretório)."
      continue
    fi
    _nerd_font_install "$root" "$fam" "$tag" "$sums"
    rc=$?
    ((rc == 0)) && changed=1
    ((rc == 1 || (worst != 1 && rc > worst))) && worst=$rc
  done
  rm -f "$sums"
  ((changed)) && has fc-cache && fc-cache -f "$root" >>"$LOG_FILE" 2>&1
  ((worst == 0)) && return 0
  STEP_REASON="Nerd Fonts: atualização incompleta; veja o log"
  return "$worst"
}


# ── Plugins do KiCad (Plugin and Content Manager) ───────────────────────────────
# O PCM só atualiza pela GUI e o pacote kicad não toca em plugins de terceiros.
# O step é só leitura: compara installed_packages.json com o packages.json atual
# de cada repositório (URL lida do cache do próprio PCM) e devolve todo com a
# lista. Instalar o zip por fora pularia a contabilidade do KiCad.

# Diretório de config da versão mais nova do KiCad que tem installed_packages.json.
kicad_pcm_config_dir() {
  local d
  d="$(find "${XDG_CONFIG_HOME:-$HOME/.config}/kicad" -mindepth 2 -maxdepth 2 -name installed_packages.json -printf '%h\n' 2>/dev/null | sort -V | tail -1)"
  [[ -n "$d" ]] && printf '%s\n' "$d"
  return 0
}

# Puro: "id<TAB>versão<TAB>repo_id" dos pacotes instalados e não fixados.
kicad_pcm_installed() {
  jq -r '.packages[] | select(.pinned != true) | [.package.identifier, .current_version, .repository_id] | @tsv' "$1" 2>/dev/null
}

# Puro: última versão não-deprecated de <id> ($2) num packages.json ($1).
kicad_pcm_latest() {
  jq -r --arg id "$2" '.packages[] | select(.identifier == $id) | .versions[] | select(.status != "deprecated") | .version' "$1" 2>/dev/null | sort -V | tail -1
}

check_kicad_plugins() {
  local cfg ver cache id cur repo url latest pkgs f
  cfg="$(kicad_pcm_config_dir)"
  [[ -n "$cfg" ]] || { log "  Nenhum pacote do PCM do KiCad instalado."; return 0; }
  ver="$(basename "$cfg")"
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/kicad/${ver}/pcm"
  local -a pending=()
  local -A fetched=()
  while IFS=$'\t' read -r id cur repo; do
    [[ -n "$id" ]] || continue
    if [[ -z "${fetched[$repo]:-}" ]]; then
      fetched[$repo]="-"
      url="$(jq -r '.packages.url // empty' "${cache}/${repo}/repository.json" 2>/dev/null)"
      pkgs="$(mktemp)" || return "$RC_WARN"
      if [[ -n "$url" ]] && fetch_network_text --connect-timeout 10 --max-time 60 "$url" >"$pkgs"; then
        fetched[$repo]="$pkgs"
      else
        rm -f "$pkgs"
        log "  Índice do repositório ${repo} indisponível; pacotes dele não conferidos."
      fi
    fi
    [[ "${fetched[$repo]}" == - ]] && continue
    latest="$(kicad_pcm_latest "${fetched[$repo]}" "$id")"
    if [[ -n "$latest" ]] && version_is_outdated "$cur" "$latest"; then
      pending+=("${id} ${cur} → ${latest}")
    else
      log "  ${id}: em dia (${cur})."
    fi
  done <<<"$(kicad_pcm_installed "${cfg}/installed_packages.json")"
  for f in "${fetched[@]}"; do
    [[ "$f" != - ]] && rm -f "$f"
  done
  ((${#pending[@]} == 0)) && return 0
  printf '%s\n' "${pending[@]}" | log_stream
  remediation "KiCad > Gerenciador de Plugins e Conteúdo > Atualizações"
  STEP_REASON="${#pending[@]} plugin(s) do KiCad com versão nova no PCM"
  return "$RC_TODO"
}


# ── arkenfox user.js nos perfis do Firefox ──────────────────────────────────────
# O arkenfox é um user.js baixado à mão em cada perfil, com o updater.sh do
# projeto ao lado. Ninguém o atualiza. `updater.sh -s -u` atualiza o próprio
# updater e o user.js sem perguntar, preservando o user-overrides.js; vale no
# próximo start do Firefox.
arkenfox_profiles() {
  local root d
  for root in "$HOME/.mozilla/firefox" "$HOME/.librewolf"; do
    [[ -d "$root" ]] || continue
    for d in "$root"/*/; do
      [[ -x "${d}updater.sh" && -f "${d}user.js" ]] || continue
      grep -q 'arkenfox' "${d}user.js" 2>/dev/null && printf '%s\n' "${d%/}"
    done
  done
  return 0
}

update_arkenfox() {
  local d rc worst=0
  local -a profiles=()
  mapfile -t profiles <<<"$(arkenfox_profiles)"
  [[ -n "${profiles[0]:-}" ]] || { log "  Nenhum perfil com o user.js do arkenfox."; return 0; }
  for d in "${profiles[@]}"; do
    log "  Perfil $(basename "$d"):"
    (cd "$d" && _native_update "arkenfox ($(basename "$d"))" ./updater.sh -s -u)
    rc=$?
    ((rc == 1 || (worst != 1 && rc > worst))) && worst=$rc
  done
  ((worst == 0)) || STEP_REASON="arkenfox: updater.sh falhou em algum perfil"
  return "$worst"
}
