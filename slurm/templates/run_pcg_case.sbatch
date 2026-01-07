#!/bin/bash
#SBATCH --job-name=wgpu_pcg
#SBATCH --chdir=.

set -euo pipefail

ROOT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "${ROOT_DIR}"

: "${IMAGE:?missing IMAGE}"
: "${BIN:?missing BIN}"
: "${CASE_DIR:?missing CASE_DIR}"
: "${OUT_DIR:?missing OUT_DIR}"
: "${BACKEND:=auto}"
: "${MAX_ITERS:=2000}"
: "${REL_TOL:=1e-4}"
: "${ABS_TOL:=1e-7}"
: "${APPTAINER_GPU:=}"

OUT_X="${OUT_DIR}/x.bin"
OUT_METRICS="${OUT_DIR}/metrics.json"
LOG_DIR="${OUT_DIR}/slurm_logs"
mkdir -p "${OUT_DIR}" "${LOG_DIR}"

# Send job logs next to the run outputs
#SBATCH --output=slurm-pcg-%j.out
#SBATCH --error=slurm-pcg-%j.err
# Note: SBATCH directives cannot use shell vars, so we redirect in shell:
exec >"${LOG_DIR}/pcg-${SLURM_JOB_ID}.out" 2>"${LOG_DIR}/pcg-${SLURM_JOB_ID}.err"

# Bind /dev/dri only if it exists (WSL-safe)
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
    '${BIN}' run-pcg-case \
      --case-dir '${CASE_DIR}' \
      --max-iters '${MAX_ITERS}' \
      --rel-tol '${REL_TOL}' \
      --abs-tol '${ABS_TOL}' \
      --out-x '${OUT_X}' \
      --out-metrics '${OUT_METRICS}'
  "
