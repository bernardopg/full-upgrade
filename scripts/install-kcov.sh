#!/usr/bin/env bash
# Compila e instala o kcov a partir do fonte. Os releases oficiais não
# disponibilizam binário pré-compilado, e o kcov não está no apt do
# ubuntu-24.04 (apenas no universe do 22.04). Espelha scripts/install-bats.sh:
# versão pinada, instala sob .ci/ (gitignored).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${KCOV_VERSION:-v43}"
DEST="${KCOV_INSTALL_DIR:-${ROOT}/.ci/kcov}"
WORK="${ROOT}/.ci/kcov-src"
ARCHIVE="${ROOT}/.ci/kcov-${VERSION}.tar.gz"

# Já instalado (cache manual / re-runs)? Reaproveita.
if [ -x "${DEST}/bin/kcov" ]; then
    echo "kcov já instalado em ${DEST}"
    "${DEST}/bin/kcov" --version
    exit 0
fi

# Dependências de build (Ubuntu/Debian). Idempotente.
# Fonte: https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md
if command -v apt-get >/dev/null 2>&1; then
    echo ":: Instalando dependências de build do kcov..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        build-essential cmake \
        binutils-dev libcurl4-openssl-dev libelf-dev libdw-dev \
        libiberty-dev zlib1g-dev libssl-dev
fi

rm -rf "$WORK" "$ARCHIVE"
mkdir -p "${ROOT}/.ci"

echo ":: Baixando kcov ${VERSION}..."
curl -fsSL \
    "https://github.com/SimonKagstrom/kcov/archive/refs/tags/${VERSION}.tar.gz" \
    -o "$ARCHIVE"
mkdir -p "$WORK"
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1

echo ":: Compilando kcov ${VERSION}..."
BUILD="${WORK}/build"
cmake -S "$WORK" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEST"
cmake --build "$BUILD" --parallel "$(nproc)"
cmake --install "$BUILD"

echo ":: kcov instalado em ${DEST}"
"${DEST}/bin/kcov" --version
