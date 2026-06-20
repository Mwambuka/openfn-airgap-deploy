#!/usr/bin/env bash
# build-bundle.sh
#
# Run on an internet-connected machine (your laptop or the jump host) to produce
# a self-contained tarball that can be transferred to the air-gapped server.
#
# Prerequisites on this machine:
#   - Docker Engine running (any recent version)
#   - gzip, sha256sum (Linux) or shasum (macOS)
#   - ~10 GB free disk space for images
#
# Output (in the repo root):
#   openfn-lightning-bundle-v2.16.7.tar.gz        -- the bundle
#   openfn-lightning-bundle-v2.16.7.tar.gz.sha256 -- outer checksum (for transfer integrity)
#
# Usage:
#   cd openfn-airgap-deploy
#   ./bundle/build-bundle.sh

set -euo pipefail

# ─── Pinned versions ──────────────────────────────────────────────────────────
LIGHTNING_VERSION="v2.16.7"
LIGHTNING_IMAGE="ghcr.io/openfn/lightning:${LIGHTNING_VERSION}"
WORKER_IMAGE="openfn/ws-worker:latest"
POSTGRES_IMAGE="postgres:15.12-alpine"

BUNDLE_NAME="openfn-lightning-bundle-${LIGHTNING_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}"

# ─── sha256 compatibility shim (Linux vs macOS) ───────────────────────────────
sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$@"
  else
    # macOS
    shasum -a 256 "$@"
  fi
}

echo "========================================================"
echo "  OpenFn Lightning — Air-Gap Bundle Builder"
echo "  Lightning version : ${LIGHTNING_VERSION}"
echo "  ws-worker         : ${WORKER_IMAGE}"
echo "  PostgreSQL        : ${POSTGRES_IMAGE}"
echo "========================================================"
echo ""

# ─── Pre-flight checks ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERROR: 'docker' not found. Install Docker Engine and try again."
  exit 1
fi

if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon is not running. Start it and try again."
  exit 1
fi

# Require at least 10 GB free in output dir
AVAIL_KB=$(df -k "${OUTPUT_DIR}" | awk 'NR==2 {print $4}')
NEED_KB=$((10 * 1024 * 1024))
if [ "${AVAIL_KB}" -lt "${NEED_KB}" ]; then
  echo "WARNING: Less than 10 GB free in ${OUTPUT_DIR}."
  echo "         Available: $((AVAIL_KB / 1024)) MB  Required: ~10240 MB"
  echo "         Continuing anyway — you may run out of space."
  echo ""
fi

# ─── Staging area ─────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'echo ""; echo "Cleaning up staging area..."; rm -rf "${WORK_DIR}"' EXIT
BUNDLE_DIR="${WORK_DIR}/${BUNDLE_NAME}"
mkdir -p "${BUNDLE_DIR}/images"

echo "--> [1/6] Pulling container images..."
echo "    This may take several minutes on a slow connection."
echo ""
docker pull "${LIGHTNING_IMAGE}"
echo ""
docker pull "${WORKER_IMAGE}"
echo ""
docker pull "${POSTGRES_IMAGE}"
echo ""

# ─── Save images ──────────────────────────────────────────────────────────────
echo "--> [2/6] Saving images (compressing with gzip -9, be patient)..."
echo "    [1/3] PostgreSQL..."
docker save "${POSTGRES_IMAGE}" | gzip -9 > "${BUNDLE_DIR}/images/postgres.tar.gz"
echo "          $(du -sh "${BUNDLE_DIR}/images/postgres.tar.gz" | cut -f1) written."

echo "    [2/3] ws-worker..."
docker save "${WORKER_IMAGE}" | gzip -9 > "${BUNDLE_DIR}/images/ws-worker.tar.gz"
echo "          $(du -sh "${BUNDLE_DIR}/images/ws-worker.tar.gz" | cut -f1) written."

echo "    [3/3] Lightning..."
docker save "${LIGHTNING_IMAGE}" | gzip -9 > "${BUNDLE_DIR}/images/lightning.tar.gz"
echo "          $(du -sh "${BUNDLE_DIR}/images/lightning.tar.gz" | cut -f1) written."
echo ""

# ─── Record image digests for audit trail ─────────────────────────────────────
echo "--> [3/6] Recording image digests..."
{
  echo "# Image digests recorded at build time ($(date -u +"%Y-%m-%dT%H:%M:%SZ"))"
  echo "# Used to verify on the server that the correct images were loaded."
  echo ""
  printf "%-12s  %s\n" "lightning"  "$(docker inspect --format='{{index .RepoDigests 0}}' "${LIGHTNING_IMAGE}" 2>/dev/null || echo 'digest unavailable')"
  printf "%-12s  %s\n" "ws-worker"  "$(docker inspect --format='{{index .RepoDigests 0}}' "${WORKER_IMAGE}"   2>/dev/null || echo 'digest unavailable')"
  printf "%-12s  %s\n" "postgres"   "$(docker inspect --format='{{index .RepoDigests 0}}' "${POSTGRES_IMAGE}"  2>/dev/null || echo 'digest unavailable')"
} > "${BUNDLE_DIR}/images/IMAGE_DIGESTS.txt"
echo ""

# ─── Copy deployment files ────────────────────────────────────────────────────
echo "--> [4/6] Copying deployment files..."
cp "${SCRIPT_DIR}/docker-compose.prod.yml"  "${BUNDLE_DIR}/docker-compose.yml"
cp "${SCRIPT_DIR}/server/setup-env.sh"      "${BUNDLE_DIR}/setup-env.sh"
cp "${SCRIPT_DIR}/server/install.sh"        "${BUNDLE_DIR}/install.sh"
cp "${SCRIPT_DIR}/server/verify.sh"         "${BUNDLE_DIR}/verify.sh"
chmod +x "${BUNDLE_DIR}"/*.sh
echo "    docker-compose.yml, setup-env.sh, install.sh, verify.sh"
echo ""

# ─── Inner checksums (per-file, verified on the server) ───────────────────────
echo "--> [5/6] Generating checksums..."
cd "${BUNDLE_DIR}"
sha256 \
  images/postgres.tar.gz \
  images/ws-worker.tar.gz \
  images/lightning.tar.gz \
  docker-compose.yml \
  setup-env.sh \
  install.sh \
  verify.sh \
  > SHA256SUMS
echo "    SHA256SUMS written."
cd "${WORK_DIR}"
echo ""

# ─── Create outer tarball ─────────────────────────────────────────────────────
echo "--> [6/6] Creating tarball..."
tar -czf "${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz" "${BUNDLE_NAME}/"
cd "${OUTPUT_DIR}"
sha256 "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256"

BUNDLE_SIZE=$(du -sh "${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz" | cut -f1)
CHECKSUM=$(cat "${BUNDLE_NAME}.tar.gz.sha256")

echo ""
echo "========================================================"
echo "  Bundle ready!"
echo ""
echo "  ${BUNDLE_NAME}.tar.gz         (${BUNDLE_SIZE})"
echo "  ${BUNDLE_NAME}.tar.gz.sha256"
echo ""
echo "  Transfer BOTH files to the air-gapped server."
echo ""
echo "  Verify after transfer (run on server):"
echo "    sha256sum -c ${BUNDLE_NAME}.tar.gz.sha256"
echo ""
echo "  Checksum:"
echo "    ${CHECKSUM}"
echo "========================================================"
