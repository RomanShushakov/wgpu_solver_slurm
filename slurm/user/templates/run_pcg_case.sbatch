#!/bin/bash
#SBATCH --job-name=wgpu_pcg
#SBATCH --chdir=.

set -euo pipefail

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not in PATH"; exit 127; }

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

GPU_LOG_DIR="/var/log/slurm/gpu-metrics"
mkdir -p "${GPU_LOG_DIR}" 2>/dev/null || true

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=timestamp,index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total \
    --format=csv,noheader,nounits \
    | sed "s/^/${SLURM_JOB_ID},START,/" \
    >> "${GPU_LOG_DIR}/gpu-${SLURM_JOB_ID}.csv" || true
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

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=timestamp,index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total \
    --format=csv,noheader,nounits \
    | sed "s/^/${SLURM_JOB_ID},END,/" \
    >> "${GPU_LOG_DIR}/gpu-${SLURM_JOB_ID}.csv" || true
fi
