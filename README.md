# OpenFn Lightning — Air-Gap Deployment Package

This repository is a submission for the OpenFn DevOps Engineer technical task.  
It contains everything needed to deploy OpenFn Lightning v2.16.7 on a single air-gapped Linux server.

**Elapsed time: ~2.5 hours**

---

## What is in this repo

```
bundle/
  build-bundle.sh          # Run on internet-connected machine → produces the tarball
  docker-compose.prod.yml  # Production Compose file (included in bundle)
  server/
    setup-env.sh           # Run first on air-gapped server: generates secrets, creates .env
    install.sh             # Run second: loads images, migrates DB, starts services
    verify.sh              # Run after install: 9 checks, clear PASS/FAIL output
RUNBOOK.md                 # Step-by-step install guide for the ministry IT focal point
DECISIONS.md               # Trade-off memo answering all four questions
README.md                  # This file
```

---

## How to test the build script

You need a machine with Docker Engine running and internet access (your laptop, or the jump host in the scenario).

```bash
git clone https://github.com/BertinMwambuka/openfn-airgap-deploy.git
cd openfn-airgap-deploy
./bundle/build-bundle.sh
```

**Expected output:** A file called `openfn-lightning-bundle-v2.16.7.tar.gz` (~3–5 GB) and a `.sha256` sidecar in the repo root. Runtime is 5–15 minutes depending on your download speed and CPU (image compression is the bottleneck).

**What the script does:**
1. Pulls three images: `ghcr.io/openfn/lightning:v2.16.7`, `openfn/ws-worker:latest`, `postgres:15.12-alpine`
2. Saves each as a gzip-compressed tar archive
3. Copies the production Compose file and three server-side scripts
4. Generates SHA256 checksums for every file in the bundle (inner checksums)
5. Wraps everything in a single outer tarball with its own checksum (for transfer integrity)

---

## How to simulate an air-gapped install

To verify the full install flow without an actual air-gapped server, you can test locally:

```bash
# 1. Build the bundle (requires internet)
./bundle/build-bundle.sh

# 2. Extract it somewhere clean (simulates the air-gapped server)
mkdir /tmp/openfn-test
tar -xzf openfn-lightning-bundle-v2.16.7.tar.gz -C /tmp/openfn-test --strip-components=1
cd /tmp/openfn-test

# 3. Run the setup (generates .env with secrets)
./setup-env.sh
# Answer: host=localhost, port=4000, scheme=http, email=test@example.com

# 4. Install and start
./install.sh

# 5. Verify
./verify.sh

# 6. Clean up
docker compose down -v
```

The key test: **after step 2, disconnect from the internet (or unplug the network cable) before step 3**. The install must complete with no outbound network access whatsoever.

---

## Key design decisions (summary — see DECISIONS.md for full rationale)

| Decision | Choice | Why |
|----------|--------|-----|
| Image transfer | `docker save` / `docker load` | Zero extra infrastructure on server; requires only Docker Engine |
| Secrets | Generated on server via `openssl`; stored in `.env` (chmod 600) | No internet needed; no external dependencies |
| Compose version | Docker Compose v2 (`docker compose`) | Ships with Docker Engine ≥ 20.10 on Ubuntu 22.04 |
| Monitoring | Docker healthchecks + log rotation + cron watchdog | No outbound network; no extra services needed |

---

## Lightning version pinned

**v2.16.7** — the latest stable release at time of submission (2026-06-20).  
The current development pre-release is v2.16.8-pre; it was excluded as non-stable.

---

## Reviewer notes

- The RUNBOOK audience is a ministry IT focal point with Linux experience but no Docker experience. Every Docker concept used is explained inline.
- The verify.sh script gives a definitive binary result (exit 0 = all pass, exit 1 = failures listed) rather than asking the operator to interpret logs.
- The failure scenario in RUNBOOK.md (§ Troubleshooting) covers the single most common first-install failure: the database password in `.env` not matching the Postgres volume, which happens when `setup-env.sh` is re-run after initial Postgres initialisation. This shows up as a crash loop on the `web` container with a clear Postgrex authentication error in the logs.
- The `docker-compose.prod.yml` was derived from the upstream `docker-compose.yml` in the Lightning repo (same Postgres image, same worker command structure, same volume name pattern) with production-appropriate additions: resource limits, log rotation, health start periods, `LISTEN_ADDRESS: 0.0.0.0` for Docker bridge networking, and pinned Lightning image tag.
