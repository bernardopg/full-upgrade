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
