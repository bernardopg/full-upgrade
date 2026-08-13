#!/usr/bin/env bash
# install-shellcheck.sh — instala uma versão FIXA do shellcheck.
#
# Por que não usar o do apt/da imagem do runner: o ubuntu-24.04 traz a versão
# 0.9.0, enquanto o Arch (ambiente de desenvolvimento deste projeto) já está na
# 0.11.0. As duas discordam — 0.10 e 0.11 acrescentaram checagens e mudaram
# severidades —, então código aprovado localmente quebrava no CI (e vice-versa).
# Pinar aqui é o mesmo remédio que o scripts/install-bats.sh aplica ao bats: o
# portão do CI roda exatamente a versão do desenvolvimento.
# (Atenção: nenhuma linha de comentário pode começar com a palavra-chave de
# diretiva seguida de espaço — o próprio shellcheck tentaria interpretá-la.)
#
# Ao subir a versão, atualize também o README (seção de desenvolvimento) e rode
# `shellcheck -S warning -x` localmente antes de commitar.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${SHELLCHECK_VERSION:-0.11.0}"
DEST="${SHELLCHECK_INSTALL_DIR:-${ROOT}/.ci/shellcheck}"
WORK="${ROOT}/.ci/shellcheck-src"
ARCHIVE="${ROOT}/.ci/shellcheck-v${VERSION}.tar.xz"

case "$(uname -m)" in
  x86_64 | amd64) ARCH="x86_64" ;;
  aarch64 | arm64) ARCH="aarch64" ;;
  *)
    echo "install-shellcheck.sh: arquitetura não suportada: $(uname -m)" >&2
    exit 1
    ;;
esac

rm -rf "$DEST" "$WORK"
mkdir -p "${ROOT}/.ci" "$DEST/bin" "$WORK"

curl -fsSL \
  "https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/shellcheck-v${VERSION}.linux.${ARCH}.tar.xz" \
  -o "$ARCHIVE"
tar -xJf "$ARCHIVE" -C "$WORK" --strip-components=1
install -m 0755 "${WORK}/shellcheck" "${DEST}/bin/shellcheck"

"${DEST}/bin/shellcheck" --version
