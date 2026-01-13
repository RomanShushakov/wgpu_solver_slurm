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
  (command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary) || true
    '${BIN}' compare-x \
      --x-ref '${X_REF}' \
      --x '${X}' \
      --rel-tol '${CMP_REL_TOL}' \
      --abs-tol '${CMP_ABS_TOL}' \
      --top-k '${TOP_K}'
  "
