#!/usr/bin/env bash
set -euo pipefail

# Optional toggles:
#   PURGE_DOCKER=1        -> stop/remove mariadb compose + container
#   PURGE_DOCKER_VOLUME=1 -> also delete mariadb volume (DESTROYS DB DATA)
#   PURGE_USERS=1         -> remove demo linux users you created (user1 etc.)
#
# Example:
#   PURGE_DOCKER=1 PURGE_DOCKER_VOLUME=1 PURGE_USERS=1 bash purge_local.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${REPO_ROOT}/admin/docker-compose.mariadb.yml"

PURGE_DOCKER="${PURGE_DOCKER:-0}"
PURGE_DOCKER_VOLUME="${PURGE_DOCKER_VOLUME:-0}"
PURGE_USERS="${PURGE_USERS:-0}"
PURGE_ACCOUNTING="${PURGE_ACCOUNTING:-0}"

echo "=== purge_local (vultr) ==="
echo "REPO_ROOT=${REPO_ROOT}"
echo "PURGE_DOCKER=${PURGE_DOCKER}"
echo "PURGE_DOCKER_VOLUME=${PURGE_DOCKER_VOLUME}"
echo "PURGE_USERS=${PURGE_USERS}"
echo "PURGE_ACCOUNTING=${PURGE_ACCOUNTING}"
echo "==========================="

echo "[1/10] Stop services (ignore failures)..."
sudo systemctl stop slurmctld slurmd slurmdbd munge 2>/dev/null || true
sudo systemctl disable slurmctld slurmd slurmdbd munge 2>/dev/null || true

echo "[2/10] Kill any remaining slurm daemons (best-effort)..."
sudo pkill -x slurmctld 2>/dev/null || true
sudo pkill -x slurmd    2>/dev/null || true
sudo pkill -x slurmdbd  2>/dev/null || true
sudo pkill -x munged    2>/dev/null || true

if [[ "${PURGE_DOCKER}" == "1" ]]; then
  echo "[3/10] Stop/remove MariaDB container (docker compose)..."
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if [[ -f "${COMPOSE_FILE}" ]]; then
      if [[ "${PURGE_DOCKER_VOLUME}" == "1" ]]; then
        docker compose -f "${COMPOSE_FILE}" down -v || true
      else
        docker compose -f "${COMPOSE_FILE}" down || true
      fi
    fi
    docker rm -f slurm-mariadb 2>/dev/null || true
  else
    echo "  (docker not installed; skipping)"
  fi
else
  echo "[3/10] Docker purge disabled (skipping MariaDB container cleanup)"
fi

echo "[4/10] Purge packages (Slurm/Munge/Apptainer + optional accounting)..."

# Always remove Slurm + Munge when purging cluster
sudo apt-get purge -y \
  slurm-wlm slurmctld slurmd slurm-client \
  munge libmunge2 \
  || true

# Read StateSaveLocation from slurm.conf if present, otherwise default
STATE_DIR="$(awk -F= '/^StateSaveLocation=/{print $2}' /etc/slurm/slurm.conf 2>/dev/null | tail -n1)"
STATE_DIR="${STATE_DIR:-/var/spool/slurmctld}"

# Wipe Slurm state so job IDs reset
sudo rm -rf "$STATE_DIR" /var/spool/slurmctld /var/spool/slurmd /var/lib/slurm 2>/dev/null || true

# Recreate required dirs with correct ownership (so init doesn’t fail later)
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /run/slurm
sudo chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /run/slurm
sudo chmod 0755 /var/log/slurm /run/slurm

# Always remove slurmdbd + mysql plugin (we reinstall deterministically)
sudo apt-get purge -y slurmdbd slurm-wlm-mysql-plugin || true
sudo rm -f /etc/slurm/slurmdbd.conf || true

# Never purge mariadb packages (we use Docker). If they exist, user already removed them manually.

# Apptainer may have been installed from a .deb and might not be in apt indexes.
if dpkg -s apptainer >/dev/null 2>&1; then
  sudo dpkg -P apptainer || true
fi

# Some older setups might still use singularity
if dpkg -s singularity-container >/dev/null 2>&1; then
  sudo dpkg -P singularity-container || true
fi

echo "[5/10] Remove configs/state/logs..."
sudo rm -rf \
  /etc/slurm /etc/munge /etc/apptainer /usr/local/etc/apptainer \
  /var/lib/slurm /var/spool/slurm /run/slurm /run/slurm* \
  /var/log/slurm /var/log/slurm* /var/log/slurmctld.log /var/log/slurmd.log /var/log/slurmdbd.log \
  /var/lib/munge /run/munge /var/log/munge \
  || true

# Remove systemd drop-ins (critical to avoid stale RuntimeDirectory/User overrides)
sudo rm -rf /etc/systemd/system/slurmdbd.service.d \
            /etc/systemd/system/slurmctld.service.d \
            /etc/systemd/system/slurmd.service.d || true

# Remove possible tmpfiles override (you already do this)
sudo rm -f /etc/tmpfiles.d/slurm.conf || true

# Reload systemd so removed drop-ins take effect
sudo systemctl daemon-reload || true
sudo systemctl reset-failed slurmdbd slurmctld slurmd munge 2>/dev/null || true

echo "[6/10] Remove apptainer caches (root + current user best-effort)..."
for home in /root "/home/${SUDO_USER:-}" "${HOME}"; do
  if [[ -n "${home}" && -d "${home}" ]]; then
    sudo rm -rf \
      "${home}/.apptainer" "${home}/.singularity" \
      "${home}/.cache/apptainer" "${home}/.cache/singularity" \
      "${home}/.local/share/apptainer" "${home}/.local/share/singularity" \
      2>/dev/null || true
  fi
done

if [[ "${PURGE_USERS}" == "1" ]]; then
  echo "[7/10] Remove demo Linux users (best-effort)..."
  for u in user1 user2 user3; do
    if id "${u}" >/dev/null 2>&1; then
      sudo userdel -r "${u}" 2>/dev/null || sudo userdel "${u}" 2>/dev/null || true
    fi
  done
else
  echo "[7/10] User purge disabled (skipping Linux user removal)"
fi

echo "[8/10] Autoremove + clean..."
sudo apt-get autoremove -y || true
sudo apt-get autoclean -y || true

echo "[9/10] Recreate proper folder for gpu metrics"
sudo rm -rf /var/log/slurm/gpu-metrics 2>/dev/null || true
sudo install -d -m 1777 /var/log/slurm/gpu-metrics

echo "[10/10] Done."
echo "Verify:"
echo "  dpkg -l | grep -E 'slurm|munge|apptainer|singularity' || true"
if [[ "${PURGE_DOCKER}" == "1" ]]; then
  echo "  docker ps -a | grep -E 'slurm-mariadb' || true"
fi
echo "GPU driver should still be present:"
echo "  nvidia-smi || true"
