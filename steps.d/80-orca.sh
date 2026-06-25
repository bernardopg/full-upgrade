#!/usr/bin/env bash
# steps.d/orca — integra Orca IDE (Stably AI). Roda por presença; instalação
# nova só acontece com ENABLE_CUSTOM_TOOLS=1.
# shellcheck shell=bash
# shellcheck disable=SC2034

ORCA_IDE_PACKAGE="stably-orca-bin"
ORCA_IDE_DESKTOP_ID="stably-orca.desktop"
ORCA_IDE_ICON_NAME="stably-orca"
ORCA_IDE_ICON_URL="https://raw.githubusercontent.com/stablyai/orca/main/resources/icon.png"

orca_ide_bin() {
  local candidate
  for candidate in \
    "${ORCA_IDE_BIN:-}" \
    "$(command -v stably-orca 2>/dev/null || true)" \
    "${HOME}/.local/bin/stably-orca"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

orca_ide_installed() {
  orca_ide_bin >/dev/null 2>&1 && return 0
  pacman -Q "$ORCA_IDE_PACKAGE" >/dev/null 2>&1 && return 0
  [[ -x "${HOME}/.local/share/orca-ide/stably-orca" ]] && return 0
}

orca_ide_release_appimage_url() {
  local arch="${1:-$(uname -m)}"
  case "$arch" in
    x86_64|amd64) printf '%s\n' "https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage" ;;
    aarch64|arm64) printf '%s\n' "https://github.com/stablyai/orca/releases/latest/download/orca-linux-arm64.AppImage" ;;
    *) return 1 ;;
  esac
}

orca_ide_release_appimage_name() {
  local arch="${1:-$(uname -m)}"
  case "$arch" in
    x86_64|amd64) printf '%s\n' "orca-linux.AppImage" ;;
    aarch64|arm64) printf '%s\n' "orca-linux-arm64.AppImage" ;;
    *) return 1 ;;
  esac
}

orca_ide_release_appimage_sha256() {
  local asset
  asset="$(orca_ide_release_appimage_name "${1:-$(uname -m)}")" || return 1
  has python || return 1
  python - "$asset" <<'PY'
import json
import sys
import urllib.request

asset_name = sys.argv[1]
with urllib.request.urlopen(
    "https://api.github.com/repos/stablyai/orca/releases/latest", timeout=30
) as response:
    release = json.load(response)
for asset in release.get("assets", []):
    if asset.get("name") == asset_name:
        digest = asset.get("digest", "")
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1])
            raise SystemExit(0)
raise SystemExit(1)
PY
}

install_orca_ide_aur() {
  local helper="${AUR_HELPER:-}"
  if [[ -z "$helper" ]] || ! has "$helper"; then
    log " Nenhum helper AUR disponível para instalar ${ORCA_IDE_PACKAGE}."
    return 1
  fi

  log " Instalando/garantindo Orca IDE via AUR (${ORCA_IDE_PACKAGE})..."
  run_logged "$helper" -S --needed --noconfirm "$ORCA_IDE_PACKAGE"
}

install_orca_ide_appimage() {
  if ! has curl; then
    log " curl ausente; não é possível baixar o AppImage do Orca IDE."
    return 1
  fi

  local url target_dir target tmp sha256
  url="$(orca_ide_release_appimage_url "$(uname -m)")" || {
    log " Arquitetura sem AppImage conhecido para Orca IDE: $(uname -m)"
    return 1
  }
  target_dir="${HOME}/.local/share/orca-ide"
  target="${target_dir}/stably-orca"
  tmp="$(mktemp "${TMPDIR:-/tmp}/orca-ide.XXXXXX")" || return 1

  log " Baixando Orca IDE AppImage..."
  if ! run_network_cmd curl -fL "$url" -o "$tmp" >/dev/null; then
    rm -f "$tmp"
    log " Falha ao baixar AppImage do Orca IDE."
    return "$RC_WARN"
  fi
  sha256="$(orca_ide_release_appimage_sha256 "$(uname -m)" 2>>"$LOG_FILE")" || {
    rm -f "$tmp"
    log " Não foi possível obter checksum SHA-256 do release do Orca IDE; abortando fallback AppImage."
    return 1
  }
  if ! printf '%s  %s\n' "$sha256" "$tmp" | sha256sum -c - >>"$LOG_FILE" 2>&1; then
    rm -f "$tmp"
    log " Checksum do AppImage do Orca IDE não confere; abortando."
    return 1
  fi

  mkdir -p "$target_dir" "${HOME}/.local/bin"
  chmod +x "$tmp"
  mv -f "$tmp" "$target"
  ln -sfn "$target" "${HOME}/.local/bin/stably-orca"
  ORCA_IDE_BIN="$target"
  log " Orca IDE instalado em ${target}."
}

orca_ide_icon_source() {
  local icon
  for icon in \
    "${HOME}/.local/share/icons/hicolor/512x512/apps/${ORCA_IDE_ICON_NAME}.png" \
    /usr/share/icons/hicolor/*/apps/stably-orca.png \
    /usr/share/icons/hicolor/*/apps/orca.png \
    /opt/stably-orca/usr/share/icons/hicolor/*/apps/stably-orca.png \
    /opt/stably-orca/usr/share/icons/hicolor/*/apps/orca.png \
    /opt/stably-orca/stably-orca.png \
    /opt/stably-orca/orca.png \
    /opt/stably-orca/.DirIcon; do
    [[ -f "$icon" ]] || continue
    printf '%s\n' "$icon"
    return 0
  done
  return 1
}

ensure_orca_ide_icon() {
  local icon_dir icon_target icon_source
  icon_dir="${HOME}/.local/share/icons/hicolor/512x512/apps"
  icon_target="${icon_dir}/${ORCA_IDE_ICON_NAME}.png"

  mkdir -p "$icon_dir"
  icon_source="$(orca_ide_icon_source || true)"
  if [[ -n "$icon_source" && "$icon_source" != "$icon_target" ]]; then
    cp -f -- "$icon_source" "$icon_target"
  elif [[ ! -f "$icon_target" ]]; then
    if ! has curl; then
      log " Ícone do Orca não encontrado e curl ausente para baixar fallback."
      return "$RC_WARN"
    fi
    if ! run_network_cmd curl -fsSL "$ORCA_IDE_ICON_URL" -o "$icon_target" >/dev/null; then
      log " Falha ao baixar ícone fallback do Orca IDE."
      return "$RC_WARN"
    fi
  fi

  [[ -s "$icon_target" ]] || return 1
  printf '%s\n' "$icon_target"
}

write_orca_ide_desktop() {
  local exec_path="$1" icon_name="$2" desktop_dir desktop_file
  desktop_dir="${HOME}/.local/share/applications"
  desktop_file="${desktop_dir}/${ORCA_IDE_DESKTOP_ID}"
  mkdir -p "$desktop_dir"

  cat >"$desktop_file" <<EOF
[Desktop Entry]
Name=Orca
GenericName=Agentic Coding IDE
Comment=Electron-based agentic coding IDE by Stably AI
Exec=${exec_path} %U
Terminal=false
Type=Application
Icon=${icon_name}
Categories=Development;IDE;TextEditor;
StartupWMClass=Orca
MimeType=x-scheme-handler/stably-orca;
EOF

  if has desktop-file-validate; then
    desktop-file-validate "$desktop_file" >>"$LOG_FILE" 2>&1 || return 1
  fi

  printf '%s\n' "$desktop_file"
}

repair_orca_ide_desktop() {
  local exec_path icon_path desktop_file
  exec_path="$(orca_ide_bin || true)"
  [[ -n "$exec_path" ]] || exec_path="/usr/bin/stably-orca"

  icon_path="$(ensure_orca_ide_icon)" || return "$?"
  desktop_file="$(write_orca_ide_desktop "$exec_path" "$ORCA_IDE_ICON_NAME")" || return 1

  if has gtk-update-icon-cache; then
    gtk-update-icon-cache -q "${HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  fi
  if has update-desktop-database; then
    update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true
  fi

  log " Orca IDE desktop: ${desktop_file}"
  log " Orca IDE ícone: ${icon_path}"
}

ensure_orca_ide() {
  local status=0
  if ! orca_ide_installed; then
    if (( ${ENABLE_CUSTOM_TOOLS:-0} == 0 )); then
      STEP_REASON="orca não instalado; habilite ENABLE_CUSTOM_TOOLS=1 para instalar"
      log " Orca IDE não encontrado; instalação automática desligada."
      return "$RC_TODO"
    fi

    install_orca_ide_aur || install_orca_ide_appimage || status=$?
    if (( status != 0 )); then
      STEP_REASON="falha ao instalar Orca IDE"
      return "$status"
    fi
  else
    log " Orca IDE já instalado."
  fi

  repair_orca_ide_desktop || status=$?
  if (( status != 0 )); then
    STEP_REASON="falha ao reparar .desktop/ícone do Orca IDE"
    return "$status"
  fi
}
