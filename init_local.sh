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

# ---- Helpers ----
log() { echo -e "\n=== $* ==="; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }
}

wait_tcp() {
  local host="$1" port="$2" tries="${3:-30}" sleep_s="${4:-1}"
  for _ in $(seq 1 "$tries"); do
    if nc -vz "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || true)"

log "init_local"
echo "REPO_ROOT=${REPO_ROOT}"
echo "HOST_SHORT=${HOST_SHORT}"
echo "HOST_FQDN=${HOST_FQDN}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"

require_cmd systemctl
require_cmd nc
require_cmd sacctmgr
require_cmd scontrol

log "0) Make /run/slurm persistent + writable (tmpfiles)"
# /run is tmpfs -> recreate on boot
sudo tee /etc/tmpfiles.d/slurm.conf >/dev/null <<EOF
d /run/slurm 0755 slurm slurm -
EOF
sudo systemd-tmpfiles --create

# Ensure dirs exist and ownership is correct now
sudo mkdir -p /run/slurm /var/log/slurm
sudo chown slurm:slurm /run/slurm /var/log/slurm
sudo chmod 0755 /run/slurm

log "1) Ensure MariaDB container is up (if you rely on docker-compose)"
# If you manage DB elsewhere, you can comment this block.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if [[ -f "${REPO_ROOT}/admin/docker-compose.mariadb.yml" ]]; then
    docker compose -f "${REPO_ROOT}/admin/docker-compose.mariadb.yml" up -d
  fi
fi

log "2) Write slurmdbd.conf (host identity + local bind)"
sudo mkdir -p /etc/slurm
sudo tee /etc/slurm/slurmdbd.conf >/dev/null <<EOF
AuthType=auth/munge

# Identity check: MUST match hostname -s (or hostname -f). Use short hostname.
DbdHost=${HOST_SHORT}
# Bind/listen only on loopback for safety
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

log "3) Start munge + slurmdbd (and verify it really listens)"
sudo systemctl enable --now munge
sudo systemctl restart munge

sudo systemctl enable --now slurmdbd
sudo systemctl restart slurmdbd

# IMPORTANT: systemd can say "running" while it is not yet listening.
if ! wait_tcp "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 30 1; then
  echo "ERROR: slurmdbd is not accepting TCP on ${SLURMDBD_ADDR}:${SLURMDBD_PORT}"
  echo "Status:"
  sudo systemctl status slurmdbd --no-pager || true
  echo "Logs:"
  sudo journalctl -u slurmdbd -n 120 --no-pager || true
  exit 1
fi

log "4) Ensure slurm.conf uses accounting_storage/slurmdbd"
# Remove any previous AccountingStorageType/Host lines and re-add deterministic values
sudo sed -i '/^AccountingStorageType=/d;/^AccountingStorageHost=/d' /etc/slurm/slurm.conf

sudo tee -a /etc/slurm/slurm.conf >/dev/null <<EOF

# --- Accounting via slurmdbd ---
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
EOF

log "5) Restart slurmctld/slurmd and verify controller is up"
sudo systemctl restart slurmctld
sudo systemctl restart slurmd

if ! scontrol ping >/dev/null 2>&1; then
  echo "ERROR: slurmctld not reachable after restart"
  sudo systemctl status slurmctld --no-pager || true
  sudo journalctl -u slurmctld -n 120 --no-pager || true
  exit 1
fi

log "6) Initialize accounting objects (cluster/account/user)"
# These are idempotent-ish: cluster add may print "already exists".
sudo sacctmgr -i add cluster "${CLUSTER_NAME}" || true
sudo sacctmgr -i add account "${DEFAULT_ACCOUNT}" Description="Admin" || true
sudo sacctmgr -i add user name="${DEFAULT_USER}" account="${DEFAULT_ACCOUNT}" DefaultAccount="${DEFAULT_ACCOUNT}" || true

# Make sure controller reloads assoc/qos state
sudo scontrol reconfigure || true

log "7) Quick checks"
echo "scontrol ping:"
scontrol ping || true
echo
echo "Accounting config:"
scontrol show config | egrep -i 'AccountingStorageType|AccountingStorageHost|JobAcctGatherType|SelectType' || true
echo
echo "Associations:"
sacctmgr show assoc | head -n 30 || true
echo
echo "slurmdbd listening:"
sudo ss -lntp | egrep "${SLURMDBD_PORT}|slurmdbd" || true

log "DONE"
echo "Next step (after you confirm this init is stable): we will add AccountingStorageTRES with gres/gpu safely."
