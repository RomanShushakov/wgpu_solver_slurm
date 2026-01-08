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
sudo sacctmgr -i add user name="${USER_NAME}" account="${ACCOUNT_NAME}" DefaultAccount="${ACCOUNT_NAME}" || true

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
    # Set password non-interactively
    echo "${USER_NAME}:${USER_PASSWORD}" | sudo chpasswd
    # Ensure password auth is allowed (in case user was locked previously)
    sudo passwd -u "${USER_NAME}" >/dev/null 2>&1 || true
    echo "Password set for linux user '${USER_NAME}'."
  else
    echo "USER_PASSWORD not set; leaving password unchanged."
  fi

  # Ensure home exists and is owned by the user (handles manual deletions)
  if [[ ! -d "${WORKSPACE_ROOT}" ]]; then
    echo "Home directory missing: ${WORKSPACE_ROOT}. Recreating..."
    sudo mkdir -p "${WORKSPACE_ROOT}"
  fi
  sudo chown "${USER_NAME}:${USER_NAME}" "${WORKSPACE_ROOT}"
  sudo chmod 750 "${WORKSPACE_ROOT}" || true

  # Workspace skeleton (user-owned)
  sudo -u "${USER_NAME}" mkdir -p \
    "${WORKSPACE_DIR}/solvers" \
    "${WORKSPACE_DIR}/experiments" \
    "${WORKSPACE_DIR}/slurm" \
    "${WORKSPACE_DIR}/apptainer"

  sudo chmod 750 "${WORKSPACE_ROOT}" || true
  echo "Workspace prepared at: ${WORKSPACE_DIR}"
else
  echo "Skipping Linux user/workspace creation (CREATE_LINUX_USER=0)."
fi

echo "[5/6] Submit a tiny billable job as ${USER_NAME}..."
TEST_OUT="${WORKSPACE_DIR}/slurm_logs/slurm-acct-test-%j.out"
TEST_ERR="${WORKSPACE_DIR}/slurm_logs/slurm-acct-test-%j.err"

TEST_JOB_ID="$(
  sudo -u "${USER_NAME}" bash -lc "
    set -euo pipefail
    cd '${WORKSPACE_DIR}'
    mkdir -p slurm_logs
    sbatch --parsable \
      --partition='${PARTITION}' \
      --job-name='acct_test' \
      --chdir='${WORKSPACE_DIR}' \
      --output='${TEST_OUT}' \
      --error='${TEST_ERR}' \
      --wrap='echo hello_from_\$(whoami); sleep 2'
  "
)"
echo "Submitted test job: ${TEST_JOB_ID}"


echo "[6/6] Wait for job completion + accounting record, then show sacct..."

# 6a) Wait until job leaves the queue (COMPLETED/FAILED/etc.)
for _ in $(seq 1 "${SACCT_WAIT_SECONDS}"); do
  if ! squeue -h -j "${TEST_JOB_ID}" >/dev/null 2>&1; then
    # some Slurm builds return nonzero if job unknown; treat as "left queue"
    break
  fi
  if [[ -z "$(squeue -h -j "${TEST_JOB_ID}" 2>/dev/null || true)" ]]; then
    break
  fi
  sleep 1
done

# 6b) Now wait until sacct returns a real record line (not just headers).
# We request parseable output and check that the first field is non-empty and equals job id.
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
  echo "Show job (if available):"
  scontrol show job "${TEST_JOB_ID}" 2>/dev/null || true
  echo "Try manually:"
  echo "  sacct -X -j ${TEST_JOB_ID} --duplicates"
  echo
else
  sacct -X -j "${TEST_JOB_ID}" -o JobIDRaw,User,Account,State,Elapsed,AllocCPUS,AllocTRES%40 || true
  echo
fi

# 6c) If the job failed, show stderr/stdout to make debugging trivial.
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
