#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNS_ROOT="${RUNS_ROOT:-${ROOT_DIR}/experiments/runs}"
EXPERIMENT="${EXPERIMENT:-local_smoke}"

# Required from caller: CASE_DIR
if [[ -z "${CASE_DIR:-}" ]]; then
  echo "ERROR: CASE_DIR is not set"
  exit 2
fi

CASE_DIR_ABS="$(cd "${CASE_DIR}" && pwd)"
CASE_NAME="$(basename "${CASE_DIR_ABS}")"

JOB_ID="${SLURM_JOB_ID:-manual}"
HOST="$(hostname -s)"

RUN_DIR="${RUNS_ROOT}/${EXPERIMENT}/${CASE_NAME}/job_${JOB_ID}_${HOST}"
mkdir -p "${RUN_DIR}"

# Capture stable metadata (expand later if you want)
cat > "${RUN_DIR}/env.json" <<EOF
{
  "experiment": "${EXPERIMENT}",
  "case_name": "${CASE_NAME}",
  "case_dir": "${CASE_DIR_ABS}",
  "run_dir": "${RUN_DIR}",
  "host": "${HOST}",
  "slurm": {
    "job_id": "${SLURM_JOB_ID:-}",
    "array_job_id": "${SLURM_ARRAY_JOB_ID:-}",
    "array_task_id": "${SLURM_ARRAY_TASK_ID:-}"
  },
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo "${RUN_DIR}"
