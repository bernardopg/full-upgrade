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
      0 | 11) log "  ${b}: $("$b" --version 2>/dev/null | awk '{print $3; exit}')" ;;
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
