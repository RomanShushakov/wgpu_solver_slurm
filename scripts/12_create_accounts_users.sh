#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local}"

# "customer" = Slurm account (billing entity)
ACCOUNT_NAME="${ACCOUNT_NAME:-customer1}"
ACCOUNT_DESC="${ACCOUNT_DESC:-Customer 1}"

# "user" = Linux username and Slurm user name (keep same for simplicity)
USER_NAME="${USER_NAME:-user1}"
# Linux password for the user (demo mode)
# If empty, we do not set a password.
USER_PASSWORD="${USER_PASSWORD:-}"

# Whether to create Linux user + workspace directories
CREATE_LINUX_USER="${CREATE_LINUX_USER:-1}"

# Workspace layout
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/${USER_NAME}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/wgpu_workspace}"

# Slurm partition to test submission
PARTITION="${PARTITION:-local}"

# How long to wait for sacct record (seconds)
SACCT_WAIT_SECONDS="${SACCT_WAIT_SECONDS:-30}"

echo "=== Step 12: Create Slurm account/user + provision workspace ==="
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ACCOUNT_NAME=${ACCOUNT_NAME}"
echo "USER_NAME=${USER_NAME}"
echo "CREATE_LINUX_USER=${CREATE_LINUX_USER}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "PARTITION=${PARTITION}"
echo "SACCT_WAIT_SECONDS=${SACCT_WAIT_SECONDS}"
echo "==============================================================="

echo "[1/6] Sanity: slurmdbd reachable and cluster exists..."
sudo sacctmgr show cluster | grep -qE "^\s*${CLUSTER_NAME}\b" || {
  echo "ERROR: Cluster '${CLUSTER_NAME}' not found in sacctmgr."
  echo "Run Step 11 first."
  exit 1
}

echo "[2/6] Create Slurm account (idempotent)..."
sudo sacctmgr -i add account "${ACCOUNT_NAME}" Description="${ACCOUNT_DESC}" || true

echo "[3/6] Create Slurm user association (idempotent)..."
# Be explicit about cluster to avoid weird multi-cluster defaults
sudo sacctmgr -i add user name="${USER_NAME}" account="${ACCOUNT_NAME}" DefaultAccount="${ACCOUNT_NAME}" cluster="${CLUSTER_NAME}" || true

# IMPORTANT: make slurmctld pick up association changes promptly
echo "[3.5/6] Reconfigure slurmctld to pick up new associations..."
sudo scontrol reconfigure || true
sleep 1

echo "[4/6] Optionally create Linux user + workspace folders..."
if [[ "${CREATE_LINUX_USER}" == "1" ]]; then
  if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "${USER_NAME}"
    echo "Linux user '${USER_NAME}' created."
  else
    echo "Linux user '${USER_NAME}' already exists."
  fi

  echo "[4.1] Set Linux password (optional)..."
  if [[ -n "${USER_PASSWORD}" ]]; then
    echo "${USER_NAME}:${USER_PASSWORD}" | sudo chpasswd
    sudo passwd -u "${USER_NAME}" >/dev/null 2>&1 || true
    echo "Password set for linux user '${USER_NAME}'."
  else
    echo "USER_PASSWORD not set; leaving password unchanged."
  fi

  if [[ ! -d "${WORKSPACE_ROOT}" ]]; then
    echo "Home directory missing: ${WORKSPACE_ROOT}. Recreating..."
    sudo mkdir -p "${WORKSPACE_ROOT}"
  fi
  sudo chown "${USER_NAME}:${USER_NAME}" "${WORKSPACE_ROOT}"
  sudo chmod 750 "${WORKSPACE_ROOT}" || true

  sudo -u "${USER_NAME}" mkdir -p \
    "${WORKSPACE_DIR}/solvers" \
    "${WORKSPACE_DIR}/experiments" \
    "${WORKSPACE_DIR}/slurm" \
    "${WORKSPACE_DIR}/apptainer" \
    "${WORKSPACE_DIR}/slurm_logs"

  echo "Workspace prepared at: ${WORKSPACE_DIR}"
else
  echo "Skipping Linux user/workspace creation (CREATE_LINUX_USER=0)."
fi

echo "[5/6] Submit a tiny billable job as ${USER_NAME}..."
TEST_OUT="${WORKSPACE_DIR}/slurm_logs/slurm-acct-test-%j.out"
TEST_ERR="${WORKSPACE_DIR}/slurm_logs/slurm-acct-test-%j.err"

submit_test_job() {
  sudo -u "${USER_NAME}" bash -lc "
    set -euo pipefail
    cd '${WORKSPACE_DIR}'
    sbatch --parsable \
      --partition='${PARTITION}' \
      --account='${ACCOUNT_NAME}' \
      --job-name='acct_test' \
      --chdir='${WORKSPACE_DIR}' \
      --output='${TEST_OUT}' \
      --error='${TEST_ERR}' \
      --wrap='echo hello_from_\$(whoami); sleep 2'
  "
}

# Try once; if we hit the association race, reconfigure + retry once.
set +e
TEST_JOB_ID="$(submit_test_job 2>"/tmp/step12_${USER_NAME}_sbatch.err")"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  err="$(cat "/tmp/step12_${USER_NAME}_sbatch.err" || true)"
  if echo "${err}" | grep -qi "Invalid account or account/partition combination"; then
    echo "WARN: slurmctld hasn't picked up new associations yet; reconfigure + retry once..."
    sudo scontrol reconfigure || true
    sleep 2
    TEST_JOB_ID="$(submit_test_job)"
  else
    echo "ERROR: sbatch failed:"
    echo "${err}" >&2
    exit $rc
  fi
fi

echo "Submitted test job: ${TEST_JOB_ID}"

echo "[6/6] Wait for job completion + accounting record, then show sacct..."

for _ in $(seq 1 "${SACCT_WAIT_SECONDS}"); do
  if ! squeue -h -j "${TEST_JOB_ID}" >/dev/null 2>&1; then
    break
  fi
  if [[ -z "$(squeue -h -j "${TEST_JOB_ID}" 2>/dev/null || true)" ]]; then
    break
  fi
  sleep 1
done

found=0
for _ in $(seq 1 "${SACCT_WAIT_SECONDS}"); do
  line="$(sacct -X -n -P -j "${TEST_JOB_ID}" -o JobIDRaw,State 2>/dev/null | head -n 1 || true)"
  jobid_field="${line%%|*}"
  if [[ "${jobid_field}" == "${TEST_JOB_ID}" ]]; then
    found=1
    break
  fi
  sleep 1
done

if [[ "${found}" != "1" ]]; then
  echo "WARN: No sacct record for job ${TEST_JOB_ID} after ${SACCT_WAIT_SECONDS}s."
  scontrol show job "${TEST_JOB_ID}" 2>/dev/null || true
else
  sacct -X -j "${TEST_JOB_ID}" -o JobIDRaw,User,Account,Partition,State,Elapsed,AllocCPUS,AllocTRES%40 || true
  echo
fi

state="$(sacct -X -n -P -j "${TEST_JOB_ID}" -o State 2>/dev/null | head -n 1 | tr -d ' ' || true)"
if [[ -n "${state}" && "${state}" != "COMPLETED" ]]; then
  echo "Job state: ${state}"
  echo "--- stdout (${TEST_OUT//%j/${TEST_JOB_ID}}) ---"
  cat "${TEST_OUT//%j/${TEST_JOB_ID}}" 2>/dev/null || echo "(no stdout file found)"
  echo "--- stderr (${TEST_ERR//%j/${TEST_JOB_ID}}) ---"
  cat "${TEST_ERR//%j/${TEST_JOB_ID}}" 2>/dev/null || echo "(no stderr file found)"
fi

echo
echo "OK: Step 12 complete."
echo "Login test (local): su - ${USER_NAME}"
echo "Next: provisioning templates + per-user run wrapper (Step 20)."
