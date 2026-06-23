#!/usr/bin/env bash
# install.sh — instala full-upgrade em ~/.local/share + symlink em ~/.local/bin.
# Uso: ./install.sh   (a partir do diretório do repo clonado)
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/full-upgrade"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/full-upgrade"

echo "full-upgrade — instalação"
echo "  origem : ${SRC_DIR}"
echo "  destino: ${DEST_DIR}"

# Copia via staging + troca atômica. Copiar por cima do destino deixaria
# libs órfãs: um arquivo removido/renomeado no projeto continuaria no destino
# e o entrypoint o carregaria via glob lib/*.sh (código morto conflitante).
# A instalação anterior fica em ${DEST_DIR}.prev para rollback rápido.
STAGE_DIR="${DEST_DIR}.new"
PREV_DIR="${DEST_DIR}.prev"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "${SRC_DIR}/full-upgrade.sh" "${SRC_DIR}/lib" "$STAGE_DIR/"
[[ -d "${SRC_DIR}/steps.d" ]] && cp -a "${SRC_DIR}/steps.d" "$STAGE_DIR/"
cp -f "${SRC_DIR}/config.example" "$STAGE_DIR/" 2>/dev/null || true
chmod +x "${STAGE_DIR}/full-upgrade.sh"

# Grava a versão instalada: a instalação não leva o .git, então sem este arquivo
# o entrypoint cairia no fallback embutido. Prioridade: git describe (só se o
# repo for ESTE projeto) > VERSION do repo. A checagem de toplevel evita pegar a
# versão de um repo git pai quando se instala de um tarball extraído.
_inst_ver=""
_git_top="$(git -C "$SRC_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$_git_top" && -f "${_git_top}/full-upgrade.sh" && -f "${_git_top}/install.sh" ]]; then
  _inst_ver="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || true)"
fi
if [[ -z "$_inst_ver" && -r "${SRC_DIR}/VERSION" ]]; then
  _inst_ver="$(tr -d '[:space:]' < "${SRC_DIR}/VERSION")"
fi
if [[ -n "$_inst_ver" ]]; then
  printf '%s\n' "${_inst_ver#v}" > "${STAGE_DIR}/VERSION"
  echo "  versão : ${_inst_ver#v}"
fi

# Aviso de downgrade (comparação semântica via sort -V).
_old_ver="$(cat "${DEST_DIR}/VERSION" 2>/dev/null || true)"
_new_ver="${_inst_ver#v}"
if [[ -n "$_old_ver" && -n "$_new_ver" && "$_old_ver" != "$_new_ver" ]]; then
  _newest="$(printf '%s\n%s\n' "$_old_ver" "$_new_ver" | sort -V | tail -1)"
  if [[ "$_newest" == "$_old_ver" ]]; then
    echo "  AVISO  : instalando ${_new_ver} por cima de ${_old_ver} (downgrade)."
  fi
fi

# Troca: janela sem DEST_DIR é mínima (dois mv no mesmo filesystem).
rm -rf "$PREV_DIR"
if [[ -d "$DEST_DIR" ]]; then
  mv "$DEST_DIR" "$PREV_DIR"
  echo "  backup : ${PREV_DIR} (instalação anterior; rollback: mv de volta)"
fi
mv "$STAGE_DIR" "$DEST_DIR"

# Symlink no PATH.
mkdir -p "$BIN_DIR"
ln -sf "${DEST_DIR}/full-upgrade.sh" "${BIN_DIR}/full-upgrade"
echo "  symlink: ${BIN_DIR}/full-upgrade -> ${DEST_DIR}/full-upgrade.sh"

# Config inicial (nunca sobrescreve o existente).
mkdir -p "$CONFIG_DIR"
if [[ ! -f "${CONFIG_DIR}/config" ]]; then
  cp -f "${SRC_DIR}/config.example" "${CONFIG_DIR}/config"
  echo "  config : ${CONFIG_DIR}/config (criado a partir do exemplo)"
else
  echo "  config : ${CONFIG_DIR}/config (preservado; veja config.example p/ novas chaves)"
fi

# ── Ícones do systray + desktop entry + unit systemd (opcional, p/ --tray) ──────
# Ícones também ficam em ${DEST_DIR}/icons (resolução preferencial do tray) e no
# tema hicolor (p/ launcher e Icon=full-upgrade).
if [[ -d "${SRC_DIR}/assets/icons" ]]; then
  mkdir -p "${DEST_DIR}/icons"
  cp -f "${SRC_DIR}/assets/icons/"*.svg "${DEST_DIR}/icons/" 2>/dev/null || true

  HICOLOR_SCALABLE="${HOME}/.local/share/icons/hicolor/scalable/apps"
  mkdir -p "$HICOLOR_SCALABLE"
  cp -f "${SRC_DIR}/assets/icons/"*.svg "$HICOLOR_SCALABLE/" 2>/dev/null || true
  # Atualiza o cache de ícones se gtk-update-icon-cache existir.
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -t "${HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  echo "  ícones : ${DEST_DIR}/icons + ${HICOLOR_SCALABLE}"
fi

# Desktop entry no menu de aplicativos (lança o systray applet).
if [[ -f "${SRC_DIR}/res/full-upgrade-tray.desktop" ]]; then
  APPS_DIR="${HOME}/.local/share/applications"
  mkdir -p "$APPS_DIR"
  cp -f "${SRC_DIR}/res/full-upgrade-tray.desktop" "$APPS_DIR/full-upgrade-tray.desktop" 2>/dev/null || true
  (command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1) || true
  echo "  desktop: ${APPS_DIR}/full-upgrade-tray.desktop"
fi

# Unit systemd --user (alternativa de autostart via 'systemctl --user enable').
if [[ -f "${SRC_DIR}/res/full-upgrade-tray.service" ]]; then
  SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
  mkdir -p "$SYSTEMD_USER_DIR"
  cp -f "${SRC_DIR}/res/full-upgrade-tray.service" "${SYSTEMD_USER_DIR}/full-upgrade-tray.service" 2>/dev/null || true
  echo "  systemd: ${SYSTEMD_USER_DIR}/full-upgrade-tray.service (enable: systemctl --user enable --now full-upgrade-tray.service)"
fi

echo ""
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  echo "AVISO: ${BIN_DIR} não está no PATH. Adicione ao seu shell rc:"
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi
echo "Pronto. Rode:  full-upgrade --help"
