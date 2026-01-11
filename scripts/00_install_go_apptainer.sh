#!/usr/bin/env bash
set -euo pipefail

# Installs a recent Go from apt (Debian) and builds Apptainer from source on arm64 (Pi).
# It also removes /usr/local/go if present (common cause of "Go too old" being detected).

APPTAINER_VERSION="${APPTAINER_VERSION:-1.4.5}"
PREFIX="${PREFIX:-/usr/local}"

# Where to build
WORKDIR="${WORKDIR:-/tmp}"
SRC_DIR="${SRC_DIR:-${WORKDIR}/apptainer}"

echo "=== Pi: Install Go + build Apptainer ==="
echo "APPTAINER_VERSION=${APPTAINER_VERSION}"
echo "PREFIX=${PREFIX}"
echo "SRC_DIR=${SRC_DIR}"
echo "======================================="

echo "[1/6] Remove old manual Go (/usr/local/go) if exists..."
if [[ -d /usr/local/go ]]; then
  echo "Found /usr/local/go -> removing to avoid old Go shadowing apt Go."
  sudo rm -rf /usr/local/go
fi

echo "[2/6] Install build dependencies + Go (apt)..."
sudo apt-get update
sudo apt-get install -y \
  git wget ca-certificates \
  build-essential pkg-config \
  golang-go \
  libseccomp-dev libssl-dev libgpgme-dev \
  squashfs-tools uidmap \
  cryptsetup \
  runc \
  jq

echo "[3/6] Verify Go..."
export PATH=/usr/bin:$PATH
hash -r || true
which go
go version

echo "[4/6] Fetch Apptainer source..."
rm -rf "${SRC_DIR}"
git clone --depth 1 --branch "v${APPTAINER_VERSION}" https://github.com/apptainer/apptainer.git "${SRC_DIR}"

echo "[5/6] Build Apptainer..."
cd "${SRC_DIR}"
rm -rf builddir || true

# Ensure we do not accidentally use any other Go in PATH
export PATH=/usr/bin:$PATH
export GOTOOLCHAIN=local

./mconfig --prefix="${PREFIX}"
make -C builddir

echo "[6/6] Install Apptainer..."
sudo make -C builddir install

echo
echo "OK: Installed:"
command -v apptainer
apptainer version
