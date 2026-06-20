#!/usr/bin/env bash
# install.sh
#
# Run on the air-gapped server after running setup-env.sh.
# Loads Docker images from the bundle and starts OpenFn Lightning.
#
# Prerequisites:
#   - Docker Engine >= 20.10 with Compose v2 plugin
#   - setup-env.sh has been run (creates .env)
#   - All images/ *.tar.gz files are present
#   - SHA256SUMS file is present
#
# This script is SAFE TO RE-RUN if startup fails.
# Images that are already loaded are not re-loaded.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "========================================================"
echo "  OpenFn Lightning — Installer"
echo "========================================================"
echo ""

# ─── Pre-flight checks ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERROR: 'docker' is not found in PATH."
  echo "       Check that Docker Engine is installed: docker --version"
  exit 1
fi

if ! docker compose version &>/dev/null 2>&1; then
  echo "ERROR: Docker Compose v2 plugin is not available."
  echo "       Run: docker compose version"
  echo "       If that fails, install Docker Engine >= 20.10."
  exit 1
fi

if ! docker info &>/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not running."
  echo "       Start it with: sudo systemctl start docker"
  exit 1
fi

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: .env not found at ${ENV_FILE}"
  echo "       Run setup-env.sh first, then re-run this script."
  exit 1
fi

if [ ! -f "${SCRIPT_DIR}/SHA256SUMS" ]; then
  echo "ERROR: SHA256SUMS file not found."
  echo "       The bundle may be incomplete. Re-transfer from the jump host."
  exit 1
fi

# ─── Verify file integrity ────────────────────────────────────────────────────
echo "--> Verifying file integrity (SHA256)..."
cd "${SCRIPT_DIR}"
if ! sha256sum -c SHA256SUMS --quiet 2>/dev/null; then
  echo ""
  echo "ERROR: One or more files failed the checksum check."
  echo "       The bundle was likely corrupted during transfer."
  echo "       Re-transfer the bundle and try again."
  exit 1
fi
echo "    All files OK."
echo ""

# ─── Load Docker images ────────────────────────────────────────────────────────
# We check if the image is already loaded to make the script idempotent.
load_image() {
  local label="$1"
  local tar_file="$2"
  local image_ref="$3"

  if docker image inspect "${image_ref}" &>/dev/null 2>&1; then
    echo "    [skip] ${label} — already loaded."
  else
    echo "    [load] ${label}..."
    docker load < "${tar_file}"
  fi
}

echo "--> Loading Docker images (this may take a few minutes)..."
load_image "PostgreSQL 15.12"          "images/postgres.tar.gz"    "postgres:15.12-alpine"
load_image "Lightning v2.16.7"         "images/lightning.tar.gz"   "ghcr.io/openfn/lightning:v2.16.7"
load_image "ws-worker"                 "images/ws-worker.tar.gz"   "openfn/ws-worker:latest"
echo ""

# ─── Start Postgres first and wait for it to be healthy ───────────────────────
echo "--> Starting PostgreSQL..."
docker compose -f "${COMPOSE_FILE}" up -d postgres
echo "    Waiting for PostgreSQL to be ready (up to 60 seconds)..."

_healthy=false
for _i in $(seq 1 12); do
  _pg_status=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Health}}' postgres 2>/dev/null || echo "unknown")
  if [ "${_pg_status}" = "healthy" ]; then
    _healthy=true
    break
  fi
  echo "    ... attempt ${_i}/12 (status: ${_pg_status})"
  sleep 5
done

if [ "${_healthy}" = "false" ]; then
  echo ""
  echo "ERROR: PostgreSQL did not become healthy within 60 seconds."
  echo "       Check logs: docker compose -f ${COMPOSE_FILE} logs postgres"
  exit 1
fi
echo "    PostgreSQL is healthy."
echo ""

# ─── Run database migrations ──────────────────────────────────────────────────
# 'docker compose run' inherits the full service environment (env_file + environment: block),
# so DATABASE_URL, SECRET_KEY_BASE, etc. are all automatically available.
echo "--> Running database migrations..."
docker compose -f "${COMPOSE_FILE}" run --rm web /app/bin/lightning eval "Lightning.Release.migrate()"
echo "    Migrations complete."
echo ""

# ─── Start all remaining services ─────────────────────────────────────────────
echo "--> Starting Lightning web and worker services..."
docker compose -f "${COMPOSE_FILE}" up -d
echo ""

# ─── Wait for web healthcheck ─────────────────────────────────────────────────
echo "--> Waiting for Lightning web to become healthy (up to 3 minutes)..."
_healthy=false
for _i in $(seq 1 18); do
  _web_status=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Health}}' web 2>/dev/null || echo "unknown")
  if [ "${_web_status}" = "healthy" ]; then
    _healthy=true
    break
  fi
  echo "    ... attempt ${_i}/18 (status: ${_web_status})"
  sleep 10
done

echo ""
if [ "${_healthy}" = "true" ]; then
  echo "========================================================"
  echo "  Installation complete!"
  echo ""
  echo "  Run ./verify.sh to confirm everything is working."
  echo "========================================================"
else
  echo "========================================================"
  echo "  WARNING: Web container did not report healthy in time."
  echo ""
  echo "  This can be normal on first boot (database initialising)."
  echo "  Wait 2 more minutes and run ./verify.sh"
  echo ""
  echo "  If verify.sh still fails, check logs:"
  echo "    docker compose -f ${COMPOSE_FILE} logs --tail=50 web"
  echo "========================================================"
fi
