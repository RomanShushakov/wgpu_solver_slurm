#!/bin/bash
#SBATCH --job-name=wgpu_info
#SBATCH --partition=local
#SBATCH --output=slurm-info-%j.out
#SBATCH --error=slurm-info-%j.err
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#SBATCH --chdir=.

set -euo pipefail

ROOT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "${ROOT_DIR}"

IMAGE="${IMAGE:-${ROOT_DIR}/apptainer/solver-runtime.sif}"
BIN="${BIN:-${ROOT_DIR}/solvers/wgpu_solver_backend_cli}"

echo "ROOT_DIR=${ROOT_DIR}"
echo "BIN=${BIN}"
ls -lah "${ROOT_DIR}/solvers" || true

if [[ ! -x "${BIN}" ]]; then
  echo "ERROR: binary not found or not executable: ${BIN}"
  exit 2
fi

APPTAINER_GPU="${APPTAINER_GPU:-}"

apptainer exec ${APPTAINER_GPU} \
  --bind "${ROOT_DIR}:${ROOT_DIR}" \
  "${IMAGE}" \
  bash -lc "
    set -euo pipefail
    cd '${ROOT_DIR}'
    '${BIN}' --backend auto info
  "
