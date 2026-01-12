#!/usr/bin/env bash
set -euo pipefail

# Run from repo root:  bash init_local.sh
REPO_ROOT="$(cd "${REPO_ROOT:-.}" && pwd)"

# ---- Versions ----
APPTAINER_VERSION="${APPTAINER_VERSION:-1.4.5}"

# ---- Paths in repo ----
BIN="${BIN:-${REPO_ROOT}/solvers/wgpu_solver_backend_cli}"
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
PARTITION="${PARTITION:-gpu}"

# ---- GPU params ----
# If you want NVML autodetect, set GRES_AUTODETECT=1
GRES_AUTODETECT="${GRES_AUTODETECT:-0}"
# Force Apptainer to use NVIDIA support (recommended on Vultr GPU)
APPTAINER_GPU="${APPTAINER_GPU:-"--nv"}"

echo "=== init_local (vultr) ==="
echo "REPO_ROOT=${REPO_ROOT}"
echo "BIN=${BIN}"
echo "CASE_DIR=${CASE_DIR}"
echo "OUT_DIR=${OUT_DIR}"
echo "X_REF=${X_REF}"
echo "APPTAINER_VERSION=${APPTAINER_VERSION}"
echo "PARTITION=${PARTITION}"
echo "GRES_AUTODETECT=${GRES_AUTODETECT}"
echo "APPTAINER_GPU=${APPTAINER_GPU}"
echo "=========================="

mkdir -p "${REPO_ROOT}/apptainer" "${REPO_ROOT}/slurm" "${OUT_DIR}" "${REPO_ROOT}/slurm_logs"
chmod +x "${BIN}" || true

###############################################################################
# 1) Install packages
###############################################################################
echo "[1/7] Installing Slurm + Munge + deps..."
sudo apt-get update
sudo apt-get install -y munge slurm-wlm slurm-client jq wget ca-certificates \
  libvulkan1 mesa-vulkan-drivers vulkan-tools

###############################################################################
# 2) Install Apptainer
###############################################################################
echo "[2/7] Installing Apptainer ${APPTAINER_VERSION}..."
cd /tmp
DEB="apptainer_${APPTAINER_VERSION}_amd64.deb"
if [[ ! -f "${DEB}" ]]; then
  wget -q "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/${DEB}"
fi
sudo dpkg -i "${DEB}" || sudo apt-get -f install -y
apptainer version

###############################################################################
# 3) Enable munge
###############################################################################
echo "[3/7] Enabling munge..."
sudo systemctl enable --now munge
munge -n | unmunge >/dev/null

###############################################################################
# 4) Configure single-node Slurm (GPU)
###############################################################################
echo "[4/7] Configuring single-node Slurm..."
HN="$(hostname -s)"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
# Keep a small reserve so Slurm doesn't overcommit
REALMEM="$(( MEM_MB > 2048 ? MEM_MB - 1024 : MEM_MB ))"
CPUS="$(nproc --all)"

sudo mkdir -p /var/lib/slurm/slurmctld /var/lib/slurm/slurmd
sudo chown -R slurm:slurm /var/lib/slurm

# Logs + run dir
sudo mkdir -p /var/log/slurm /run/slurm
sudo chown slurm:slurm /var/log/slurm /run/slurm
sudo chmod 755 /var/log/slurm /run/slurm

# cgroup config (helps device isolation; also required for clean accounting later)
sudo tee /etc/slurm/cgroup.conf >/dev/null <<'EOF'
CgroupAutomount=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
EOF

# gres config
sudo tee /etc/slurm/gres.conf >/dev/null <<EOF
$( [[ "${GRES_AUTODETECT}" == "1" ]] && echo "AutoDetect=nvml" || echo "Name=gpu File=/dev/nvidia0" )
EOF

# IMPORTANT: use real hostname for NodeName and partition
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
TaskPlugin=task/cgroup
JobAcctGatherType=jobacct_gather/cgroup

SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# accounting disabled here; enable via slurmdbd scripts later
AccountingStorageType=accounting_storage/none

GresTypes=gpu

NodeName=${HN} CPUs=${CPUS} RealMemory=${REALMEM} State=UNKNOWN Gres=gpu:1
PartitionName=${PARTITION} Nodes=${HN} Default=YES MaxTime=INFINITE State=UP
EOF

sudo systemctl enable --now slurmctld slurmd
sudo systemctl restart munge
sudo systemctl restart slurmctld slurmd

echo "Slurm sanity:"
sinfo -N -l
scontrol show node "${HN}" | egrep -i 'NodeName|State|Gres|CfgTRES|Partitions' || true

echo "GPU sanity:"
nvidia-smi -L || true

###############################################################################
# 5) Build Apptainer runtime
###############################################################################
echo "[5/7] Building Apptainer runtime SIF..."
cat > "${DEF}" <<'EOF'
Bootstrap: docker
From: debian:bookworm-slim

%post
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    libvulkan1 \
    mesa-vulkan-drivers \
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

###############################################################################
# 6) Write sbatch scripts (GPU-aware)
###############################################################################
echo "[6/7] Writing sbatch scripts..."

cat > "${REPO_ROOT}/slurm/run_pcg_case.sbatch" <<'EOF'
#!/bin/bash
#SBATCH --job-name=wgpu_pcg
#SBATCH --output=slurm_logs/slurm-pcg-%j.out
#SBATCH --error=slurm_logs/slurm-pcg-%j.err
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --gres=gpu:1
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
: "${APPTAINER_GPU:=--nv}"

mkdir -p slurm_logs "${OUT_DIR}"
OUT_X="${OUT_DIR}/x.bin"
OUT_METRICS="${OUT_DIR}/metrics.json"

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
#SBATCH --output=slurm_logs/slurm-cmp-%j.out
#SBATCH --error=slurm_logs/slurm-cmp-%j.err
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#SBATCH --gres=gpu:1
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
: "${APPTAINER_GPU:=--nv}"

mkdir -p slurm_logs
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

###############################################################################
# 7) Submit demo jobs
###############################################################################
echo "[7/7] Submitting jobs..."
cd "${REPO_ROOT}"

export IMAGE BIN CASE_DIR OUT_DIR BACKEND MAX_ITERS REL_TOL ABS_TOL
export X_REF CMP_REL_TOL CMP_ABS_TOL TOP_K
export APPTAINER_GPU

JOB1="$(sbatch --parsable --partition="${PARTITION}" slurm/run_pcg_case.sbatch)"
echo "PCG job: ${JOB1}"

JOB2="$(sbatch --parsable --partition="${PARTITION}" --dependency=afterok:${JOB1} slurm/compare_x.sbatch)"
echo "COMPARE job: ${JOB2} (afterok:${JOB1})"

echo
echo "Track: squeue"
echo "Logs: slurm_logs/slurm-pcg-${JOB1}.out  slurm_logs/slurm-cmp-${JOB2}.out"
echo "Outputs: ${OUT_DIR}/x.bin  ${OUT_DIR}/metrics.json"
