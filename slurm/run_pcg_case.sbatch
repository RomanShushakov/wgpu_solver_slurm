#!/bin/bash
#SBATCH --job-name=wgpu_pcg
#SBATCH --output=slurm_logs/slurm-pcg-%j.out
#SBATCH --error=slurm_logs/slurm-pcg-%j.err
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
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

# Auto-enable NVIDIA passthrough for GPU jobs unless user overrides
if [[ -z "${APPTAINER_GPU}" && -n "${SLURM_JOB_GPUS:-}" ]]; then
  APPTAINER_GPU="--nv"
fi

# Bind host Vulkan + GLVND config into the container (required for NVIDIA Vulkan ICD discovery)
VULKAN_BINDS=()
[[ -d /etc/vulkan ]] && VULKAN_BINDS+=(--bind /etc/vulkan:/etc/vulkan)
[[ -d /usr/share/vulkan ]] && VULKAN_BINDS+=(--bind /usr/share/vulkan:/usr/share/vulkan)
[[ -d /usr/share/glvnd ]] && VULKAN_BINDS+=(--bind /usr/share/glvnd:/usr/share/glvnd)
[[ -d /etc/glvnd ]] && VULKAN_BINDS+=(--bind /etc/glvnd:/etc/glvnd)

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


OUT_X="${OUT_DIR}/x.bin"
OUT_METRICS="${OUT_DIR}/metrics.json"
mkdir -p "${OUT_DIR}"

GPU_LOG_DIR="/var/log/slurm/gpu-metrics"
mkdir -p "${GPU_LOG_DIR}" 2>/dev/null || true

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=timestamp,index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total \
    --format=csv,noheader,nounits \
    | sed "s/^/${SLURM_JOB_ID},START,/" \
    >> "${GPU_LOG_DIR}/gpu-${SLURM_JOB_ID}.csv" || true
fi

apptainer exec ${APPTAINER_GPU} "${VULKAN_BINDS[@]}" --bind "${ROOT_DIR}:${ROOT_DIR}" "${IMAGE}" bash -lc "
  set -euo pipefail
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

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=timestamp,index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total \
    --format=csv,noheader,nounits \
    | sed "s/^/${SLURM_JOB_ID},END,/" \
    >> "${GPU_LOG_DIR}/gpu-${SLURM_JOB_ID}.csv" || true
fi
