#!/usr/bin/env bash
# Compila e instala o kcov a partir do fonte. Os releases oficiais não
# disponibilizam binário pré-compilado, e o kcov não está no apt do
# ubuntu-24.04 (apenas no universe do 22.04). Espelha scripts/install-bats.sh:
# versão pinada, instala sob .ci/ (gitignored).
#
# Pin em commit do master, não na tag v43 (2024): com o bash 5.3 (Ubuntu
# 26.04, Arch) o motor de bash da v43 perde os traces e a cobertura caiu de
# 52% para 27% no Codecov (lib/testable/*.sh foram de 100% para 0%). O master
# traz as correções do bash-engine (#510, #517, #518). KCOV_VERSION aceita
# tag ou SHA. O patch abaixo é feito contra esse commit.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${KCOV_VERSION:-bbaa197381a34080a0aa0de09de32f9c57c4cbc7}"
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
    "https://github.com/SimonKagstrom/kcov/archive/${VERSION}.tar.gz" \
    -o "$ARCHIVE"
mkdir -p "$WORK"
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1

# O motor de bash do kcov alterna um estado "dentro de aspa simples" a cada '
# ímpar numa linha de trace, para pular valores multilinha. Só que `[[ ]]`,
# `for`, `case` e `arr+=()` saem no xtrace sem escape ("[[ it's == a ]]"): um
# apóstrofo num valor deixava o kcov ignorando TODO o trace seguinte, de todos
# os processos, e a cobertura variava com a ordem dos testes. O patch remove
# esse estado (linha sem o marcador kcov@ já é ignorada) e trata texto que só
# cita o PS4 como linha comum, não como erro.
echo ":: Aplicando scripts/kcov-bash-quote-state.patch..."
patch -d "$WORK" -p1 < "${ROOT}/scripts/kcov-bash-quote-state.patch"

echo ":: Compilando kcov ${VERSION}..."
BUILD="${WORK}/build"
cmake -S "$WORK" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEST"
cmake --build "$BUILD" --parallel "$(nproc)"
cmake --install "$BUILD"

echo ":: kcov instalado em ${DEST}"
"${DEST}/bin/kcov" --version
