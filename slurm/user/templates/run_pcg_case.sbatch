#!/bin/bash
#SBATCH --job-name=wgpu_pcg
#SBATCH --chdir=.

set -euo pipefail

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not in PATH"; exit 127; }
command -v gpu_wrap   >/dev/null 2>&1 || { echo "ERROR: gpu_wrap not in PATH (run scripts/13_install_gpu_wrap.sh)"; exit 127; }

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

OUT_X="${OUT_DIR}/x.bin"
OUT_METRICS="${OUT_DIR}/metrics.json"
LOG_DIR="${OUT_DIR}/slurm_logs"
mkdir -p "${OUT_DIR}" "${LOG_DIR}"

# Redirect logs next to run outputs
exec >"${LOG_DIR}/pcg-${SLURM_JOB_ID}.out" 2>"${LOG_DIR}/pcg-${SLURM_JOB_ID}.err"

# Optional bind /dev/dri (safe no-op on systems without it)
DRI_BIND=()
[[ -d /dev/dri ]] && DRI_BIND+=(--bind /dev/dri:/dev/dri)

# Auto-enable NVIDIA passthrough when Slurm allocated GPUs (or when SLURM_JOB_GPUS is set)
APPTAINER_GPU=""
if [[ -n "${SLURM_JOB_GPUS:-}" || -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
  APPTAINER_GPU="--nv"
fi

# --- Apptainer GPU env + binds (critical) ---
source "${ROOT_DIR}/slurm/lib/apptainer_gpu_env.sh"
GPU_BINDS=( $(build_gpu_binds) )

# IMPORTANT: gpu_wrap must wrap the whole apptainer exec to write start/end CSV snapshots
gpu_wrap apptainer exec ${APPTAINER_GPU} \
  "${GPU_BINDS[@]}" \
  "${DRI_BIND[@]}" \
  --bind "${ROOT_DIR}:${ROOT_DIR}" \
  "${IMAGE}" bash -lc "
    set -euo pipefail
    $(print_gpu_env_exports)
    cd '${ROOT_DIR}'
    (command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary) || true

    '${BIN}' --backend '${BACKEND}' run-pcg-case \
      --case-dir '${CASE_DIR}' \
      --max-iters '${MAX_ITERS}' \
      --rel-tol '${REL_TOL}' \
      --abs-tol '${ABS_TOL}' \
      --out-x '${OUT_X}' \
      --out-metrics '${OUT_METRICS}'
  "
