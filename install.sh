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

# Grava a versão instalada: a instalação não leva o .git, então sem este arquivo
# o entrypoint cairia no fallback embutido. Prioridade: git describe > VERSION do repo.
_inst_ver="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || true)"
if [[ -z "$_inst_ver" && -r "${SRC_DIR}/VERSION" ]]; then
  _inst_ver="$(tr -d '[:space:]' < "${SRC_DIR}/VERSION")"
fi
if [[ -n "$_inst_ver" ]]; then
  printf '%s\n' "${_inst_ver#v}" > "${DEST_DIR}/VERSION"
  echo "  versão : ${_inst_ver#v}"
fi

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
