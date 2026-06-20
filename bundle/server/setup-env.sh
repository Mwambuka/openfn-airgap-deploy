#!/usr/bin/env bash
# setup-env.sh
#
# Run ONCE on the air-gapped server to generate all required secrets and
# create the .env configuration file.
#
# Prerequisites: openssl, base64 (both available on Ubuntu 22.04 by default)
# Run from the directory containing docker-compose.yml.
#
# Usage:
#   cd /opt/openfn
#   ./setup-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "========================================================"
echo "  OpenFn Lightning — First-Time Configuration"
echo "========================================================"
echo ""

# Guard: don't silently overwrite an existing config
if [ -f "${ENV_FILE}" ]; then
  echo "WARNING: ${ENV_FILE} already exists."
  echo "         Re-running this script generates NEW secrets, which means:"
  echo "         - Existing user sessions will be invalidated"
  echo "         - Encrypted credentials will become unreadable unless you"
  echo "           restore the old PRIMARY_ENCRYPTION_KEY"
  echo "         - If the Postgres password changes, the database won't start"
  echo "           (see RUNBOOK.md — Failure Scenario)"
  echo ""
  read -r -p "Are you sure you want to overwrite? [y/N] " _answer
  case "${_answer}" in
    [yY]) rm -f "${ENV_FILE}" ;;
    *) echo "Aborted. Existing .env left unchanged."; exit 0 ;;
  esac
  echo ""
fi

# ─── Collect site-specific values interactively ───────────────────────────────
echo "Answer the questions below. Press Enter to accept the default."
echo ""

read -r -p "Server IP address or hostname (e.g. 192.168.1.100): " _url_host
while [ -z "${_url_host}" ]; do
  echo "  This cannot be empty — users need it to open Lightning in their browser."
  read -r -p "Server IP address or hostname: " _url_host
done

read -r -p "Port users will connect on [default: 4000]: " _url_port
_url_port="${_url_port:-4000}"

read -r -p "Protocol — http or https [default: http]: " _url_scheme
_url_scheme="${_url_scheme:-http}"

read -r -p "Admin e-mail address (used as system sender, e.g. it@ministry.gov): " _email_admin
while [ -z "${_email_admin}" ]; do
  echo "  This cannot be empty."
  read -r -p "Admin e-mail address: " _email_admin
done

echo ""
echo "--> Generating cryptographic secrets (using openssl — no internet needed)..."

SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
PRIMARY_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '\n=/+' | head -c 32)

echo "    SECRET_KEY_BASE          generated (64 random bytes, base64)"
echo "    PRIMARY_ENCRYPTION_KEY   generated (32 random bytes, base64)"
echo "    POSTGRES_PASSWORD        generated"

echo ""
echo "--> Generating RSA keypair for worker authentication..."

_TMPDIR=$(mktemp -d)
trap 'rm -rf "${_TMPDIR}"' EXIT

openssl genrsa -out "${_TMPDIR}/lightning_private.pem" 4096 2>/dev/null
openssl rsa \
  -in  "${_TMPDIR}/lightning_private.pem" \
  -pubout \
  -out "${_TMPDIR}/lightning_public.pem" 2>/dev/null

WORKER_RUNS_PRIVATE_KEY=$(base64 -w 0 < "${_TMPDIR}/lightning_private.pem")
WORKER_LIGHTNING_PUBLIC_KEY=$(base64 -w 0 < "${_TMPDIR}/lightning_public.pem")
WORKER_SECRET=$(openssl rand -base64 32 | tr -d '\n')

echo "    WORKER_RUNS_PRIVATE_KEY  generated (RSA-4096 private key, base64)"
echo "    WORKER_LIGHTNING_PUBLIC_KEY  generated (RSA-4096 public key, base64)"
echo "    WORKER_SECRET            generated (256-bit shared secret)"
echo ""

# ─── Write .env ───────────────────────────────────────────────────────────────
cat > "${ENV_FILE}" <<EOF
# OpenFn Lightning — Environment Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# *** KEEP THIS FILE SECURE ***
# - Do not paste its contents into chat tools or emails.
# - Back up this file offline (encrypted USB or printed and locked away).
# - If PRIMARY_ENCRYPTION_KEY is lost, credential data cannot be recovered.

# ── Site identity ────────────────────────────────────────────────────────────
URL_HOST=${_url_host}
URL_PORT=${_url_port}
URL_SCHEME=${_url_scheme}

# The host port that Lightning will listen on (maps to internal port 4000)
LIGHTNING_PORT=${_url_port}

# ── Core secrets ─────────────────────────────────────────────────────────────
# SECRET_KEY_BASE signs cookies and tokens. Rotating this logs everyone out.
SECRET_KEY_BASE=${SECRET_KEY_BASE}

# PRIMARY_ENCRYPTION_KEY encrypts credentials stored in the database.
# Rotating this WITHOUT migrating existing data will make credentials unreadable.
PRIMARY_ENCRYPTION_KEY=${PRIMARY_ENCRYPTION_KEY}

# ── Database ─────────────────────────────────────────────────────────────────
# This password is set when Postgres first initialises the data volume.
# Changing it later requires updating Postgres as well (see RUNBOOK.md).
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# ── Worker authentication ─────────────────────────────────────────────────────
# These three values must be generated together and kept in sync.
WORKER_RUNS_PRIVATE_KEY=${WORKER_RUNS_PRIVATE_KEY}
WORKER_LIGHTNING_PUBLIC_KEY=${WORKER_LIGHTNING_PUBLIC_KEY}
WORKER_SECRET=${WORKER_SECRET}

# ── Application behaviour ─────────────────────────────────────────────────────
# Disable public sign-up — new users must be invited by an admin.
ALLOW_SIGNUP=false

# Disable usage telemetry — this server has no outbound internet.
USAGE_TRACKING_ENABLED=false

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_LEVEL=info

# ── Email ─────────────────────────────────────────────────────────────────────
# 'local' queues emails without sending — safe default for an air-gapped server.
# Change to 'smtp' and add SMTP_* variables if you have an internal mail server.
MAIL_PROVIDER=local
EMAIL_ADMIN=${_email_admin}
EOF

chmod 600 "${ENV_FILE}"

echo "========================================================"
echo "  .env created at: ${ENV_FILE}"
echo ""
echo "  IMPORTANT — Back up this file NOW:"
echo "    cp ${ENV_FILE} /path/to/secure/usb/openfn-env.bak"
echo ""
echo "  If this file is lost, credential data cannot be recovered."
echo "========================================================"
echo ""
echo "Next step: run ./install.sh"
