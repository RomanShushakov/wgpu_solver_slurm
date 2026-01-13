#!/bin/bash
#SBATCH --job-name=wgpu_cmp
#SBATCH --chdir=.

set -euo pipefail

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not in PATH"; exit 127; }

ROOT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "${ROOT_DIR}"

: "${IMAGE:?missing IMAGE}"
: "${BIN:?missing BIN}"
: "${X_REF:?missing X_REF}"
: "${OUT_DIR:?missing OUT_DIR}"
: "${CMP_REL_TOL:=1e-5}"
: "${CMP_ABS_TOL:=1e-3}"
: "${TOP_K:=10}"

X="${OUT_DIR}/x.bin"
LOG_DIR="${OUT_DIR}/slurm_logs"
mkdir -p "${LOG_DIR}"

exec >"${LOG_DIR}/cmp-${SLURM_JOB_ID}.out" 2>"${LOG_DIR}/cmp-${SLURM_JOB_ID}.err"

# Optional bind /dev/dri
DRI_BIND=()
[[ -d /dev/dri ]] && DRI_BIND+=(--bind /dev/dri:/dev/dri)

# --- Apptainer GPU env + binds (critical) ---
source "${ROOT_DIR}/slurm/lib/apptainer_gpu_env.sh"
GPU_BINDS=( $(build_gpu_binds) )

apptainer exec --nv \
  "${GPU_BINDS[@]}" \
  "${DRI_BIND[@]}" \
  --bind "${ROOT_DIR}:${ROOT_DIR}" \
  "${IMAGE}" bash -c "
    set -euo pipefail
    $(print_gpu_env_exports)
    cd '${ROOT_DIR}'
    (command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary) || true

    '${BIN}' compare-x \
      --x-ref '${X_REF}' \
      --x '${X}' \
      --rel-tol '${CMP_REL_TOL}' \
      --abs-tol '${CMP_ABS_TOL}' \
      --top-k '${TOP_K}'
  "
