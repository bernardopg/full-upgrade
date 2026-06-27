#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${BATS_VERSION:-1.13.0}"
DEST="${BATS_INSTALL_DIR:-${ROOT}/.ci/bats}"
WORK="${ROOT}/.ci/bats-src"
ARCHIVE="${ROOT}/.ci/bats-v${VERSION}.tar.gz"

rm -rf "$DEST" "$WORK"
mkdir -p "${ROOT}/.ci"

curl -fsSL \
  "https://github.com/bats-core/bats-core/archive/refs/tags/v${VERSION}.tar.gz" \
  -o "$ARCHIVE"
mkdir -p "$WORK"
tar -xzf "$ARCHIVE" -C "$WORK" --strip-components=1
"$WORK/install.sh" "$DEST"
"$DEST/bin/bats" --version
