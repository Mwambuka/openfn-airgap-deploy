# OpenFn Lightning — Installation Runbook

**Audience:** Ministry IT focal point  
**Background assumed:** Comfortable with Linux command line (SSH, editing files, basic networking). No Docker experience required.  
**Time required:** 45–90 minutes for a first install.

---

## What you are installing

OpenFn Lightning is a workflow automation platform. It runs as three programs (called "containers") managed by Docker:

| Container | What it does |
|-----------|-------------|
| `postgres` | Database — stores all workflows, users, and run history |
| `web`      | The Lightning application — what users access in their browser |
| `worker`   | Job executor — runs the JavaScript code in your workflows |

Docker keeps these programs isolated from the rest of your system and restarts them automatically if they crash.

---

## Before you start

**What you need:**

- The bundle file: `openfn-lightning-bundle-v2.16.7.tar.gz`
- The checksum file: `openfn-lightning-bundle-v2.16.7.tar.gz.sha256`
- Both files transferred to this server (see Step 1 below)
- This server's IP address (ask your network team if unsure)
- An e-mail address for the system admin account

**Check your server meets requirements:**

```bash
# Check available disk space — need at least 15 GB free
df -h /

# Check Docker is installed
docker --version
# Expected output: Docker version 24.x.x or higher

# Check Docker Compose is available (must say v2.x.x)
docker compose version

# Check Docker daemon is running
sudo systemctl status docker
# Expected: "active (running)"
```

If Docker is not running, start it:

```bash
sudo systemctl start docker
sudo systemctl enable docker   # start automatically on server reboot
```

---

## Step 1 — Transfer and verify the bundle

Transfer both files from the jump host (or USB drive) to this server.

**Via scp from the jump host:**

```bash
# Run this on the JUMP HOST, not on this server
scp openfn-lightning-bundle-v2.16.7.tar.gz       user@SERVER_IP:/home/user/
scp openfn-lightning-bundle-v2.16.7.tar.gz.sha256 user@SERVER_IP:/home/user/
```

**Via USB drive:**

```bash
# On the server, after mounting the USB drive (usually at /media/usb)
cp /media/usb/openfn-lightning-bundle-v2.16.7.tar.gz       /home/user/
cp /media/usb/openfn-lightning-bundle-v2.16.7.tar.gz.sha256 /home/user/
```

**Verify the transfer was not corrupted:**

```bash
cd /home/user
sha256sum -c openfn-lightning-bundle-v2.16.7.tar.gz.sha256
```

Expected output:

```
openfn-lightning-bundle-v2.16.7.tar.gz: OK
```

> **If you see `FAILED` instead of `OK`:** The file was corrupted in transfer.  
> Transfer the bundle again and re-run the check before continuing.

---

## Step 2 — Extract the bundle

Choose a permanent home for the installation. `/opt/openfn` is a good choice:

```bash
sudo mkdir -p /opt/openfn
sudo tar -xzf /home/user/openfn-lightning-bundle-v2.16.7.tar.gz -C /opt/openfn --strip-components=1
sudo chown -R $USER:$USER /opt/openfn
cd /opt/openfn
ls
```

You should see:

```
docker-compose.yml  images/  install.sh  setup-env.sh  verify.sh  SHA256SUMS
```

Make the scripts executable:

```bash
chmod +x setup-env.sh install.sh verify.sh
```

---

## Step 3 — Generate secrets and configure the site

Run the setup script. It will ask you a few questions and create a `.env` file containing all the passwords and cryptographic keys Lightning needs.

```bash
cd /opt/openfn
./setup-env.sh
```

The script will ask:

1. **Server IP address or hostname** — The address users type in their browser  
   Example: `192.168.10.50` or `openfn.ministry.int`

2. **Port** — Press Enter to accept the default `4000`  
   (Users will visit `http://192.168.10.50:4000`)

3. **Protocol** — Press Enter to accept `http`

4. **Admin e-mail** — Your IT department's e-mail address  
   Example: `it-support@ministry.gov`

The script generates all passwords and cryptographic keys automatically. When it finishes, you will see:

```
  .env created at: /opt/openfn/.env
  IMPORTANT — Back up this file NOW
```

**Back up the .env file immediately:**

```bash
# Copy to a secure USB drive or another safe location
cp /opt/openfn/.env /media/usb/openfn-env-backup-$(date +%Y%m%d).txt
```

> **Why this matters:** The `.env` file contains the encryption key for your database. If it is lost and the server ever fails, you cannot recover your workflows or credentials. Treat it like a password you cannot reset.

---

## Step 4 — Load images and start Lightning

```bash
cd /opt/openfn
./install.sh
```

This script:
1. Verifies the files are intact (inner checksums)
2. Loads the three Docker images from the `.tar.gz` files in `images/`
3. Creates the database and runs initial setup
4. Starts all three services

**Expected output (abridged):**

```
--> [2/6] Saving images...
    [1/3] PostgreSQL... ✓
    [2/3] ws-worker...  ✓
    [3/3] Lightning...  ✓
--> Starting PostgreSQL...
    Waiting for PostgreSQL to be ready...
    PostgreSQL is healthy.
--> Running database migrations... Migrations complete.
--> Starting Lightning web and worker services...
--> Waiting for Lightning web to become healthy...
    Installation complete!
```

**If you see `WARNING: Web container did not report healthy in time`:**  
This is normal on first run — the application is still initialising. Wait 2 minutes, then go to Step 5.

---

## Step 5 — Verify everything is working

```bash
cd /opt/openfn
./verify.sh
```

Each line will print `[PASS]` or `[FAIL]`. All checks must pass.

**What a successful result looks like:**

```
  [PASS] PostgreSQL container is running
  [PASS] PostgreSQL is accepting connections (healthcheck passed)
  [PASS] Lightning web container is running
  [PASS] Lightning web healthcheck passed
  [PASS] Worker container is running
  [PASS] HTTP /health_check returns 200 OK
  [PASS] Login page /users/log_in returns 200 OK
  [PASS] No containers are in a crash/restart loop
  [PASS] Disk space OK (22 GB free on /)

  RESULT: ALL 9 CHECKS PASSED

  Open this URL in a web browser on any ministry computer:
    http://192.168.10.50:4000
```

> **This is your definitive "yes, it works."**  
> If any check fails, go to the Troubleshooting section below before telling anyone Lightning is ready.

---

## Step 6 — Create the first user account

Lightning starts with no user accounts. The first account must be created via the command line.

```bash
cd /opt/openfn

# Open an interactive console inside the Lightning container
docker compose exec web /app/bin/lightning remote

# Inside the console, type this (replace the details in quotes):
Lightning.Accounts.register_superuser(%{
  first_name: "Admin",
  last_name: "User",
  email: "admin@ministry.gov",
  password: "ChangeThisPassword123!"
})

# Type :q and press Enter to exit the console
```

Now open `http://SERVER_IP:4000` in a browser and log in with those credentials.  
**Change the password immediately after first login.**

---

## Step 7 — Configure the firewall (if applicable)

If the server has a firewall (`ufw`), open the Lightning port:

```bash
sudo ufw allow 4000/tcp
sudo ufw status
```

---

## Day-to-day operations

**Check if Lightning is running:**

```bash
cd /opt/openfn
docker compose ps
```

All three containers should show `Up` under Status and `healthy` under Health.

**View logs (last 50 lines):**

```bash
docker compose logs --tail=50 web      # Lightning application logs
docker compose logs --tail=50 postgres # Database logs
docker compose logs --tail=50 worker   # Job execution logs
```

**Restart a single service:**

```bash
docker compose restart web      # restart Lightning only
docker compose restart worker   # restart worker only
```

**Stop everything:**

```bash
docker compose stop
```

**Start again after a stop:**

```bash
docker compose start
```

**After a server reboot:**  
Docker is configured to restart containers automatically (`restart: unless-stopped`). Lightning should come back on its own within 2 minutes of the server booting. Verify with `./verify.sh`.

---

## Troubleshooting — Lightning web container in a crash loop

This is the most common problem on a first install (and on re-installs). Here is how to diagnose and fix it.

### What you will see

Running `docker compose ps` shows something like this:

```
NAME              IMAGE                              STATUS
openfn-postgres   postgres:15.12-alpine              Up 3 minutes (healthy)
openfn-web        ghcr.io/openfn/lightning:v2.16.7   Restarting (1) 30 seconds ago
openfn-worker     openfn/ws-worker:latest            Created
```

The `web` container shows `Restarting` instead of `Up`. The `worker` shows `Created` because it is waiting for `web` to be healthy before it starts.

### Step A — Read the error message

```bash
docker compose logs --tail=30 web
```

Look at the last few lines. The most common errors are:

**Error 1: Wrong database password**

```
[error] Postgrex.Protocol (#PID<...>) failed to connect:
** (Postgrex.Error) FATAL 28P01 (invalid_password)
   password authentication failed for user "lightning"
```

**Cause:** The `POSTGRES_PASSWORD` in `.env` does not match the password that PostgreSQL was initialised with. This happens when:
- You ran `setup-env.sh` a second time after the database was already created (new random password generated)
- You manually edited `.env` and changed `POSTGRES_PASSWORD`

**Fix A1 — No important data yet (safest):**

```bash
# Stop all containers
docker compose stop

# Remove the database volume (ALL DATA WILL BE DELETED)
docker compose down -v

# Re-run installation — Postgres will reinitialise with the current .env password
./install.sh
```

**Fix A2 — You have data you need to keep:**

You need to change the Postgres password to match what `.env` says.

```bash
# Find the POSTGRES_PASSWORD value in .env
grep POSTGRES_PASSWORD /opt/openfn/.env
# Example output: POSTGRES_PASSWORD=abc123xyz...

# Connect to the running Postgres container
docker compose exec postgres psql -U lightning -d lightning_prod

# Inside psql, change the password (replace 'abc123xyz' with your actual value):
ALTER USER lightning PASSWORD 'abc123xyz';
\q

# Now restart the web container
docker compose restart web

# Verify
./verify.sh
```

---

**Error 2: Missing or invalid SECRET_KEY_BASE**

```
[error] RuntimeError: expected :secret_key_base to be at least 64 bytes
```

**Cause:** `SECRET_KEY_BASE` in `.env` is too short or missing.

**Fix:**

```bash
# Generate a new value (run this on the server — openssl is built in)
openssl rand -base64 64 | tr -d '\n'

# Edit .env and replace the SECRET_KEY_BASE line with the new value
nano /opt/openfn/.env

# Restart web
docker compose restart web
./verify.sh
```

---

**Error 3: Cannot reach database (network / timing issue)**

```
[error] ** (DBConnection.ConnectionError) tcp connect (postgres:5432):
        connection refused
```

**Cause:** Usually a timing issue — Lightning tried to connect before Postgres finished starting. This can also happen if the Postgres container is not running.

**Fix:**

```bash
# Check if Postgres is running and healthy
docker compose ps postgres

# If it is running, simply restart web — it will reconnect
docker compose restart web

# Wait 30 seconds, then verify
sleep 30
./verify.sh
```

---

### What to do if none of the above apply

```bash
# Capture the full log and send it to OpenFn support
docker compose logs web > /tmp/lightning-web.log 2>&1
docker compose logs postgres > /tmp/lightning-pg.log 2>&1
```

Share these files with your OpenFn contact.

---

## Quick reference card

| Task | Command |
|------|---------|
| Check status | `docker compose ps` |
| View web logs | `docker compose logs --tail=50 web` |
| Restart web | `docker compose restart web` |
| Run verification | `cd /opt/openfn && ./verify.sh` |
| Stop everything | `docker compose stop` |
| Start everything | `docker compose start` |
| After server reboot | Wait 2 min, then `./verify.sh` |
