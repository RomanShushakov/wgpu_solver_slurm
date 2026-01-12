#!/usr/bin/env bash
set -euo pipefail

SLURMDBD_PORT="${SLURMDBD_PORT:-6819}"
SLURMDBD_ADDR="${SLURMDBD_ADDR:-127.0.0.1}"

log() { echo -e "\n=== $* ==="; }

wait_tcp4() {
  local host="$1" port="$2" tries="${3:-20}" sleep_s="${4:-1}"
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
if ! wait_tcp4 "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 20 1; then
  echo "ERROR: slurmdbd not reachable on ${SLURMDBD_ADDR}:${SLURMDBD_PORT}"
  echo "--- slurmdbd status ---"
  sudo systemctl status slurmdbd --no-pager || true
  echo "--- slurmdbd journal ---"
  sudo journalctl -u slurmdbd -n 120 --no-pager || true
  echo "--- ss listeners ---"
  sudo ss -lntp | egrep ":${SLURMDBD_PORT}\b|slurmdbd" || true
  exit 1
fi

log "2) Set AccountingStorageTRES (GPU) in slurm.conf"
# Keep it minimal first. You can extend later once it's stable.
sudo sed -i '/^AccountingStorageTRES=/d' /etc/slurm/slurm.conf

sudo tee -a /etc/slurm/slurm.conf >/dev/null <<'EOF'

# --- TRES stored in accounting DB (enable GPU accounting) ---
AccountingStorageTRES=cpu,mem,node,billing,gres/gpu
EOF

log "3) Restart slurmctld (this is where TRES rows may be created)"
# Re-check slurmdbd right before restarting controller.
if ! wait_tcp4 "${SLURMDBD_ADDR}" "${SLURMDBD_PORT}" 10 1; then
  echo "ERROR: slurmdbd became unreachable right before restarting slurmctld. Aborting."
  exit 1
fi

sudo systemctl restart slurmctld
sudo systemctl restart slurmd

log "4) Validate"
scontrol ping || true
scontrol show config | egrep -i 'AccountingStorageType|AccountingStorageHost|AccountingStorageTRES' || true

log "DONE"
echo "If this is stable, we can expand AccountingStorageTRES to include gpumem/gpuutil later."
