#!/bin/bash
#SBATCH --job-name=wgpu_cmp
#SBATCH --output=slurm_logs/slurm-cmp-%j.out
#SBATCH --error=slurm_logs/slurm-cmp-%j.err
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#SBATCH --chdir=.

set -euo pipefail
ROOT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "${ROOT_DIR}"

: "${IMAGE:?missing IMAGE}"
: "${BIN:?missing BIN}"
: "${X_REF:?missing X_REF}"
: "${OUT_DIR:?missing OUT_DIR}"
: "${CMP_REL_TOL:=1e-5}"
: "${CMP_ABS_TOL:=1e-3}"
: "${TOP_K:=10}"
: "${APPTAINER_GPU:=}"

X="${OUT_DIR}/x.bin"

apptainer exec ${APPTAINER_GPU} --bind "${ROOT_DIR}:${ROOT_DIR}" "${IMAGE}" bash -lc "
  set -euo pipefail
  cd '${ROOT_DIR}'
  '${BIN}' compare-x \
    --x-ref '${X_REF}' \
    --x '${X}' \
    --rel-tol '${CMP_REL_TOL}' \
    --abs-tol '${CMP_ABS_TOL}' \
    --top-k '${TOP_K}'
"
