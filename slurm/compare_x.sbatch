#!/bin/bash
#SBATCH --job-name=wgpu_cmp
#SBATCH --output=slurm_logs/slurm-cmp-%j.out
#SBATCH --error=slurm_logs/slurm-cmp-%j.err
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
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
: "${APPTAINER_GPU:=}"

# Auto-enable NVIDIA passthrough for GPU jobs unless user overrides
if [[ -z "${APPTAINER_GPU}" && -n "${SLURM_JOB_GPUS:-}" ]]; then
  APPTAINER_GPU="--nv"
fi

# Prefer Vulkan backend in wgpu
export WGPU_BACKEND="${WGPU_BACKEND:-vulkan}"

# Only force VK_ICD_FILENAMES if the file exists (and will be visible via binds above)
if [[ -z "${VK_ICD_FILENAMES:-}" ]]; then
  if [[ -f /etc/vulkan/icd.d/nvidia_icd.json ]]; then
    export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
  elif [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]]; then
    export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
  fi
fi


X="${OUT_DIR}/x.bin"

source "$ROOT_DIR/slurm/lib/apptainer_gpu_env.sh"
GPU_BINDS=( $(build_gpu_binds) )

apptainer exec --nv \
  "${GPU_BINDS[@]}" \
  --bind "$ROOT_DIR:$ROOT_DIR" \
  "$IMAGE" bash -c "
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
