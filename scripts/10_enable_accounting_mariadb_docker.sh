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

echo "=== Step 10: MariaDB (Docker) for Slurm accounting ==="
echo "REPO_ROOT=${REPO_ROOT}"
echo "COMPOSE_FILE=${COMPOSE_FILE}"
echo "DB_HOST=${DB_HOST}"
echo "DB_PORT=${DB_PORT}"
echo "DB_NAME=${DB_NAME}"
echo "DB_USER=${DB_USER}"
echo "======================================================"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: Compose file not found: ${COMPOSE_FILE}"
  echo "Create it at admin/docker-compose.mariadb.yml"
  exit 2
fi

# 1) Ensure docker exists
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. Install Docker first."
  echo "On Ubuntu: sudo apt-get install -y docker.io docker-compose-plugin"
  exit 2
fi

# 2) Ensure compose plugin exists (docker compose)
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' plugin not found."
  echo "Install: sudo apt-get install -y docker-compose-plugin"
  exit 2
fi

# 3) Bring up MariaDB
echo "[1/3] Starting MariaDB container..."
docker compose -f "${COMPOSE_FILE}" up -d

# 4) Wait for healthcheck
echo "[2/3] Waiting for MariaDB healthcheck..."
for i in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' slurm-mariadb 2>/dev/null || true)"
  if [[ "${status}" == "healthy" ]]; then
    echo "MariaDB is healthy."
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: MariaDB did not become healthy."
    echo "Logs:"
    docker logs --tail 200 slurm-mariadb || true
    exit 1
  fi
  sleep 2
done

# 5) Quick connectivity check (using mysql client inside container)
echo "[3/3] Verifying DB exists and user can connect..."
docker exec -i slurm-mariadb mariadb -u"${DB_USER}" -p"${DB_PASS}" -e "SHOW DATABASES LIKE '${DB_NAME}';" >/dev/null

echo
echo "OK: MariaDB is running and reachable at ${DB_HOST}:${DB_PORT}"
echo "Next step: configure slurmdbd to use this database (scripts/11_configure_slurmdbd.sh)."
