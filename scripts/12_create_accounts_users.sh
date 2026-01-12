# scripts/12_create_accounts_users.sh
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local}"

ACCOUNT_NAME="${ACCOUNT_NAME:-customer1}"
ACCOUNT_DESC="${ACCOUNT_DESC:-Customer 1}"

USER_NAME="${USER_NAME:-user1}"
USER_PASSWORD="${USER_PASSWORD:-}"
CREATE_LINUX_USER="${CREATE_LINUX_USER:-1}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/${USER_NAME}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/wgpu_workspace}"

# IMPORTANT: for your Vultr node this should be gpu
PARTITION="${PARTITION:-gpu}"

SACCT_WAIT_SECONDS="${SACCT_WAIT_SECONDS:-45}"

log() { echo -e "\n=== $* ==="; }

log "Step 12: Create Slurm account/user + provision workspace"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ACCOUNT_NAME=${ACCOUNT_NAME}"
echo "USER_NAME=${USER_NAME}"
echo "PARTITION=${PARTITION}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"

log "[1/7] Sanity: cluster exists in sacctmgr"
sudo sacctmgr show cluster | grep -qE "^\s*${CLUSTER_NAME}\b" || {
  echo "ERROR: Cluster '${CLUSTER_NAME}' not found in sacctmgr. Run Step 11 first."
  exit 1
}

log "[2/7] Create Slurm account (idempotent)"
sudo sacctmgr -i add account "${ACCOUNT_NAME}" Description="${ACCOUNT_DESC}" || true

log "[3/7] Create Slurm user association (idempotent)"
sudo sacctmgr -i add user name="${USER_NAME}" account="${ACCOUNT_NAME}" DefaultAccount="${ACCOUNT_NAME}" cluster="${CLUSTER_NAME}" || true

log "[3.5/7] Reconfigure slurmctld to pick up associations"
sudo scontrol reconfigure || true
sleep 1

log "[4/7] Optionally create Linux user + workspace folders"
if [[ "${CREATE_LINUX_USER}" == "1" ]]; then
  if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "${USER_NAME}"
    echo "Linux user '${USER_NAME}' created."
  else
    echo "Linux user '${USER_NAME}' already exists."
  fi

  if [[ -n "${USER_PASSWORD}" ]]; then
    echo "${USER_NAME}:${USER_PASSWORD}" | sudo chpasswd
    sudo passwd -u "${USER_NAME}" >/dev/null 2>&1 || true
  fi

  sudo -u "${USER_NAME}" mkdir -p \
    "${WORKSPACE_DIR}/solvers" \
    "${WORKSPACE_DIR}/experiments" \
    "${WORKSPACE_DIR}/slurm" \
    "${WORKSPACE_DIR}/apptainer" \
    "${WORKSPACE_DIR}/slurm_logs"

  sudo chmod 750 "${WORKSPACE_ROOT}" || true
  sudo chown -R "${USER_NAME}:${USER_NAME}" "${WORKSPACE_ROOT}"
else
  echo "Skipping Linux user/workspace creation (CREATE_LINUX_USER=0)."
fi

log "[5/7] Submit a tiny test job as ${USER_NAME} (includes GPU allocation)"
TEST_OUT="${WORKSPACE_DIR}/slurm_logs/slurm-acct-test-%j.out"
TEST_ERR="${WORKSPACE_DIR}/slurm_logs/slurm-acct-test-%j.err"

submit_test_job() {
  sudo -u "${USER_NAME}" bash -lc "
    set -euo pipefail
    sbatch --parsable \
      --partition='${PARTITION}' \
      --account='${ACCOUNT_NAME}' \
      --job-name='acct_test' \
      --gres='gpu:1' \
      --output='${TEST_OUT}' \
      --error='${TEST_ERR}' \
      --wrap='echo hello_from_\$(whoami); nvidia-smi || true; sleep 2; nvidia-smi || true'
  "
}

set +e
TEST_JOB_ID="$(submit_test_job 2>"/tmp/step12_${USER_NAME}_sbatch.err")"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  err="$(cat "/tmp/step12_${USER_NAME}_sbatch.err" || true)"
  if echo "${err}" | grep -qi "Invalid account or account/partition combination"; then
    echo "WARN: association race; reconfigure + retry once..."
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

log "[6/7] Wait for job completion + show sacct"
for _ in $(seq 1 "${SACCT_WAIT_SECONDS}"); do
  if [[ -z "$(squeue -h -j "${TEST_JOB_ID}" 2>/dev/null || true)" ]]; then
    break
  fi
  sleep 1
done

for _ in $(seq 1 "${SACCT_WAIT_SECONDS}"); do
  if sacct -X -n -P -j "${TEST_JOB_ID}" -o JobIDRaw 2>/dev/null | head -n 1 | grep -qx "${TEST_JOB_ID}"; then
    break
  fi
  sleep 1
done

sacct -X -j "${TEST_JOB_ID}" -o JobIDRaw,User,Account,Partition,State,Elapsed,AllocCPUS,AllocTRES%60,ReqTRES%60 || true

log "[7/7] Done"
echo "OK: Step 12 complete."
