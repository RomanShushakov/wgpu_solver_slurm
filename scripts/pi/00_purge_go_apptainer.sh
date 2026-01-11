#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
PURGE_APT_GO="${PURGE_APT_GO:-0}"   # set to 1 if you also want to remove apt Go

echo "=== Pi: Purge Apptainer + optional Go ==="
echo "PREFIX=${PREFIX}"
echo "PURGE_APT_GO=${PURGE_APT_GO}"
echo "========================================"

echo "[1/5] Remove Apptainer files under ${PREFIX}..."
# These are typical install locations for "make install" with --prefix=/usr/local
sudo rm -f  "${PREFIX}/bin/apptainer" "${PREFIX}/bin/run-singularity" || true
sudo rm -rf "${PREFIX}/libexec/apptainer" || true
sudo rm -rf "${PREFIX}/etc/apptainer" || true
sudo rm -rf "${PREFIX}/var/apptainer" || true
sudo rm -rf "${PREFIX}/share/apptainer" || true

echo "[2/5] Remove old manual Go (/usr/local/go) if exists..."
sudo rm -rf /usr/local/go || true

echo "[3/5] Optionally remove apt Go..."
if [[ "${PURGE_APT_GO}" == "1" ]]; then
  sudo apt-get remove -y golang-go || true
  sudo apt-get autoremove -y || true
fi

echo "[4/5] Refresh shell cache..."
hash -r || true

echo "[5/5] Status:"
if command -v apptainer >/dev/null 2>&1; then
  echo "WARN: apptainer still found at: $(command -v apptainer)"
  apptainer version || true
else
  echo "OK: apptainer not found."
fi

if command -v go >/dev/null 2>&1; then
  echo "Go: $(command -v go)"
  go version || true
else
  echo "Go: not found."
fi
