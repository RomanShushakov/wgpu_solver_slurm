#!/usr/bin/env bash
set -euo pipefail

SLURMDBD_PORT="${SLURMDBD_PORT:-6819}"
SLURMDBD_ADDR="${SLURMDBD_ADDR:-127.0.0.1}"

log() { echo -e "\n=== $* ==="; }

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

log "0) Preconditions"
if [[ ! -f /etc/slurm/slurm.conf ]]; then
  echo "ERROR: /etc/slurm/slurm.conf not found. Run ./init_local.sh first."
  exit 1
fi

log "1) Verify slurmdbd is reachable (hard requirement)"
if ! wait_tcp4 "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 60 1; then
  echo "ERROR: slurmdbd not reachable on ${SLURMDBD_ADDR}:${SLURMDBD_PORT}"
  sudo systemctl status slurmdbd --no-pager || true
  sudo journalctl -u slurmdbd -n 200 --no-pager || true
  sudo ss -lntp | egrep ":${SLURMDBD_PORT}\b|slurmdbd" || true
  exit 1
fi

log "2) Set AccountingStorageTRES in slurm.conf (GPU allocation accounting)"
sudo sed -i '/^AccountingStorageTRES=/d' /etc/slurm/slurm.conf

sudo tee -a /etc/slurm/slurm.conf >/dev/null <<'EOF'

# TRES stored in accounting DB (enable GPU allocation accounting)
AccountingStorageTRES=cpu,mem,node,billing,gres/gpu
EOF

log "3) Restart slurmctld + slurmd"
# Guard again right before restart (prevents slurmctld fatal if DB drops)
if ! wait_tcp4 "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 30 1; then
  echo "ERROR: slurmdbd became unreachable right before restarting slurmctld. Aborting."
  exit 1
fi

sudo systemctl restart slurmctld
sudo systemctl restart slurmd

log "4) Validate"
scontrol ping || true
scontrol show config | egrep -i 'AccountingStorageType|AccountingStorageHost|AccountingStorageTRES' || true

log "DONE"
