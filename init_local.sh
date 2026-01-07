#!/usr/bin/env bash
set -euo pipefail

# Run from repo root:  bash repro_local.sh
REPO_ROOT="$(cd "${REPO_ROOT:-.}" && pwd)"

# ---- Versions ----
APPTAINER_VERSION="${APPTAINER_VERSION:-1.4.5}"

# ---- Paths in repo ----
BIN="${BIN:-${REPO_ROOT}/solver/wgpu_solver_backend_cli}"
IMAGE="${IMAGE:-${REPO_ROOT}/apptainer/solver-runtime.sif}"
DEF="${DEF:-${REPO_ROOT}/apptainer/solver-runtime.def}"

CASE_DIR="${CASE_DIR:-${REPO_ROOT}/experiments/cases/test}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/experiments/runs/test}"
X_REF="${X_REF:-${REPO_ROOT}/experiments/cases/test/x_ref.bin}"

# ---- Solver params ----
BACKEND="${BACKEND:-auto}"
MAX_ITERS="${MAX_ITERS:-2000}"
REL_TOL="${REL_TOL:-1e-4}"
ABS_TOL="${ABS_TOL:-1e-7}"

# ---- Compare params ----
CMP_REL_TOL="${CMP_REL_TOL:-1e-4}"
CMP_ABS_TOL="${CMP_ABS_TOL:-1e-7}"
TOP_K="${TOP_K:-10}"

# ---- Slurm params ----
PARTITION="${PARTITION:-local}"

echo "=== repro_local ==="
echo "REPO_ROOT=${REPO_ROOT}"
echo "BIN=${BIN}"
echo "CASE_DIR=${CASE_DIR}"
echo "OUT_DIR=${OUT_DIR}"
echo "X_REF=${X_REF}"
echo "APPTAINER_VERSION=${APPTAINER_VERSION}"
echo "==================="

mkdir -p "${REPO_ROOT}/apptainer" "${REPO_ROOT}/slurm" "${OUT_DIR}"
chmod +x "${BIN}"

# 1) Install packages
echo "[1/6] Installing Slurm + Munge + deps..."
sudo apt-get update
sudo apt-get install -y munge slurm-wlm jq wget ca-certificates \
  libvulkan1 mesa-vulkan-drivers vulkan-tools

echo "[2/6] Installing Apptainer ${APPTAINER_VERSION}..."
cd /tmp
DEB="apptainer_${APPTAINER_VERSION}_amd64.deb"
if [[ ! -f "${DEB}" ]]; then
  wget -q "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/${DEB}"
fi
sudo dpkg -i "${DEB}" || sudo apt-get -f install -y
apptainer version

# 2) Enable munge
echo "[3/6] Enabling munge..."
sudo systemctl enable --now munge
munge -n | unmunge >/dev/null

# 3) Configure single-node Slurm
echo "[4/6] Configuring single-node Slurm..."
HN="$(hostname -s)"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
REALMEM="$(( MEM_MB > 1024 ? MEM_MB - 512 : MEM_MB ))"
CPUS=1

sudo mkdir -p /var/lib/slurm/slurmctld /var/lib/slurm/slurmd
sudo chown -R slurm:slurm /var/lib/slurm

sudo tee /etc/slurm/slurm.conf >/dev/null <<EOF
ClusterName=local
SlurmctldHost=${HN}
SlurmUser=slurm

AuthType=auth/munge
CryptoType=crypto/munge

StateSaveLocation=/var/lib/slurm/slurmctld
SlurmdSpoolDir=/var/lib/slurm/slurmd

SlurmctldPort=6817
SlurmdPort=6818

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
ProctrackType=proctrack/cgroup

SlurmctldLogFile=/var/log/slurmctld.log
SlurmdLogFile=/var/log/slurmd.log

# local dev: disable accounting / mpi noise
AccountingStorageType=accounting_storage/none
JobAcctGatherType=jobacct_gather/none
MpiDefault=none

NodeName=${HN} CPUs=${CPUS} RealMemory=${REALMEM} State=UNKNOWN
PartitionName=${PARTITION} Nodes=${HN} Default=YES MaxTime=INFINITE State=UP
EOF

sudo systemctl enable --now slurmctld slurmd
sudo systemctl restart slurmctld slurmd
sinfo

# 4) Build Apptainer runtime
echo "[5/6] Building Apptainer runtime SIF..."
cat > "${DEF}" <<'EOF'
Bootstrap: docker
From: ubuntu:24.04

%post
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    libvulkan1 \
    mesa-vulkan-drivers \
    vulkan-tools \
    libstdc++6 \
    libgcc-s1 \
  && rm -rf /var/lib/apt/lists/*

%environment
  export LC_ALL=C
  export LANG=C
  export RUST_BACKTRACE=1

%runscript
  exec "$@"
EOF

sudo apptainer build "${IMAGE}" "${DEF}"

# 5) Ensure job scripts exist (minimal, stable versions)
echo "[6/6] Writing sbatch scripts + submitting jobs..."

cat > "${REPO_ROOT}/slurm/run_pcg_case.sbatch" <<'EOF'
#!/bin/bash
#SBATCH --job-name=wgpu_pcg
#SBATCH --output=slurm-pcg-%j.out
#SBATCH --error=slurm-pcg-%j.err
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --chdir=.

set -euo pipefail
ROOT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "${ROOT_DIR}"

: "${IMAGE:?missing IMAGE}"
: "${BIN:?missing BIN}"
: "${CASE_DIR:?missing CASE_DIR}"
: "${OUT_DIR:?missing OUT_DIR}"
: "${BACKEND:=auto}"
: "${MAX_ITERS:=2000}"
: "${REL_TOL:=1e-4}"
: "${ABS_TOL:=1e-7}"
: "${APPTAINER_GPU:=}"

OUT_X="${OUT_DIR}/x.bin"
OUT_METRICS="${OUT_DIR}/metrics.json"
mkdir -p "${OUT_DIR}"

apptainer exec ${APPTAINER_GPU} --bind "${ROOT_DIR}:${ROOT_DIR}" "${IMAGE}" bash -lc "
  set -euo pipefail
  cd '${ROOT_DIR}'
  '${BIN}' --backend '${BACKEND}' run-pcg-case \
    --case-dir '${CASE_DIR}' \
    --max-iters '${MAX_ITERS}' \
    --rel-tol '${REL_TOL}' \
    --abs-tol '${ABS_TOL}' \
    --out-x '${OUT_X}' \
    --out-metrics '${OUT_METRICS}'
"
EOF
chmod +x "${REPO_ROOT}/slurm/run_pcg_case.sbatch"

cat > "${REPO_ROOT}/slurm/compare_x.sbatch" <<'EOF'
#!/bin/bash
#SBATCH --job-name=wgpu_cmp
#SBATCH --output=slurm-cmp-%j.out
#SBATCH --error=slurm-cmp-%j.err
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#SBATCH --chdir=.

set -euo pipefail
ROOT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "${ROOT_DIR}"

: "${IMAGE:?missing IMAGE}"
: "${BIN:?missing BIN}"
: "${X_REF:?missing X_REF}"
: "${OUT_DIR:?missing OUT_DIR}"
: "${CMP_REL_TOL:=1e-5}"
: "${CMP_ABS_TOL:=1e-3}"
: "${TOP_K:=10}"
: "${APPTAINER_GPU:=}"

X="${OUT_DIR}/x.bin"

apptainer exec ${APPTAINER_GPU} --bind "${ROOT_DIR}:${ROOT_DIR}" "${IMAGE}" bash -lc "
  set -euo pipefail
  cd '${ROOT_DIR}'
  '${BIN}' compare-x \
    --x-ref '${X_REF}' \
    --x '${X}' \
    --rel-tol '${CMP_REL_TOL}' \
    --abs-tol '${CMP_ABS_TOL}' \
    --top-k '${TOP_K}'
"
EOF
chmod +x "${REPO_ROOT}/slurm/compare_x.sbatch"

# Submit jobs
cd "${REPO_ROOT}"
export IMAGE BIN CASE_DIR OUT_DIR BACKEND MAX_ITERS REL_TOL ABS_TOL
export X_REF CMP_REL_TOL CMP_ABS_TOL TOP_K
export APPTAINER_GPU="${APPTAINER_GPU:-}"

JOB1="$(sbatch --parsable slurm/run_pcg_case.sbatch)"
echo "PCG job: ${JOB1}"

JOB2="$(sbatch --parsable --dependency=afterok:${JOB1} slurm/compare_x.sbatch)"
echo "COMPARE job: ${JOB2} (afterok:${JOB1})"

echo
echo "Track: squeue"
echo "Logs: slurm-pcg-${JOB1}.out  slurm-cmp-${JOB2}.out"
echo "Outputs: ${OUT_DIR}/x.bin  ${OUT_DIR}/metrics.json"
