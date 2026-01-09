#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "./slurm/common.sh"

fix_unicode_dashes_here
ensure_env

log "ROOT_DIR=${ROOT_DIR}"
log "CASE_DIR=${CASE_DIR}"
log "OUT_DIR=${OUT_DIR}"
log "BIN=${BIN}"
log "IMAGE=${IMAGE}"
log "PARTITION=${PARTITION}"

RUN_LOG_DIR="${OUT_DIR}/slurm_logs"
mkdir -p "${RUN_LOG_DIR}"

export IMAGE BIN CASE_DIR OUT_DIR BACKEND MAX_ITERS REL_TOL ABS_TOL APPTAINER_GPU
export X_REF CMP_REL_TOL CMP_ABS_TOL TOP_K

PCG="./slurm/templates/run_pcg_case.sbatch"
CMP="./slurm/templates/compare_x.sbatch"

require_file "${PCG}"
require_file "${CMP}"

JOB1="$(sbatch --parsable --partition="${PARTITION}" \
  --time="${SBATCH_TIME}" --mem="${SBATCH_MEM}" --cpus-per-task="${SBATCH_CPUS}" \
  --chdir="${ROOT_DIR}" \
  --output="${RUN_LOG_DIR}/pcg-%j.out" \
  --error="${RUN_LOG_DIR}/pcg-%j.err" \
  "${PCG}")"
log "PCG job: ${JOB1}"

JOB2="$(sbatch --parsable --dependency=afterok:${JOB1} --partition="${PARTITION}" \
  --time="00:05:00" --mem="512M" --cpus-per-task="1" \
  --chdir="${ROOT_DIR}" \
  --output="${RUN_LOG_DIR}/cmp-%j.out" \
  --error="${RUN_LOG_DIR}/cmp-%j.err" \
  "${CMP}")"
log "COMPARE job: ${JOB2} (afterok:${JOB1})"

log "Track: squeue"
log "Accounting: sacct -X -j ${JOB1},${JOB2} --format=JobIDRaw,User,Account,State,Elapsed,AllocTRES%40"
