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

# Copia o projeto (lib/, steps.d/, entrypoint, config.example).
mkdir -p "$DEST_DIR"
cp -a "${SRC_DIR}/full-upgrade.sh" "${SRC_DIR}/lib" "$DEST_DIR/"
[[ -d "${SRC_DIR}/steps.d" ]] && cp -a "${SRC_DIR}/steps.d" "$DEST_DIR/"
cp -f "${SRC_DIR}/config.example" "$DEST_DIR/" 2>/dev/null || true
chmod +x "${DEST_DIR}/full-upgrade.sh"

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

echo ""
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  echo "AVISO: ${BIN_DIR} não está no PATH. Adicione ao seu shell rc:"
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi
echo "Pronto. Rode:  full-upgrade --help"
