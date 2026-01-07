#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local}"

ACCOUNT_NAME="${ACCOUNT_NAME:-customer1}"
USER_NAME="${USER_NAME:-user1}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/${USER_NAME}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/wgpu_workspace}"

DELETE_LINUX_USER="${DELETE_LINUX_USER:-0}"
DELETE_HOME="${DELETE_HOME:-0}"
DELETE_WORKSPACE="${DELETE_WORKSPACE:-1}"
CANCEL_USER_JOBS="${CANCEL_USER_JOBS:-1}"

# Remove Slurm account object as well (only if empty)
DELETE_ACCOUNT="${DELETE_ACCOUNT:-1}"

# If set to 1, do not change anything (just print what would happen)
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

echo "=== Step 12 UNDO: Remove Slurm assoc/account + workspace ==="
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ACCOUNT_NAME=${ACCOUNT_NAME}"
echo "USER_NAME=${USER_NAME}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "DELETE_WORKSPACE=${DELETE_WORKSPACE}"
echo "DELETE_LINUX_USER=${DELETE_LINUX_USER}  DELETE_HOME=${DELETE_HOME}"
echo "DELETE_ACCOUNT=${DELETE_ACCOUNT}"
echo "CANCEL_USER_JOBS=${CANCEL_USER_JOBS}"
echo "DRY_RUN=${DRY_RUN}"
echo "==========================================================="

echo "[0/7] Preflight: show current objects (debug)..."
sudo sacctmgr show assoc where cluster="${CLUSTER_NAME}" and account="${ACCOUNT_NAME}" format=Cluster,Account,User,QOS 2>/dev/null || true
sudo sacctmgr show assoc where cluster="${CLUSTER_NAME}" and user="${USER_NAME}" format=Cluster,Account,User,QOS 2>/dev/null || true
sudo sacctmgr show account where name="${ACCOUNT_NAME}" format=Name,Description 2>/dev/null || true
echo

echo "[1/7] Cancel user's running/pending jobs (optional)..."
if [[ "${CANCEL_USER_JOBS}" == "1" ]]; then
  # Cancel all pending/running jobs for the user. (Safe if user doesn't exist.)
  run "sudo scancel -u '${USER_NAME}' 2>/dev/null || true"
fi

echo "[2/7] Remove workspace directory (optional)..."
if [[ "${DELETE_WORKSPACE}" == "1" ]]; then
  if [[ -d "${WORKSPACE_DIR}" ]]; then
    run "sudo rm -rf '${WORKSPACE_DIR}'"
    echo "Deleted workspace: ${WORKSPACE_DIR}"
  else
    echo "Workspace not found: ${WORKSPACE_DIR} (ok)"
  fi
fi

echo "[3/7] Remove Slurm association(s) for this user+account (precise)..."
# Delete ONLY the association under (cluster, account, user)
run "sudo sacctmgr -i delete assoc where cluster='${CLUSTER_NAME}' and account='${ACCOUNT_NAME}' and user='${USER_NAME}' 2>/dev/null || true"

echo "[4/7] Show remaining associations under account (debug)..."
sudo sacctmgr show assoc where cluster="${CLUSTER_NAME}" and account="${ACCOUNT_NAME}" format=Cluster,Account,User,QOS 2>/dev/null || true

echo "[5/7] Remove Slurm account (optional, only if empty)..."
if [[ "${DELETE_ACCOUNT}" == "1" ]]; then
  # Attempt to delete the account; if associations still exist, Slurm will refuse.
  run "sudo sacctmgr -i delete account where name='${ACCOUNT_NAME}' 2>/dev/null || true"
else
  echo "Keeping Slurm account '${ACCOUNT_NAME}' (DELETE_ACCOUNT=0)."
fi

echo "[6/7] Optionally delete Linux user..."
if [[ "${DELETE_LINUX_USER}" == "1" ]]; then
  if id -u "${USER_NAME}" >/dev/null 2>&1; then
    if [[ "${DELETE_HOME}" == "1" ]]; then
      run "sudo userdel -r '${USER_NAME}' || true"
      echo "Deleted linux user + home: ${USER_NAME}"
    else
      run "sudo userdel '${USER_NAME}' || true"
      echo "Deleted linux user (home preserved): ${USER_NAME}"
    fi
  else
    echo "Linux user '${USER_NAME}' not found (ok)"
  fi
else
  echo "Keeping Linux user '${USER_NAME}' (DELETE_LINUX_USER=0)."
fi

echo "[7/7] Show remaining accounting objects (informational)..."
echo "--- assoc for user ---"
sudo sacctmgr show assoc where cluster="${CLUSTER_NAME}" and user="${USER_NAME}" format=Cluster,Account,User,QOS 2>/dev/null || true
echo "--- account ---"
sudo sacctmgr show account where name="${ACCOUNT_NAME}" format=Name,Description 2>/dev/null || true

echo
echo "OK: Step 12 undo completed."
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "NOTE: DRY_RUN=1, nothing was actually changed."
fi
