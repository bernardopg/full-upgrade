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
  printf '%s\n' "$out" >>"$LOG_FILE"
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
  printf '%s\n' "$out" >>"$LOG_FILE"
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
    hermes|ollama|claude|claude-code|opencode|OpenCode|antigravity|\
    uv|copilot|kimi|gk|gitkraken|coderabbit|cr|\
    kiro-cli|kiro-cli-chat|kiro-cli-term)
      return 0 ;;
    *) return 1 ;;
  esac
}

doctor_manual_apps() {
  has pacman || { log "  pacman ausente; inventário de apps manuais indisponível."; return 0; }

  local total=0 covered=0 f d name probe
  local -a uncovered=()

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
      if _manual_apps_has_step "$name"; then
        covered=$((covered + 1))
      else
        uncovered+=("${name}  (${bindir})")
      fi
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
      if _manual_apps_has_step "$name"; then
        covered=$((covered + 1))
      else
        uncovered+=("${name}  (/opt)")
      fi
    done
  fi

  if (( total == 0 )); then
    log "  Nenhum app fora de gerenciador de pacotes detectado."
    return 0
  fi

  log "  Apps fora de gerenciador de pacotes: ${total} (com step de atualização: ${covered}, sem step: ${#uncovered[@]})."
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
    log "  Itens 'sem step' atualizam-se sozinhos (GUIs/Electron) ou exigem reinstalação manual."
  fi
  return 0
}
