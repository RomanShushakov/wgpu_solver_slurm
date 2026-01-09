#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

USER_NAME="${USER_NAME:-user1}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/home/${USER_NAME}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/wgpu_workspace}"

SRC_BIN="${SRC_BIN:-${REPO_ROOT}/solvers/wgpu_solver_backend_cli}"
SRC_IMAGE="${SRC_IMAGE:-${REPO_ROOT}/apptainer/solver-runtime.sif}"
SRC_TEST_CASE="${SRC_TEST_CASE:-${REPO_ROOT}/experiments/cases/test}"

COPY_TEST_CASE="${COPY_TEST_CASE:-1}"     # 1 = copy test case, 0 = skip
RSYNC_DELETE="${RSYNC_DELETE:-0}"         # 1 = use --delete, 0 = safer default

echo "=== Step 20: Provision per-user workspace (Option A: copy) ==="
echo "USER_NAME=${USER_NAME}"
echo "WORKSPACE_DIR=${WORKSPACE_DIR}"
echo "SRC_BIN=${SRC_BIN}"
echo "SRC_IMAGE=${SRC_IMAGE}"
echo "SRC_TEST_CASE=${SRC_TEST_CASE}"
echo "COPY_TEST_CASE=${COPY_TEST_CASE}"
echo "RSYNC_DELETE=${RSYNC_DELETE}"
echo "=============================================================="

id -u "${USER_NAME}" >/dev/null 2>&1 || {
  echo "ERROR: linux user '${USER_NAME}' not found. Run Step 12 first."
  exit 1
}
[[ -f "${SRC_BIN}" ]] || { echo "ERROR: missing solver bin: ${SRC_BIN}"; exit 1; }
[[ -f "${SRC_IMAGE}" ]] || { echo "ERROR: missing sif image: ${SRC_IMAGE}"; exit 1; }

echo "[1/6] Create workspace skeleton..."
sudo -u "${USER_NAME}" mkdir -p \
  "${WORKSPACE_DIR}/solvers" \
  "${WORKSPACE_DIR}/apptainer" \
  "${WORKSPACE_DIR}/experiments/cases" \
  "${WORKSPACE_DIR}/experiments/runs" \
  "${WORKSPACE_DIR}/slurm/templates"

echo "[2/6] Copy solver binary + sif..."
sudo install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${SRC_BIN}" \
  "${WORKSPACE_DIR}/solvers/wgpu_solver_backend_cli"
sudo install -m 0644 -o "${USER_NAME}" -g "${USER_NAME}" "${SRC_IMAGE}" \
  "${WORKSPACE_DIR}/apptainer/solver-runtime.sif"

echo "[2.1] Optionally copy test case..."
if [[ "${COPY_TEST_CASE}" == "1" ]]; then
  [[ -d "${SRC_TEST_CASE}" ]] || { echo "ERROR: missing test case dir: ${SRC_TEST_CASE}"; exit 1; }

  dest="${WORKSPACE_DIR}/experiments/cases/$(basename "${SRC_TEST_CASE}")"
  sudo -u "${USER_NAME}" mkdir -p "${dest}"

  rsync_flags=(-a)
  if [[ "${RSYNC_DELETE}" == "1" ]]; then
    rsync_flags+=(--delete)
  fi

  # copy contents of SRC_TEST_CASE into dest
  sudo rsync "${rsync_flags[@]}" "${SRC_TEST_CASE}/" "${dest}/"
  sudo chown -R "${USER_NAME}:${USER_NAME}" "${WORKSPACE_DIR}/experiments"
else
  echo "Skipping test case copy (COPY_TEST_CASE=0)."
fi

echo "[3/6] Copy slurm wrappers + templates..."
sudo install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${REPO_ROOT}/slurm/user/common.sh" \
  "${WORKSPACE_DIR}/slurm/common.sh"
sudo install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${REPO_ROOT}/slurm/user/submit_case.sh" \
  "${WORKSPACE_DIR}/slurm/submit_case.sh"
sudo install -m 0644 -o "${USER_NAME}" -g "${USER_NAME}" "${REPO_ROOT}/slurm/user/env.example.sh" \
  "${WORKSPACE_DIR}/slurm/env.example.sh"

sudo install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${REPO_ROOT}/slurm/user/templates/run_pcg_case.sbatch" \
  "${WORKSPACE_DIR}/slurm/run_pcg_case.sbatch"
sudo install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${REPO_ROOT}/slurm/user/templates/compare_x.sbatch" \
  "${WORKSPACE_DIR}/slurm/compare_x.sbatch"

echo "[4/6] Create slurm/env.sh if missing..."
if [[ ! -f "${WORKSPACE_DIR}/slurm/env.sh" ]]; then
  sudo -u "${USER_NAME}" cp "${WORKSPACE_DIR}/slurm/env.example.sh" "${WORKSPACE_DIR}/slurm/env.sh"
  echo "Created ${WORKSPACE_DIR}/slurm/env.sh (edit it for case paths)."
else
  echo "Keeping existing ${WORKSPACE_DIR}/slurm/env.sh"
fi

echo "[5/6] Tighten perms on home/workspace..."
sudo chmod 750 "${WORKSPACE_ROOT}" || true
sudo chmod 750 "${WORKSPACE_DIR}" || true

echo "[6/6] Done."
echo "As user:"
echo "  sudo -u ${USER_NAME} -H bash -lc 'cd ${WORKSPACE_DIR} && ./slurm/submit_case.sh'"
