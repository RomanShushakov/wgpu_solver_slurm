#!/usr/bin/env bash
set -euo pipefail

WRAP_PATH="${WRAP_PATH:-/usr/local/bin/gpu_wrap}"
LOG_DIR="${LOG_DIR:-/var/log/slurm/gpu-metrics}"

log() { echo -e "\n=== $* ==="; }

log "Step 13: Install gpu_wrap (Option A: nvidia-smi snapshots start/end)"
echo "WRAP_PATH=${WRAP_PATH}"
echo "LOG_DIR=${LOG_DIR}"

log "[1/3] Create log directory"
sudo mkdir -p "${LOG_DIR}"
sudo chmod 0755 "${LOG_DIR}"
sudo chown root:root "${LOG_DIR}"

log "[2/3] Install ${WRAP_PATH}"
sudo tee "${WRAP_PATH}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-/var/log/slurm/gpu-metrics}"

job_id="${SLURM_JOB_ID:-unknown}"
job_user="${SLURM_JOB_USER:-${USER:-unknown}}"
host="$(hostname -s)"
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

start_file="${LOG_DIR}/job-${job_id}-start.csv"
end_file="${LOG_DIR}/job-${job_id}-end.csv"

query="index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu"

snap() {
  local out="$1"
  {
    echo "ts,host,job_id,job_user,${query}"
    if command -v nvidia-smi >/dev/null 2>&1; then
      # csv,noheader,nounits -> stable for awk/jq parsing
      nvidia-smi --query-gpu="${query}" --format=csv,noheader,nounits \
        | awk -v T="$(ts)" -v H="${host}" -v J="${job_id}" -v U="${job_user}" 'BEGIN{FS=","; OFS=","} {gsub(/^ +| +$/, "", $0); print T,H,J,U,$0}'
    else
      echo "$(ts),${host},${job_id},${job_user},NO_NVIDIA_SMI"
    fi
  } > "${out}"
  chmod 0644 "${out}" || true
}

snap "${start_file}"

# Run the payload
"$@"
rc=$?

# Always attempt end snapshot
snap "${end_file}" || true

exit $rc
EOF

sudo chmod 0755 "${WRAP_PATH}"
sudo chown root:root "${WRAP_PATH}"

log "[3/3] Smoke check"
command -v gpu_wrap >/dev/null 2>&1 || true
echo "OK: installed gpu_wrap."
echo "Use in sbatch scripts like:"
echo "  gpu_wrap apptainer exec ... your_command ..."
