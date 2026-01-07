#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local}"

ACCOUNT_NAME="${ACCOUNT_NAME:-customer1}"
USER_NAME="${USER_NAME:-user1}"

# Workspace path used by step 12
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/${USER_NAME}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/wgpu_workspace}"

# Safety switches
DELETE_LINUX_USER="${DELETE_LINUX_USER:-0}"   # default: keep the unix user
DELETE_HOME="${DELETE_HOME:-0}"               # only meaningful if DELETE_LINUX_USER=1
DELETE_WORKSPACE="${DELETE_WORKSPACE:-1}"     # delete WORKSPACE_DIR by default
CANCEL_USER_JOBS="${CANCEL_USER_JOBS:-1}"     # cancel running/pending jobs for this user

echo "=== Step 12 UNDO: Remove Slurm account/user + workspace ==="
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ACCOUNT_NAME=${ACCOUNT_NAME}"
echo "USER_NAME=${USER_NAME}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "DELETE_WORKSPACE=${DELETE_WORKSPACE}"
echo "DELETE_LINUX_USER=${DELETE_LINUX_USER}  DELETE_HOME=${DELETE_HOME}"
echo "CANCEL_USER_JOBS=${CANCEL_USER_JOBS}"
echo "==========================================================="

echo "[0/6] Sanity: accounting should exist..."
sudo sacctmgr show cluster | grep -qE "^\s*${CLUSTER_NAME}\b" || {
  echo "WARNING: Cluster '${CLUSTER_NAME}' not found in sacctmgr. Continuing anyway."
}

echo "[1/6] Cancel user's running/pending jobs (optional)..."
if [[ "${CANCEL_USER_JOBS}" == "1" ]]; then
  # scancel will error if user doesn't exist; ignore
  sudo scancel -u "${USER_NAME}" 2>/dev/null || true
fi

echo "[2/6] Remove workspace directory (optional)..."
if [[ "${DELETE_WORKSPACE}" == "1" ]]; then
  if [[ -d "${WORKSPACE_DIR}" ]]; then
    sudo rm -rf "${WORKSPACE_DIR}"
    echo "Deleted workspace: ${WORKSPACE_DIR}"
  else
    echo "Workspace not found: ${WORKSPACE_DIR} (ok)"
  fi
else
  echo "Skipping workspace deletion."
fi

echo "[3/6] Remove Slurm user association..."
# Remove associations first; ignore if not found
sudo sacctmgr -i delete user name="${USER_NAME}" cluster="${CLUSTER_NAME}" 2>/dev/null || true

echo "[4/6] Remove Slurm account (only if empty)..."
# This will fail if other users/associations still exist; that's fine.
sudo sacctmgr -i delete account name="${ACCOUNT_NAME}" cluster="${CLUSTER_NAME}" 2>/dev/null || true

echo "[5/6] Optionally delete Linux user..."
if [[ "${DELETE_LINUX_USER}" == "1" ]]; then
  if id -u "${USER_NAME}" >/dev/null 2>&1; then
    if [[ "${DELETE_HOME}" == "1" ]]; then
      sudo userdel -r "${USER_NAME}" || true
      echo "Deleted linux user + home: ${USER_NAME}"
    else
      sudo userdel "${USER_NAME}" || true
      echo "Deleted linux user (home preserved): ${USER_NAME}"
    fi
  else
    echo "Linux user '${USER_NAME}' not found (ok)"
  fi
else
  echo "Keeping Linux user '${USER_NAME}' (DELETE_LINUX_USER=0)."
fi

echo "[6/6] Show remaining accounting objects (informational)..."
echo "--- assoc for user ---"
sudo sacctmgr show assoc where user="${USER_NAME}" format=Cluster,Account,User,QOS 2>/dev/null || true
echo "--- account ---"
sudo sacctmgr show account where name="${ACCOUNT_NAME}" format=Name,Description 2>/dev/null || true

echo
echo "OK: Step 12 undo completed."
echo "If you want a full reset of all slurm/apptainer/db, use purge_local.sh instead."
