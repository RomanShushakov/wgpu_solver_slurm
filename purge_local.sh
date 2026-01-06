#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Stop services (ignore failures)..."
systemctl stop slurmctld slurmd munge 2>/dev/null || true
systemctl disable slurmctld slurmd munge 2>/dev/null || true

echo "[2/6] Purge packages..."
sudo apt-get purge -y \
  slurm-wlm slurmctld slurmd slurm-client slurmdbd \
  munge libmunge2 \
  apptainer \
  || true

echo "[3/6] Remove configs/state/logs..."
sudo rm -rf \
  /etc/slurm /etc/munge /etc/apptainer /usr/local/etc/apptainer \
  /var/lib/slurm /var/spool/slurm /var/log/slurm* /run/slurm* \
  /var/lib/munge /run/munge /var/log/munge \
  || true

echo "[4/6] Remove apptainer caches (root + current user best-effort)..."
for home in /root "/home/${SUDO_USER:-}"; do
  if [[ -n "$home" && -d "$home" ]]; then
    sudo rm -rf \
      "$home/.apptainer" "$home/.singularity" \
      "$home/.cache/apptainer" "$home/.cache/singularity" \
      "$home/.local/share/apptainer" "$home/.local/share/singularity" \
      2>/dev/null || true
  fi
done

echo "[5/6] Autoremove + clean..."
sudo apt-get autoremove -y || true
sudo apt-get autoclean -y || true

echo "[6/6] Done."
echo "Verify:"
echo "  dpkg -l | grep -E 'slurm|munge|apptainer|singularity' || true"
