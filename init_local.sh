#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Config knobs ----
CLUSTER_NAME="${CLUSTER_NAME:-local}"

# slurmdbd listens locally only
SLURMDBD_PORT="${SLURMDBD_PORT:-6819}"
SLURMDBD_ADDR="${SLURMDBD_ADDR:-127.0.0.1}"

# MariaDB in Docker (published to 127.0.0.1:3306 on host)
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-slurm_acct_db}"
DB_USER="${DB_USER:-slurm}"
DB_PASS="${DB_PASS:-slurmpass_change_me}"

# Default account/user for “local demo”
DEFAULT_ACCOUNT="${DEFAULT_ACCOUNT:-admin}"
DEFAULT_USER="${DEFAULT_USER:-root}"

log() { echo -e "\n=== $* ==="; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }
}

wait_tcp4() {
  local host="$1" port="$2" tries="${3:-40}" sleep_s="${4:-1}"
  for _ in $(seq 1 "$tries"); do
    if nc -4 -vz "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || true)"

log "Install required packages (slurm + munge + accounting)"
sudo apt-get update -y
sudo apt-get install -y \
  munge \
  slurm-wlm slurmctld slurmd slurm-client \
  slurmdbd slurm-wlm-mysql-plugin \
  netcat-openbsd

require_cmd systemctl
require_cmd nc
require_cmd sacctmgr
require_cmd scontrol

log "init_local"
echo "REPO_ROOT=${REPO_ROOT}"
echo "HOST_SHORT=${HOST_SHORT}"
echo "HOST_FQDN=${HOST_FQDN}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "SLURMDBD_ADDR=${SLURMDBD_ADDR}"
echo "SLURMDBD_PORT=${SLURMDBD_PORT}"
echo "DB_HOST=${DB_HOST}"
echo "DB_PORT=${DB_PORT}"
echo "DB_NAME=${DB_NAME}"
echo "DEFAULT_ACCOUNT=${DEFAULT_ACCOUNT}"
echo "DEFAULT_USER=${DEFAULT_USER}"

log "0) Make /run/slurm persistent + writable (tmpfiles)"
sudo tee /etc/tmpfiles.d/slurm.conf >/dev/null <<'EOF'
d /run/slurm 0755 slurm slurm -
EOF
sudo systemd-tmpfiles --create

# Ensure dirs exist and ownership is correct now
sudo mkdir -p /run/slurm /var/log/slurm
sudo chown slurm:slurm /run/slurm /var/log/slurm
sudo chmod 0755 /run/slurm

log "0.5) systemd override for slurmdbd: stable /run/slurm + wait for DB + restart policy"
sudo mkdir -p /etc/systemd/system/slurmdbd.service.d
sudo tee /etc/systemd/system/slurmdbd.service.d/override.conf >/dev/null <<EOF
[Service]
# systemd creates /run/slurm as /run/slurmdbd? No: we force /run/slurm with ExecStartPre.
RuntimeDirectory=slurm
RuntimeDirectoryMode=0755

# Ensure /run/slurm exists with correct owner every start (fixes pidfile permission flakiness)
ExecStartPre=/usr/bin/install -d -m 0755 -o slurm -g slurm /run/slurm

# Wait until DB is reachable before starting slurmdbd (fixes mysql_real_connect timing)
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do nc -4 -z ${DB_HOST} ${DB_PORT} && exit 0; sleep 1; done; exit 1'

Restart=on-failure
RestartSec=2
EOF
sudo systemctl daemon-reload

log "1) Ensure MariaDB container is up (optional)"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if [[ -f "${REPO_ROOT}/admin/docker-compose.mariadb.yml" ]]; then
    docker compose -f "${REPO_ROOT}/admin/docker-compose.mariadb.yml" up -d
  fi
fi

log "1.1) Wait for MariaDB TCP port (host side)"
if ! wait_tcp4 "${DB_HOST}" "${DB_PORT}" 60 1; then
  echo "ERROR: MariaDB not reachable at ${DB_HOST}:${DB_PORT}"
  echo "If you use docker-compose, check: docker ps; docker logs slurm-mariadb"
  exit 1
fi

log "2) Write /etc/slurm/slurmdbd.conf (host identity + local bind + pidfile)"
sudo mkdir -p /etc/slurm
sudo tee /etc/slurm/slurmdbd.conf >/dev/null <<EOF
AuthType=auth/munge

# Identity check: MUST match hostname -s (or hostname -f).
DbdHost=${HOST_SHORT}

# Bind/listen only on IPv4 loopback for safety
DbdAddr=${SLURMDBD_ADDR}
DbdPort=${SLURMDBD_PORT}

SlurmUser=slurm

StorageType=accounting_storage/mysql
StorageHost=${DB_HOST}
StoragePort=${DB_PORT}
StorageUser=${DB_USER}
StoragePass=${DB_PASS}
StorageLoc=${DB_NAME}

LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurm/slurmdbd.pid
EOF
sudo chown slurm:slurm /etc/slurm/slurmdbd.conf
sudo chmod 0600 /etc/slurm/slurmdbd.conf

log "3) Start munge + slurmdbd (verify it REALLY listens)"
sudo systemctl enable --now munge
sudo systemctl restart munge

sudo systemctl enable --now slurmdbd
sudo systemctl restart slurmdbd

if ! wait_tcp4 "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 60 1; then
  echo "ERROR: slurmdbd is not accepting TCP on ${SLURMDBD_ADDR}:${SLURMDBD_PORT}"
  sudo systemctl status slurmdbd --no-pager || true
  sudo journalctl -u slurmdbd -n 200 --no-pager || true
  sudo ss -lntp | egrep ":${SLURMDBD_PORT}\b|slurmdbd" || true
  exit 1
fi

log "3.5) Stop slurmctld/slurmd before writing slurm.conf"
sudo systemctl stop slurmctld slurmd 2>/dev/null || true

log "3.6) Ensure /etc/slurm/slurm.conf exists (create if missing)"
sudo mkdir -p /etc/slurm

# detect CPU count + memory (MB)
CPU_TOTAL="$(nproc || echo 2)"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 7000)"

if [[ ! -f /etc/slurm/slurm.conf ]]; then
  sudo tee /etc/slurm/slurm.conf >/dev/null <<EOF
#
# Auto-generated by init_local.sh (single-node)
#
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${HOST_SHORT}
SlurmUser=slurm
SlurmdUser=root

AuthType=auth/munge
CryptoType=crypto/munge

SlurmctldPort=6817
SlurmdPort=6818

StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup

GresTypes=gpu

# Accounting via slurmdbd (TRES enabled later by enable_gpu_tres.sh)
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=127.0.0.1
JobAcctGatherType=jobacct_gather/cgroup

# Disable MPI plugin noise
MpiDefault=none

NodeName=${HOST_SHORT} CPUs=${CPU_TOTAL} RealMemory=${MEM_MB} Gres=gpu:1 State=UNKNOWN
PartitionName=gpu Nodes=${HOST_SHORT} Default=YES MaxTime=INFINITE State=UP

MailProg=/usr/bin/mail
EOF
  sudo chmod 0644 /etc/slurm/slurm.conf
else
  # Keep user edits, but enforce the critical accounting host/type lines and MPI-noise setting.
  sudo sed -i \
    -e 's/^AccountingStorageHost=.*/AccountingStorageHost=127.0.0.1/' \
    -e 's/^AccountingStorageType=.*/AccountingStorageType=accounting_storage\/slurmdbd/' \
    -e 's/^MpiDefault=.*/MpiDefault=none/' \
    /etc/slurm/slurm.conf || true

  # Ensure MailProg exists line (avoid "Configured MailProg is invalid")
  if ! grep -q '^MailProg=' /etc/slurm/slurm.conf; then
    echo 'MailProg=/usr/bin/mail' | sudo tee -a /etc/slurm/slurm.conf >/dev/null
  fi
fi

log "3.7) Ensure /etc/slurm/gres.conf exists"
if [[ ! -f /etc/slurm/gres.conf ]]; then
  sudo tee /etc/slurm/gres.conf >/dev/null <<EOF
NodeName=${HOST_SHORT} Name=gpu File=/dev/nvidia0
EOF
  sudo chmod 0644 /etc/slurm/gres.conf
fi

log "3.8) Ensure state/log dirs exist with correct ownership"
sudo mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd /var/lib/slurm /run/slurm
sudo chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd /var/lib/slurm /run/slurm
sudo chmod 0755 /var/log/slurm /var/spool/slurmctld /var/spool/slurmd /run/slurm

log "4) Start slurmctld/slurmd (slurmdbd must be reachable first)"
# Guard: slurmctld will die if it can’t reach slurmdbd and you later enable AccountingStorageTRES.
if ! wait_tcp4 "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 30 1; then
  echo "ERROR: slurmdbd not reachable right before starting slurmctld"
  exit 1
fi

sudo systemctl enable --now slurmctld slurmd
sudo systemctl restart slurmctld
sudo systemctl restart slurmd

if ! scontrol ping >/dev/null 2>&1; then
  echo "ERROR: slurmctld not reachable after restart"
  sudo systemctl status slurmctld --no-pager || true
  sudo journalctl -u slurmctld -n 200 --no-pager || true
  exit 1
fi

log "5) Initialize accounting objects (quiet idempotent)"
if ! sacctmgr -n show cluster "${CLUSTER_NAME}" format=Cluster 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  sudo sacctmgr -i add cluster "${CLUSTER_NAME}"
fi

if ! sacctmgr -n show account "${DEFAULT_ACCOUNT}" format=Account 2>/dev/null | grep -qx "${DEFAULT_ACCOUNT}"; then
  sudo sacctmgr -i add account "${DEFAULT_ACCOUNT}" Description="Admin"
fi

if ! sacctmgr -n show assoc user="${DEFAULT_USER}" account="${DEFAULT_ACCOUNT}" format=User,Account 2>/dev/null \
      | awk '{print $1,$2}' | grep -qx "${DEFAULT_USER} ${DEFAULT_ACCOUNT}"; then
  sudo sacctmgr -i add user name="${DEFAULT_USER}" account="${DEFAULT_ACCOUNT}" DefaultAccount="${DEFAULT_ACCOUNT}"
fi

sudo scontrol reconfigure || true

log "6) Quick checks"
echo "Services:"
systemctl is-active munge slurmdbd slurmctld slurmd || true
echo
echo "slurmdbd listening:"
sudo ss -lntp | egrep ":${SLURMDBD_PORT}\b|slurmdbd" || true
echo
echo "scontrol ping:"
scontrol ping || true
echo
echo "sinfo -N -l:"
sinfo -N -l || true

log "DONE"
echo "Next: run ./enable_gpu_tres.sh to enable GPU allocation accounting (AccountingStorageTRES)."
