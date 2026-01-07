#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/admin/docker-compose.mariadb.yml"

# Allow overrides via env vars (useful for Pi/Vultr later)
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-slurm_acct_db}"
DB_USER="${DB_USER:-slurm}"
DB_PASS="${DB_PASS:-slurmpass_change_me}"

# Root password used inside container for bootstrap
DB_ROOT_PASS="${DB_ROOT_PASS:-${MARIADB_ROOT_PASSWORD:-}}"

CONTAINER_NAME="${CONTAINER_NAME:-slurm-mariadb}"

echo "=== Step 10: MariaDB (Docker) for Slurm accounting ==="
echo "REPO_ROOT=${REPO_ROOT}"
echo "COMPOSE_FILE=${COMPOSE_FILE}"
echo "CONTAINER_NAME=${CONTAINER_NAME}"
echo "DB_HOST=${DB_HOST}"
echo "DB_PORT=${DB_PORT}"
echo "DB_NAME=${DB_NAME}"
echo "DB_USER=${DB_USER}"
echo "======================================================"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: Compose file not found: ${COMPOSE_FILE}"
  exit 2
fi

# 1) Ensure docker exists
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found; installing docker.io + compose plugin..."
  sudo apt-get update
  sudo apt-get install -y docker.io docker-compose-plugin
  sudo systemctl enable --now docker
fi

# 2) Ensure compose plugin exists (docker compose)
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' plugin not found."
  echo "Install: sudo apt-get install -y docker-compose-plugin"
  exit 2
fi

# 3) Bring up MariaDB
echo "[1/4] Starting MariaDB container..."
docker compose -f "${COMPOSE_FILE}" up -d

# 4) Wait until DB responds (healthcheck if present, otherwise ping loop)
echo "[2/4] Waiting for MariaDB readiness..."
for i in $(seq 1 90); do
  health="$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
  if [[ "${health}" == "healthy" ]]; then
    echo "MariaDB is healthy."
    break
  fi

  # If no healthcheck, try a simple ping
  if docker exec "${CONTAINER_NAME}" sh -lc "mariadb-admin ping --silent >/dev/null 2>&1"; then
    echo "MariaDB responds to ping."
    break
  fi

  if [[ "${i}" -eq 90 ]]; then
    echo "ERROR: MariaDB did not become ready."
    echo "Logs:"
    docker logs --tail 200 "${CONTAINER_NAME}" || true
    exit 1
  fi
  sleep 2
done

# 5) Bootstrap DB/user (idempotent)
echo "[3/4] Bootstrapping database + user (idempotent)..."

if [[ -z "${DB_ROOT_PASS}" ]]; then
  echo "ERROR: DB_ROOT_PASS is empty."
  echo "Set DB_ROOT_PASS (or MARIADB_ROOT_PASSWORD) to the root password used in docker-compose.mariadb.yml."
  exit 2
fi

docker exec -i "${CONTAINER_NAME}" sh -lc "mariadb -uroot -p'${DB_ROOT_PASS}' -e \
\"CREATE DATABASE IF NOT EXISTS \\\`${DB_NAME}\\\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \\\`${DB_NAME}\\\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;\""

# 6) Connectivity check with target user
echo "[4/4] Verifying DB/user can connect..."
docker exec -i "${CONTAINER_NAME}" sh -lc "mariadb -u'${DB_USER}' -p'${DB_PASS}' -e \"SHOW DATABASES LIKE '${DB_NAME}';\" >/dev/null"

echo
echo "OK: MariaDB is running and bootstrapped."
echo "Next step: scripts/11_configure_slurmdbd.sh"
