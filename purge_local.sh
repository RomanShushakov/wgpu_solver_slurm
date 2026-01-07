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

echo "=== purge_local ==="
echo "REPO_ROOT=${REPO_ROOT}"
echo "PURGE_DOCKER=${PURGE_DOCKER}"
echo "PURGE_DOCKER_VOLUME=${PURGE_DOCKER_VOLUME}"
echo "PURGE_USERS=${PURGE_USERS}"
echo "==================="

echo "[1/9] Stop services (ignore failures)..."
sudo systemctl stop slurmctld slurmd slurmdbd munge 2>/dev/null || true
sudo systemctl disable slurmctld slurmd slurmdbd munge 2>/dev/null || true

echo "[2/9] Kill any remaining slurm daemons (best-effort)..."
sudo pkill -x slurmctld 2>/dev/null || true
sudo pkill -x slurmd    2>/dev/null || true
sudo pkill -x slurmdbd  2>/dev/null || true
sudo pkill -x munged    2>/dev/null || true

if [[ "${PURGE_DOCKER}" == "1" ]]; then
  echo "[3/9] Stop/remove MariaDB container (docker compose)..."
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if [[ -f "${COMPOSE_FILE}" ]]; then
      if [[ "${PURGE_DOCKER_VOLUME}" == "1" ]]; then
        docker compose -f "${COMPOSE_FILE}" down -v || true
      else
        docker compose -f "${COMPOSE_FILE}" down || true
      fi
    fi
    # extra safety if compose file moved/renamed
    docker rm -f slurm-mariadb 2>/dev/null || true
  else
    echo "  (docker not installed; skipping)"
  fi
else
  echo "[3/9] Docker purge disabled (skipping MariaDB container cleanup)"
fi

echo "[4/9] Purge packages..."
sudo apt-get purge -y \
  slurm-wlm slurmctld slurmd slurm-client slurmdbd \
  munge libmunge2 \
  apptainer \
  mariadb-client \
  || true

echo "[5/9] Remove configs/state/logs..."
sudo rm -rf \
  /etc/slurm /etc/munge /etc/apptainer /usr/local/etc/apptainer \
  /var/lib/slurm /var/spool/slurm /run/slurm /run/slurm* \
  /var/log/slurm /var/log/slurm* /var/log/slurmctld.log /var/log/slurmd.log /var/log/slurmdbd.log \
  /var/lib/munge /run/munge /var/log/munge \
  || true

echo "[6/9] Remove apptainer caches (root + current user best-effort)..."
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
  echo "[7/9] Remove demo Linux users (best-effort)..."
  for u in user1; do
    if id "${u}" >/dev/null 2>&1; then
      sudo userdel -r "${u}" 2>/dev/null || sudo userdel "${u}" 2>/dev/null || true
    fi
  done
else
  echo "[7/9] User purge disabled (skipping Linux user removal)"
fi

echo "[8/9] Autoremove + clean..."
sudo apt-get autoremove -y || true
sudo apt-get autoclean -y || true

echo "[9/9] Done."
echo "Verify:"
echo "  dpkg -l | grep -E 'slurm|munge|apptainer|singularity' || true"
if [[ "${PURGE_DOCKER}" == "1" ]]; then
  echo "  docker ps -a | grep -E 'slurm-mariadb' || true"
fi
