# DECISIONS.md — Trade-offs Memo

## 1. Image handling

**Chosen approach: `docker save` / `docker load` with per-image compressed tarballs**

The build script pulls three images (`ghcr.io/openfn/lightning:v2.16.7`, `openfn/ws-worker:latest`, `postgres:15.12-alpine`), saves each as a separate `gzip`-compressed tarball, and bundles them into a single outer tarball for transfer.

**Why this over the alternatives:**

- **Portable private registry (Harbor, `distribution/registry`)** — would require running an additional container on the server, more moving parts, more for a non-Docker IT focal point to manage. The benefit (serving partial layer updates) is only meaningful when you're updating frequently from many machines. For a single server, first install, it is pure overhead.
- **Single combined `docker save IMAGE1 IMAGE2 IMAGE3`** — possible and saves cross-image layer duplication (minimal here since images share few layers), but a single corrupt archive means reloading all three. Separate files give better error isolation and allow partial re-transfer.
- **OCI image layout directory + tar** — technically cleaner, but `docker load` understands the tarball format natively, requiring no extra tooling on the server. Simplicity wins for a non-developer operator.

**Trade-offs accepted:**
- Bundle size is ~3–5 GB (Lightning ~1.5 GB, worker ~600 MB, Postgres ~80 MB compressed). This is fine for scp or USB transfer on a LAN.
- No layer deduplication across image tarballs, so the total size is slightly larger than strictly necessary.
- `docker save` / `docker load` is the only approach that requires zero additional software on the air-gapped server beyond Docker Engine itself.

---

## 2. Secrets

**Generation:** All secrets are generated on the server by `setup-env.sh` using `openssl rand`, which is available on every Ubuntu install without internet access. No Elixir/Phoenix tooling is needed. A 4096-bit RSA keypair is generated for worker authentication (Lightning's `mix lightning.gen_worker_keys` task generates the same format; `openssl` is the underlying mechanism).

**Storage:** A single `.env` file in the installation directory, permissions `600` (readable only by the installing user). Docker Compose reads this file automatically for both variable interpolation and injection into containers.

**The three secret types and their rotation posture:**

| Secret | Risk of rotation | How to rotate |
|--------|-----------------|---------------|
| `SECRET_KEY_BASE` | Low — logs everyone out | Update `.env`, `docker compose restart web` |
| `WORKER_SECRET` / worker keys | Low — reconnects automatically | Update `.env`, `docker compose restart web worker` |
| `POSTGRES_PASSWORD` | Medium — must change DB and `.env` atomically | See below |
| `PRIMARY_ENCRYPTION_KEY` | **High — credentials become unreadable** | Requires a decrypt-re-encrypt migration; no built-in tool |

**Postgres password rotation procedure:**
```
1. docker compose exec postgres psql -U lightning -c "ALTER USER lightning PASSWORD 'new_password';"
2. Update POSTGRES_PASSWORD in .env
3. docker compose restart web
```
Changing the password in `.env` without step 1 is the most common failure mode (described in RUNBOOK).

**`PRIMARY_ENCRYPTION_KEY` is intentionally "set once"**: Lightning uses it to encrypt credentials at rest. There is no built-in rotation tooling. Document this clearly to the ministry: back up the `.env` file and treat the encryption key as permanent for the life of the installation.

**At 20 deployments instead of one:**  
The per-site `setup-env.sh` approach does not scale. I would:
- Use a secrets manager (HashiCorp Vault, or even a password manager with API access) to generate and store secrets centrally.
- Use `ansible-vault`-encrypted variable files, distributed per-site, to keep secrets out of plaintext on developer machines.
- Track `PRIMARY_ENCRYPTION_KEY` with special access controls since it is the hardest secret to rotate.
- Generate keypairs centrally and push only the needed half to each container (Lightning gets private key, worker gets public key), rather than both to the `.env` on one server.

---

## 3. Updates

**Patch update (e.g., v2.16.3 → v2.16.4):**

The IT focal point receives a new bundle from the jump host. On the server:

```bash
# Transfer and verify new bundle (same as initial install, Step 1-2 in RUNBOOK)
sha256sum -c openfn-lightning-bundle-v2.16.4.tar.gz.sha256

# Load only the updated Lightning image
docker load < images/lightning.tar.gz

# Pull the new image into Compose and restart web only
docker compose up -d --no-deps web
```

Docker Compose detects that the `web` service's image changed and replaces only that container, leaving Postgres and worker untouched. Downtime is ~10–30 seconds (the container restart). Patch releases do not typically require migrations (but always check the release notes). The worker does not usually need updating for a patch on Lightning.

**Minor update (e.g., v2.16 → v2.17):**

Likely involves database migrations and possibly a ws-worker version bump. Procedure:

```bash
# 1. Stop web and worker (leave postgres running — no data loss)
docker compose stop web worker

# 2. Load the new images from the updated bundle
docker load < images/lightning.tar.gz
docker load < images/ws-worker.tar.gz

# 3. Run migrations before starting the new web
docker compose run --rm web /app/bin/lightning eval "Lightning.Release.migrate()"

# 4. Start everything
docker compose up -d
./verify.sh
```

**Where the risks are:**

- **Migration failure** — if a migration is buggy, Postgres may be left in a partially-migrated state. Mitigation: take a `pg_dump` backup before any minor-version update. The procedure is `docker compose exec postgres pg_dump -U lightning lightning_prod > backup-pre-v2.17.sql`.
- **ws-worker compatibility** — Lightning and ws-worker versions must be compatible. Always update them together. The build script should be updated to pull the paired ws-worker version, not always `latest`.
- **Rollback** — patch rollback is straightforward (load old image, restart). Minor rollback requires running down-migrations if Lightning provides them; if not, restore from the `pg_dump` taken before the update.
- **No staging environment** — in this single-server setup, the ministry is testing updates in production. Document that briefly, and schedule updates during off-hours.

---

## 4. Observability

This server has no outbound network. Metrics cannot be shipped off-site.

**Minimum useful monitoring I would put in place:**

**1. Docker healthchecks (already included in docker-compose.yml)**  
Each container has a `healthcheck:` configured. `docker compose ps` shows health state (`healthy` / `unhealthy` / `starting`). This is the fastest answer to "is it up?" — one command, no additional software.

**2. Log rotation (already included)**  
Each service uses the `json-file` logging driver with `max-size` and `max-file` limits:
- `web`: 50 MB × 5 files = 250 MB max
- `worker`: 20 MB × 3 files = 60 MB max
- `postgres`: 10 MB × 3 files = 30 MB max

Without this, logs fill a 50 GB disk in weeks under normal load. This is the most common silent failure mode in self-hosted deployments.

**3. A simple watchdog cron job**  
Add to the server's crontab (run as the `openfn` user):

```cron
# Check Lightning health every 5 minutes; log failures to a local file
*/5 * * * * docker inspect --format='{{.State.Health.Status}}' openfn-web 2>&1 | grep -v healthy >> /var/log/openfn-health.log
```

This creates a record of every unhealthy event with a timestamp. The IT focal point checks `/var/log/openfn-health.log` weekly (or when users complain).

**4. Disk space alert**  
```cron
# Daily disk check — alert if less than 5 GB free
0 8 * * * df -BG / | awk 'NR==2 && $4+0 < 5 {print strftime("%Y-%m-%d %H:%M") " ALERT: Low disk space: " $4 " free"}' >> /var/log/openfn-health.log
```

**How to know something broke before the ministry calls:**  
Realistically, with no outbound network, the answer is: you don't get a push notification. The options are:
1. The IT focal point runs `./verify.sh` weekly (add to their calendar).
2. The watchdog cron job above creates a local log file they can check with `tail /var/log/openfn-health.log`.
3. If the ministry has an internal monitoring tool (Nagios, Zabbix, Prometheus running inside the network), Lightning exposes a Prometheus-compatible metrics endpoint at `/metrics` when `PROMEX_ENABLED=true`. This is the right answer if the ministry has existing monitoring infrastructure.

**What I would add with more time:**  
- A health-check script that sends an SMS via an internal GSM gateway (common in low-connectivity contexts) when Lightning goes down.
- Prometheus + Grafana running locally inside the same Docker Compose stack (the `tooling/observability/` directory in the Lightning repo has a working example). This is the largest monitoring upgrade for zero additional network requirements.

---

## Assumptions stated

- **Docker Compose v2** (`docker compose`, not `docker-compose`) is available. This ships with Docker Engine ≥ 20.10. Ubuntu 22.04's Docker Engine package includes it.
- The server user running install scripts has permission to use Docker without `sudo`. If not: `sudo usermod -aG docker $USER && newgrp docker`.
- `openssl` and `base64` are available on the server (both are standard on Ubuntu 22.04).
- `curl` is available inside the Lightning container for the healthcheck (it is — see the Dockerfile).
- The jump host or developer machine used to build the bundle runs Linux or macOS (the build script handles both `sha256sum` and `shasum -a 256`).
- No TLS termination is included in this bundle. For a ministry deployment exposed beyond the local server room LAN, TLS should be added via an nginx reverse proxy or Caddy with a local CA certificate. This is out of scope for this task but documented as an assumption.
- The `ws-worker` image tag `latest` was current at bundle build time. For updates, the specific digest in `images/IMAGE_DIGESTS.txt` can be used to verify the exact version that was deployed.
