#!/usr/bin/env bash
# steps.d/burp-wireshark — Burp Suite installer + Wireshark perms (custom do autor)
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2120,SC2154  # tool custom legado do autor

burpsuite_desktop_release_info() {
  python - <<'PY'
import re
import sys
import urllib.request

index = urllib.request.urlopen("https://portswigger.net/burp/releases", timeout=30).read().decode()
match = re.search(r'href="(/burp/releases/professional-community-[^"]+)"', index)
if not match:
    raise SystemExit("release page not found")

release_url = "https://portswigger.net" + match.group(1)
page = urllib.request.urlopen(release_url, timeout=30).read().decode()
version_match = re.search(r'startdownload\?product=desktop&amp;version=([^&]+)&amp;type=jar', page)
jar_match = re.search(
    r'<option\s+md5Checksum=([0-9a-f]{32})\s+buildCategoryId=desktop\s+sha256Checksum=([0-9a-f]{64})\s+value=Jar>',
    page,
    re.S,
)
if not version_match or not jar_match:
    raise SystemExit("desktop jar metadata not found")

version = version_match.group(1)
sha256 = jar_match.group(2)
url = f"https://portswigger.net/burp/releases/startdownload?product=desktop&version={version}&type=jar"
print(f"{version}\t{sha256}\t{url}")
PY
}

burpsuite_java_bin() {
  local candidate

  for candidate in \
    "${BURPSUITE_JAVA_BIN:-}" \
    "${JAVA_BIN:-}" \
    /usr/lib/jvm/java-26-openjdk/bin/java \
    /usr/lib/jvm/java-21-openjdk/bin/java \
    "$(command -v java 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

install_burpsuite_desktop_fallback() {
  local info version sha256 url pkgver current tmpdir jar source_candidate cache_dir cache_candidate java_bin

  if ! has curl || ! has makepkg || ! has python; then
    log "  Fallback do Burp requer curl, makepkg e python."
    return 1
  fi

  java_bin="$(burpsuite_java_bin)" || {
    log "  Fallback do Burp requer Java 21+ instalado."
    return 1
  }

  info="$(burpsuite_desktop_release_info 2>&1)" || {
    printf '%s\n' "$info" | tee -a "$LOG_FILE"
    return 1
  }

  IFS=$'\t' read -r version sha256 url <<<"$info"
  pkgver="${version//-/.}"
  current="$(pacman -Q burpsuite 2>/dev/null | awk '{print $2}' | sed 's/-[0-9][0-9]*$//' || true)"

  if [[ "$current" == "$pkgver" ]]; then
    log "  burpsuite ${pkgver} ja instalado."
    return 0
  fi

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/burpsuite-pkg.XXXXXX")"
  jar="${tmpdir}/burpsuite-${pkgver}.jar"
  source_candidate="${HOME}/Downloads/burpsuite_desktop_v${version}.jar"
  cache_dir="${LOG_DIR}/burpsuite"
  cache_candidate="${cache_dir}/burpsuite_desktop_v${version}.jar"

  if [[ -f "$cache_candidate" ]] && printf '%s  %s\n' "$sha256" "$cache_candidate" | sha256sum -c - >/dev/null 2>&1; then
    log "  Reutilizando JAR oficial em cache: ${cache_candidate}"
    cp -- "$cache_candidate" "$jar"
  elif [[ -f "$source_candidate" ]] && printf '%s  %s\n' "$sha256" "$source_candidate" | sha256sum -c - >/dev/null 2>&1; then
    log "  Reutilizando JAR oficial ja baixado: ${source_candidate}"
    cp -- "$source_candidate" "$jar"
  else
    log "  Baixando Burp Suite Desktop ${version} do PortSwigger."
    run_logged curl -L --fail -o "$jar" "$url" || {
      rm -rf -- "$tmpdir"
      return 1
    }
  fi

  printf '%s  %s\n' "$sha256" "$jar" | tee -a "$LOG_FILE" | sha256sum -c - || {
    rm -rf -- "$tmpdir"
    return 1
  }
  mkdir -p "$cache_dir"
  cp -- "$jar" "$cache_candidate"

  cat >"${tmpdir}/PKGBUILD" <<EOF
pkgname=burpsuite
pkgver=${pkgver}
pkgrel=1
pkgdesc="Burp Suite Desktop from PortSwigger"
url="https://portswigger.net/burp/"
depends=('java-runtime>=21')
arch=('any')
license=('custom')
source=("burpsuite-\${pkgver}.jar")
sha256sums=('${sha256}')

package() {
  install -Dm644 "burpsuite-\${pkgver}.jar" "\${pkgdir}/usr/share/burpsuite/burpsuite.jar"
  install -Dm644 /dev/null "\${pkgdir}/usr/share/applications/burpsuite.desktop"
  printf '%s\n' \\
    '[Desktop Entry]' \\
    'Type=Application' \\
    'Name=Burp Suite' \\
    'Exec=burpsuite %U' \\
    'Icon=burpsuite' \\
    'Categories=Development;Security;' \\
    'StartupWMClass=burp-StartBurp' \\
    > "\${pkgdir}/usr/share/applications/burpsuite.desktop"

  install -Dm755 /dev/null "\${pkgdir}/usr/bin/burpsuite"
  printf '%s\n' \\
    '#!/bin/sh' \\
    'for candidate in "\${BURPSUITE_JAVA_BIN:-}" "\${JAVA_BIN:-}" "${java_bin}" /usr/lib/jvm/java-26-openjdk/bin/java /usr/lib/jvm/java-21-openjdk/bin/java "\$(command -v java 2>/dev/null)"; do' \\
    '  [ -n "\$candidate" ] && [ -x "\$candidate" ] && JAVA_BIN="\$candidate" && break' \\
    'done' \\
    'if [ -z "\${JAVA_BIN:-}" ]; then' \\
    '  echo "Burp Suite requer Java 21+." >&2' \\
    '  exit 1' \\
    'fi' \\
    'exec "\$JAVA_BIN" --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.desktop/javax.swing=ALL-UNNAMED -jar /usr/share/burpsuite/burpsuite.jar "\$@"' \\
    > "\${pkgdir}/usr/bin/burpsuite"
}
EOF

  (
    cd "$tmpdir"
    run_logged makepkg -f --noconfirm
  ) || {
    rm -rf -- "$tmpdir"
    return 1
  }

  local _burp_pkg
  _burp_pkg="$(find "$tmpdir" -maxdepth 1 -name "burpsuite-${pkgver}-1-any.pkg.tar.*" ! -name "*-debug*" | head -1)"
  run_logged sudo pacman -U --noconfirm "$_burp_pkg" || {
    rm -rf -- "$tmpdir"
    return 1
  }

  rm -rf -- "$tmpdir"
}

install_arch_package() {
  local pkg="$1"

  if pacman -Q "$pkg" >/dev/null 2>&1; then
    log "  ${pkg} ja instalado."
    return 0
  fi

  _install_arch_package_via_helper "$pkg"
}

upgrade_arch_package() {
  local pkg="$1"
  local installed_ver available_ver

  installed_ver="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}' || true)"

  if [[ -n "$installed_ver" ]]; then
    # checar se há versão nova disponível antes de invocar o helper
    available_ver="$(paru -Si "$pkg" 2>/dev/null | awk '/^Version/{print $3; exit}' || true)"
    if [[ -n "$available_ver" && "$installed_ver" == "$available_ver" ]]; then
      log "  ${pkg} ${installed_ver} já na versão mais recente."
      return 0
    fi
    if [[ -n "$available_ver" ]]; then
      log "  ${pkg}: ${installed_ver} → ${available_ver}"
    fi
  fi

  _install_arch_package_via_helper "$pkg"
}

_install_arch_package_via_helper() {
  local pkg="$1"

  if has paru; then
    if run_logged paru -S --needed --skipreview --noconfirm "$pkg"; then
      return 0
    fi
    if [[ "$pkg" == "burpsuite" ]]; then
      log "  AUR burpsuite falhou; tentando fallback com JAR oficial validado."
      install_burpsuite_desktop_fallback
      return $?
    fi
    return 1
  fi

  if has yay; then
    if run_logged yay -S --needed --noconfirm --answerclean None --answerdiff None --answeredit None "$pkg"; then
      return 0
    fi
    if [[ "$pkg" == "burpsuite" ]]; then
      log "  AUR burpsuite falhou; tentando fallback com JAR oficial validado."
      install_burpsuite_desktop_fallback
      return $?
    fi
    return 1
  fi

  run_logged sudo pacman -S --needed --noconfirm "$pkg"
}

ensure_security_tools() {
  local -a failed=()

  # wireshark-qt: pacote oficial extra — verifica e atualiza se necessário
  if ! upgrade_arch_package wireshark-qt; then
    failed+=(wireshark-qt)
  fi

  # burpsuite: AUR travado em FULL_UPGRADE_AUR_IGNORE; update via fallback PortSwigger apenas
  # quando não estava instalado antes (instalação nova). Runs com burpsuite já presente não
  # precisam hit de rede no PortSwigger — _install_arch_package_via_helper já chama o fallback
  # se paru falhar.
  local _burp_pre_ver
  _burp_pre_ver="$(pacman -Q burpsuite 2>/dev/null | awk '{print $2}' || true)"
  if ! install_arch_package burpsuite; then
    failed+=(burpsuite)
  elif [[ -z "$_burp_pre_ver" ]]; then
    # instalação nova — sincronizar fallback para garantir .desktop e ícones
    if ! install_burpsuite_desktop_fallback; then
      log "  Não foi possivel verificar/atualizar Burp pelo fallback oficial agora."
    fi
  fi

  if (( ${#failed[@]} > 0 )); then
    log "  Falha ao garantir pacote(s): ${failed[*]}"
    return 1
  fi

  return 0
}


repair_wireshark_capture_permissions() {
  if [[ ! -e /usr/bin/dumpcap ]]; then
    log "  dumpcap não encontrado."
    return 1
  fi

  if ! getent group wireshark >/dev/null 2>&1; then
    log "  Grupo wireshark não encontrado."
    return 1
  fi

  run_logged sudo chgrp wireshark /usr/bin/dumpcap
  run_logged sudo chmod 750 /usr/bin/dumpcap

  if has setcap; then
    run_logged sudo setcap cap_net_raw,cap_net_admin,cap_dac_override+eip /usr/bin/dumpcap
  else
    log "  setcap não instalado; não foi possivel configurar capabilities."
    return 1
  fi
}

repair_broken_burpsuite_desktop_entries() {
  local dir="${HOME}/.local/share/applications"
  local -a entries=()
  local entry exec_path backup

  [[ -d "$dir" ]] || return 0

  mapfile -t entries < <(find "$dir" -maxdepth 1 -type f -iname '*BurpSuite*.desktop' -print 2>/dev/null)
  if (( ${#entries[@]} == 0 )); then
    log "  Sem atalhos locais antigos do Burp."
    return 0
  fi

  for entry in "${entries[@]}"; do
    exec_path="$(awk -F= '$1=="Exec"{print $2; exit}' "$entry" | sed 's/^"//; s/" .*$//; s/ .*$//')"
    if [[ -n "$exec_path" && ! -e "$exec_path" ]]; then
      backup="${entry}.broken.$(date +%Y%m%d-%H%M%S)"
      log "  Movendo atalho quebrado do Burp: ${entry} -> ${backup}"
      mv -- "$entry" "$backup" || return 1
    fi
  done
}

