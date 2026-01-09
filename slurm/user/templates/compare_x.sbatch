#!/bin/bash
#SBATCH --job-name=wgpu_cmp
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
LOG_DIR="${OUT_DIR}/slurm_logs"
mkdir -p "${LOG_DIR}"

exec >"${LOG_DIR}/cmp-${SLURM_JOB_ID}.out" 2>"${LOG_DIR}/cmp-${SLURM_JOB_ID}.err"

DRI_BIND=""
if [[ -d /dev/dri ]]; then
  DRI_BIND="--bind /dev/dri:/dev/dri"
fi

apptainer exec ${APPTAINER_GPU} \
  --bind "${ROOT_DIR}:${ROOT_DIR}" \
  ${DRI_BIND} \
  "${IMAGE}" bash -lc "
    set -euo pipefail
    cd '${ROOT_DIR}'
    '${BIN}' compare-x \
      --x-ref '${X_REF}' \
      --x '${X}' \
      --rel-tol '${CMP_REL_TOL}' \
      --abs-tol '${CMP_ABS_TOL}' \
      --top-k '${TOP_K}'
  "
