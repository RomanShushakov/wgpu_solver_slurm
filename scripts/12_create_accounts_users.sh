#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local}"

# "customer" = Slurm account (billing entity)
ACCOUNT_NAME="${ACCOUNT_NAME:-customer1}"
ACCOUNT_DESC="${ACCOUNT_DESC:-Customer 1}"

# "user" = Linux username and Slurm user name (keep same for simplicity)
USER_NAME="${USER_NAME:-user1}"

# Whether to create Linux user + workspace directories
CREATE_LINUX_USER="${CREATE_LINUX_USER:-1}"

# Workspace layout
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/${USER_NAME}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/wgpu_workspace}"

# Slurm partition to test submission
PARTITION="${PARTITION:-local}"

echo "=== Step 12: Create Slurm account/user + provision workspace ==="
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ACCOUNT_NAME=${ACCOUNT_NAME}"
echo "USER_NAME=${USER_NAME}"
echo "CREATE_LINUX_USER=${CREATE_LINUX_USER}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "PARTITION=${PARTITION}"
echo "==============================================================="

echo "[1/6] Sanity: slurmdbd reachable and cluster exists..."
sudo sacctmgr show cluster | grep -qE "^\s*${CLUSTER_NAME}\b" || {
  echo "ERROR: Cluster '${CLUSTER_NAME}' not found in sacctmgr."
  echo "Run Step 11 first."
  exit 1
}

echo "[2/6] Create Slurm account (idempotent)..."
# If exists, sacctmgr will error; we ignore safely
sudo sacctmgr -i add account "${ACCOUNT_NAME}" Description="${ACCOUNT_DESC}" || true

echo "[3/6] Create Slurm user association (idempotent)..."
# Create association (user -> account); ignore if exists
sudo sacctmgr -i add user name="${USER_NAME}" account="${ACCOUNT_NAME}" DefaultAccount="${ACCOUNT_NAME}" || true

echo "[4/6] Optionally create Linux user + workspace folders..."
if [[ "${CREATE_LINUX_USER}" == "1" ]]; then
  if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "${USER_NAME}"
    echo "Linux user '${USER_NAME}' created."
  else
    echo "Linux user '${USER_NAME}' already exists."
  fi

  # Workspace skeleton (user-owned)
  sudo -u "${USER_NAME}" mkdir -p \
    "${WORKSPACE_DIR}/solvers" \
    "${WORKSPACE_DIR}/experiments" \
    "${WORKSPACE_DIR}/slurm" \
    "${WORKSPACE_DIR}/apptainer"

  # Lock down home a bit (optional; comment out if you dislike)
  sudo chmod 750 "${WORKSPACE_ROOT}" || true

  echo "Workspace prepared at: ${WORKSPACE_DIR}"
else
  echo "Skipping Linux user/workspace creation (CREATE_LINUX_USER=0)."
fi

echo "[5/6] Submit a tiny billable job as ${USER_NAME}..."
TEST_JOB_ID="$(
  sudo -u "${USER_NAME}" sbatch --parsable \
    --partition="${PARTITION}" \
    --job-name="acct_test" \
    --wrap="echo hello_from_\$(whoami); sleep 2"
)"
echo "Submitted test job: ${TEST_JOB_ID}"

echo "[6/6] Wait briefly and show sacct record..."
sleep 3
sacct -X -j "${TEST_JOB_ID}" -o JobIDRaw,User,Account,State,Elapsed,AllocCPUS,AllocTRES%40

echo
echo "OK: Step 12 complete."
echo "Next: provisioning templates + per-user run wrapper (Step 20)."
