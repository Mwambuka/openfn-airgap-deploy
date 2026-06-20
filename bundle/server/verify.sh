#!/usr/bin/env bash
# verify.sh
#
# Run after install.sh to confirm OpenFn Lightning is fully operational.
# Each check prints [PASS] or [FAIL] with a clear reason.
# The script exits 0 only if all checks pass.
#
# Usage (from the bundle directory):
#   ./verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"

PASS=0
FAIL=0
FAIL_MESSAGES=()

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); FAIL_MESSAGES+=("$1"); }

# ─── Load site config from .env ───────────────────────────────────────────────
if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: .env not found. Run setup-env.sh and install.sh first."
  exit 1
fi

# Read only the variables we need (avoid sourcing secrets into the shell broadly)
_PORT=$(grep '^LIGHTNING_PORT=' "${ENV_FILE}" | cut -d= -f2)
_PORT="${_PORT:-4000}"
_HOST=$(grep '^URL_HOST='      "${ENV_FILE}" | cut -d= -f2)
_HOST="${_HOST:-localhost}"
_SCHEME=$(grep '^URL_SCHEME='   "${ENV_FILE}" | cut -d= -f2)
_SCHEME="${_SCHEME:-http}"

echo "========================================================"
echo "  OpenFn Lightning — Verification"
echo "  Checking: ${_SCHEME}://${_HOST}:${_PORT}"
echo "========================================================"
echo ""

# ─── Check 1: PostgreSQL container running ────────────────────────────────────
_pg_status=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.State}}' postgres 2>/dev/null || echo "error")
if [ "${_pg_status}" = "running" ]; then
  pass "PostgreSQL container is running"
else
  fail "PostgreSQL container is NOT running (state: ${_pg_status})"
fi

# ─── Check 2: PostgreSQL is healthy (accepting connections) ───────────────────
_pg_health=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Health}}' postgres 2>/dev/null || echo "unknown")
if [ "${_pg_health}" = "healthy" ]; then
  pass "PostgreSQL is accepting connections (healthcheck passed)"
else
  fail "PostgreSQL healthcheck not passing (state: ${_pg_health})"
fi

# ─── Check 3: Lightning web container running ─────────────────────────────────
_web_status=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.State}}' web 2>/dev/null || echo "error")
if [ "${_web_status}" = "running" ]; then
  pass "Lightning web container is running"
else
  fail "Lightning web container is NOT running (state: ${_web_status})"
fi

# ─── Check 4: Lightning web is healthy ───────────────────────────────────────
_web_health=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Health}}' web 2>/dev/null || echo "unknown")
if [ "${_web_health}" = "healthy" ]; then
  pass "Lightning web healthcheck passed"
else
  fail "Lightning web healthcheck NOT passing (state: ${_web_health})"
fi

# ─── Check 5: Worker container running ────────────────────────────────────────
_wk_status=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.State}}' worker 2>/dev/null || echo "error")
if [ "${_wk_status}" = "running" ]; then
  pass "Worker container is running"
else
  fail "Worker container is NOT running (state: ${_wk_status})"
fi

# ─── Check 6: HTTP health endpoint returns 200 ────────────────────────────────
_http_code=$(curl -so /dev/null -w "%{http_code}" --max-time 10 \
  "http://localhost:${_PORT}/health_check" 2>/dev/null || echo "000")
if [ "${_http_code}" = "200" ]; then
  pass "HTTP /health_check returns 200 OK"
else
  fail "HTTP /health_check returned ${_http_code} (expected 200)"
fi

# ─── Check 7: Login page is reachable ─────────────────────────────────────────
_login_code=$(curl -so /dev/null -w "%{http_code}" --max-time 10 \
  "http://localhost:${_PORT}/users/log_in" 2>/dev/null || echo "000")
if [ "${_login_code}" = "200" ]; then
  pass "Login page /users/log_in returns 200 OK"
else
  fail "Login page /users/log_in returned ${_login_code} (expected 200)"
fi

# ─── Check 8: No containers in a restart/crash loop ───────────────────────────
_restarting=$(docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null | grep -c "restarting" || echo "0")
if [ "${_restarting}" -eq 0 ]; then
  pass "No containers are in a crash/restart loop"
else
  fail "${_restarting} container(s) are stuck in a restart loop"
fi

# ─── Check 9: Disk space (warn if < 5 GB free) ────────────────────────────────
_avail_gb=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
if [ "${_avail_gb:-0}" -ge 5 ]; then
  pass "Disk space OK (${_avail_gb} GB free on /)"
else
  fail "Low disk space: only ${_avail_gb:-?} GB free on / (recommend >= 5 GB)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
TOTAL=$((PASS + FAIL))
if [ "${FAIL}" -eq 0 ]; then
  echo "  RESULT: ALL ${PASS} CHECKS PASSED"
  echo ""
  echo "  OpenFn Lightning is running and ready to use."
  echo ""
  echo "  Open this URL in a web browser on any ministry computer:"
  echo "    ${_SCHEME}://${_HOST}:${_PORT}"
  echo ""
  echo "  You will see a login page. An administrator must create the"
  echo "  first user account via the API or by enabling ALLOW_SIGNUP"
  echo "  temporarily in .env, then restarting: docker compose restart web"
  echo "========================================================"
  exit 0
else
  echo "  RESULT: ${FAIL} of ${TOTAL} CHECKS FAILED"
  echo ""
  echo "  Failed checks:"
  for _msg in "${FAIL_MESSAGES[@]}"; do
    echo "    - ${_msg}"
  done
  echo ""
  echo "  Diagnose with:"
  echo "    docker compose -f ${COMPOSE_FILE} ps"
  echo "    docker compose -f ${COMPOSE_FILE} logs --tail=50 web"
  echo "    docker compose -f ${COMPOSE_FILE} logs --tail=50 postgres"
  echo ""
  echo "  See RUNBOOK.md — Troubleshooting for step-by-step guidance."
  echo "========================================================"
  exit 1
fi
