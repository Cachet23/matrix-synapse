# Matrix Synapse Deployment Playbook

> **For AI agents and humans:** Follow each phase in order. Skip nothing.
> Replace all `<PLACEHOLDER>` values with your own.

---

## Prerequisites

### System
- Linux host (tested on Ubuntu 22.04+ / Kernel 7.x)
- Docker + Docker Compose v2+
- `sudo` access
- Cloudflare account with a managed domain

### API Tokens (prepare beforehand)
- **Cloudflare API Token** with `Zone:DNS:Edit` + `Tunnel:Edit` for your zone
- Domain must already be managed by Cloudflare (nameservers pointing to CF)

### Path Convention
This guide uses `<WORKDIR>` as placeholder for your working directory.
Adapt to your host (e.g. `/opt/matrix-synapse/`, `/home/user/matrix-synapse/`, etc.).

---

## Phase 1: Cloudflare Tunnel

> The tunnel makes the server reachable without opening ports. No router port-forwarding needed. The host IP stays hidden.

### 1.1 Install cloudflared

```bash
# Arch-based (AUR)
yay -S cloudflared

# Debian/Ubuntu
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb

# Verify
cloudflared --version
```

### 1.2 Authenticate

```bash
# Interactive login (opens browser)
cloudflared tunnel login

# OR: API token
export CLOUDFLARE_API_TOKEN="<your-token>"
```

### 1.3 Create Tunnel

```bash
TUNNEL_NAME="<hostname-or-label>"

cloudflared tunnel create "$TUNNEL_NAME"
```

**Note down:**
- Tunnel ID (e.g. `84585384-b594-409e-9d21-dced4669117f`)
- Credentials file path (e.g. `/home/user/.cloudflared/<TUNNEL_ID>.json`)

### 1.4 DNS Record

```bash
cloudflared tunnel route dns "$TUNNEL_NAME" matrix.<DOMAIN>
```

This creates a CNAME record in Cloudflare (proxied).

> ⚠️ **Pitfall:** If the DNS record already exists (e.g. as A-record), delete it first. The CNAME won't auto-overwrite.

### 1.5 Tunnel Config

```bash
sudo mkdir -p /etc/cloudflared
sudo cp /home/user/.cloudflared/<TUNNEL_ID>.json /etc/cloudflared/
```

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: matrix.<DOMAIN>
    service: http://localhost:8008
  - service: http_status:404
```

### 1.6 systemd Service

> ⚠️ **Pitfall:** `cloudflared service install` can overwrite your config.yml. If you need custom ingress rules, write the systemd unit manually.

`/etc/systemd/system/cloudflared.service`:

```ini
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Alternative: Token-based (simpler, less flexible):**

```ini
[Service]
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token <TUNNEL_TOKEN>
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

### 1.7 Verify Tunnel

```bash
cloudflared tunnel info "$TUNNEL_NAME"
# Should show 4 connections
```

---

## Phase 2: Synapse + PostgreSQL (Docker)

### 2.1 Directory Structure

```bash
mkdir -p <WORKDIR>/synapse-data
mkdir -p <WORKDIR>/backups
cd <WORKDIR>
```

### 2.2 .env File

```bash
cat > .env << 'EOF'
POSTGRES_PASSWORD=<generate-a-strong-password>
SYNAPSE_SERVER_NAME=<DOMAIN>
EOF
chmod 600 .env
```

> ⚠️ **Pitfall:** Don't use `!` or `$` in the password — Docker Compose interprets these. Alphanumeric + `#%^&*` is safe.

### 2.3 docker-compose.yml

See the included `docker-compose.yml`. Key points:

```yaml
environment:
  SYNAPSE_SERVER_NAME: ${SYNAPSE_SERVER_NAME}  # from .env
  SYNAPSE_REPORT_STATS: "no"

ports:
  - "127.0.0.1:8008:8008"  # CRITICAL: localhost only!
```

> ⚠️ **Critical:** `127.0.0.1:8008:8008` — NEVER `0.0.0.0:8008`. Synapse must only be reachable locally. The tunnel is the only path to the outside.

### 2.4 Generate Initial Config

```bash
docker compose up -d postgres
# Wait for DB to be healthy
docker compose run --rm -e SYNAPSE_SERVER_NAME=<DOMAIN> -e SYNAPSE_REPORT_STATS=no synapse generate
```

This creates in `./synapse-data/`:
- `homeserver.yaml`
- `<DOMAIN>.signing.key`
- `<DOMAIN>.log.config`

### 2.5 Configure homeserver.yaml

Must set/adjust:

```yaml
server_name: "<DOMAIN>"
pid_file: /data/homeserver.pid

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true          # Important! Tunnel sends X-Forwarded-For
    resources:
      - names: [client]         # Client API only — no federation resource
        compress: false

# PostgreSQL (not SQLite!)
database:
  name: psycopg2
  args:
    user: synapse
    password: <POSTGRES_PASSWORD from .env>
    database: synapse
    host: postgres              # Docker service name!
    port: 5432
    cp_min: 5
    cp_max: 10

# Security
enable_registration: false       # NEVER true on the internet!

# Federation — fully disabled (single-server setup)
federation_domain_whitelist: []   # No external servers
serve_server_wellknown: false     # No federation metadata exposed
trusted_key_servers: []           # No external key queries

# Privacy
url_preview_enabled: false
max_upload_size: 50M
use_presence: true

# Rate limiting
rc_login:
  address:
    per_second: 0.17
    burst_count: 3
  account:
    per_second: 0.17
    burst_count: 3
```

### 2.6 Secrets in homeserver.yaml

These are auto-generated by `synapse generate`. **NEVER set or change them manually** — doing so invalidates all existing sessions:

- `registration_shared_secret`
- `macaroon_secret_key`
- `form_secret`
- `signing_key_path`

> ⚠️ **Pitfall:** Re-running `generate` creates new secrets. All user tokens are invalidated. Always back up `homeserver.yaml` before regenerating!

### 2.7 Start Synapse

```bash
docker compose up -d
docker compose ps              # Both should be "healthy"
docker logs synapse --tail 20  # Check for errors
```

### 2.8 Health Check

```bash
curl -s http://localhost:8008/health
# → OK

curl -s http://localhost:8008/_matrix/client/versions | python3 -m json.tool
# → JSON with versions array
```

---

## Phase 3: Create Users

### 3.1 Admin User

```bash
echo "no" | docker exec -i synapse register_new_matrix_user \
  -u <ADMIN_USERNAME> \
  -p "<PASSWORD>" \
  -a \
  -c /data/homeserver.yaml \
  http://localhost:8008
```

> ⚠️ **Pitfall:** The `echo "no"` is critical! The command asks interactively "Make admin?" — even with `-a` flag, the prompt appears. Without `echo "no"`, it hangs in Docker without TTY.

### 3.2 Regular User

```bash
echo "no" | docker exec -i synapse register_new_matrix_user \
  -u <USERNAME> \
  -p "<PASSWORD>" \
  -c /data/homeserver.yaml \
  http://localhost:8008
```

No `-a` flag for regular users.

### 3.3 Bot User (optional)

```bash
echo "no" | docker exec -i synapse register_new_matrix_user \
  -u <BOT_USERNAME> \
  -p "<PASSWORD>" \
  -c /data/homeserver.yaml \
  http://localhost:8008
```

### 3.4 Verify Users

```bash
docker exec synapse list_matrix_users -c /data/homeserver.yaml http://localhost:8008 2>/dev/null || \
  docker exec -it synapse /bin/bash -c "source /venv/bin/activate && list_matrix_users -c /data/homeserver.yaml http://localhost:8008"
```

---

## Phase 4: .well-known/matrix

> Only needed for federation. If federation is disabled (recommended for single-server setups), you can skip this phase entirely.

### 4.1 Create Files

If your website is on Cloudflare Pages (or any static host):

**`/.well-known/matrix/server`:**
```json
{"m.server": "matrix.<DOMAIN>:443"}
```

**`/.well-known/matrix/client`:**
```json
{
  "m.homeserver": {
    "base_url": "https://matrix.<DOMAIN>"
  }
}
```

### 4.2 CORS Headers

```
/.well-known/matrix/server
  Content-Type: application/json

/.well-known/matrix/client
  Content-Type: application/json
  Access-Control-Allow-Origin: *
```

> ⚠️ **Pitfall:** `Access-Control-Allow-Origin: *` on `.well-known/matrix/client` is **required** — other Matrix servers fetch this cross-origin. Without CORS, federation fails.

> ⚠️ **Pitfall:** If using Cloudflare Pages `_headers`, always **append** — never overwrite the whole file. Read first, then edit.

### 4.3 Verify

```bash
curl -s https://<DOMAIN>/.well-known/matrix/server
# {"m.server": "matrix.<DOMAIN>:443"}

curl -sI https://<DOMAIN>/.well-known/matrix/server | grep -i content-type
# content-type: application/json
```

---

## Phase 5: Backup Strategy

### 5.1 Backup Script

The included `backup.sh` handles everything. Backups are **encrypted with GPG AES256** — the passphrase file (`/etc/synapse-backup-key`) must exist on the host.

**Setup (one-time):**

```bash
# Create passphrase file (generate a strong passphrase)
echo -n "<your-strong-passphrase>" | sudo tee /etc/synapse-backup-key
sudo chmod 600 /etc/synapse-backup-key

# Encrypt signing key as offline backup (DO NOT commit to git!)
gpg --symmetric --cipher-algo AES256 --batch \
  --passphrase-file /etc/synapse-backup-key \
  -o synapse-data/signing-key-backup.gpg \
  synapse-data/<DOMAIN>.signing.key
```

> ⚠️ Store `signing-key-backup.gpg` offline (USB, password manager, other host). Without the signing key, the server identity is lost and Synapse cannot start.

**System cron (root crontab — runs independently of OpenClaw):**

```bash
sudo crontab -e
# Add:
# 0 3 * * * /path/to/backup.sh >> /var/log/synapse-backup.log 2>&1
```

### 5.2 Restore

> ⚠️ Backups are encrypted with GPG AES256. The passphrase file (`/etc/synapse-backup-key`) must exist on the restore host. If restoring on a different machine, copy the key file first.

```bash
cd <WORKDIR>

# 1. Stop containers
docker compose down

# 2. Decrypt and extract backup
gpg --decrypt --passphrase-file /etc/synapse-backup-key backups/synapse-YYYY-MM-DD.tar.gz.gpg | tar -xzf - -C /tmp/restore/

# 3. Restore data
cp -r /tmp/restore/synapse-data/* synapse-data/

# 4. Restore DB
docker compose up -d postgres
docker exec -i synapse-db psql -U synapse synapse < /tmp/restore/synapse-db.sql

# 5. Start Synapse
docker compose up -d
```

---

## Phase 6: End-to-End Verification

```bash
# 1. Docker containers
docker compose ps
# → synapse: Up (healthy), synapse-db: Up (healthy)

# 2. Cloudflare Tunnel
sudo systemctl is-active cloudflared
# → active

# 3. Synapse API via tunnel
curl -s https://matrix.<DOMAIN>/_matrix/client/versions | python3 -m json.tool
# → JSON with "versions" array

# 4. .well-known
curl -s https://<DOMAIN>/.well-known/matrix/server
# → {"m.server": "matrix.<DOMAIN>:443"}

# 5. Registration is OFF
curl -s https://matrix.<DOMAIN>/_matrix/client/v3/register
# → Error "Registration has been disabled" (expected!)

# 5. Federation check (should return 404 or M_UNRECOGNIZED — federation is disabled)
curl -s "https://matrix.<DOMAIN>/_matrix/federation/v1/version"
# → {"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}

curl -s "https://matrix.<DOMAIN>/.well-known/matrix/server"
# → 404 (federation metadata not exposed)
```

---

## Phase 7: Bot Integration (Optional)

> Connect a bot (e.g. via [matrix-bot-sdk](https://github.com/mautrix/matrix-bot-sdk), [mautrix-python](https://github.com/mautrix/mautrix-python), or similar) to your Synapse instance.

### 7.1 Get Bot Access Token

```bash
curl -s -X POST "https://matrix.<DOMAIN>/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "identifier": {"type": "m.id.user", "user": "<BOT_USERNAME>"},
    "password": "<BOT_PASSWORD>"
  }' | python3 -m json.tool
```

**Response contains:**
- `access_token` — for your bot framework config
- `user_id` — `@<BOT_USERNAME>:<DOMAIN>`
- `device_id` — device identifier

> ⚠️ **Token security:** The token is as valuable as a password. Never commit it, log it, or write it to files tracked by git.

### 7.2 Create DM Room (for direct messaging)

```bash
# 1. Create room
ROOM_ID=$(curl -s -X POST "https://matrix.<DOMAIN>/_matrix/client/v3/createRoom" \
  -H "Authorization: Bearer <BOT_ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Bot",
    "topic": "DM with Bot",
    "is_direct": true,
    "preset": "trusted_private_chat"
  }' | python3 -c "import sys,json; print(json.load(sys.stdin)['room_id'])")

echo "Room ID: $ROOM_ID"

# 2. Invite user
curl -s -X POST "https://matrix.<DOMAIN>/_matrix/client/v3/rooms/$ROOM_ID/invite" \
  -H "Authorization: Bearer <BOT_ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"@<USERNAME>:<DOMAIN>","reason":"DM with Bot"}'
```

### 7.3 Set m.direct Account Data

> ⚠️ **Critical!** Without `m.direct` account data, many bot frameworks won't find the DM room.

```bash
curl -s -X PUT "https://matrix.<DOMAIN>/_matrix/client/v3/user/@<BOT_USERNAME>:<DOMAIN>/account_data/m.direct" \
  -H "Authorization: Bearer <BOT_ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "@<USERNAME>:<DOMAIN>": ["<ROOM_ID>"]
  }'
```

### 7.4 E2EE (End-to-End Encryption)

**Option A: Unencrypted DM (simpler, for testing)**
- Create room without E2EE — bot can read/write directly

**Option B: E2EE DM (recommended)**
- E2EE is default for `trusted_private_chat` preset
- Bot needs Olm/Megolm support (most bot SDKs handle this)
- Verify the bot device in the client app

---

## Phase 8: Element Client Setup

### 8.1 Install Element

- **iOS:** App Store → "Element" (or "Element X")
- **Android:** F-Droid or Play Store → "Element"
- **Desktop:** https://element.io/download

### 8.2 Login

1. Open app → "Sign in"
2. **Homeserver:** `matrix.<DOMAIN>` (not matrix.org!)
3. **Username:** your username
4. **Password:** the password set during registration
5. App asks about E2EE key backup → "Set up" or "Skip" (can do later)

### 8.3 Device Verification

- Settings → Security & Privacy
- Verify other devices of your own account
- Verify bot device if E2EE is active

### 8.4 Cross-Signing Setup (recommended)

- Settings → Security & Privacy → "Set up Secure Backup"
- Save recovery key in a password manager

---

## Phase 9: Migration from Another Messenger (Optional)

When Matrix is stable and all users have migrated:

### 9.1 Disable Old Channel

Update your bot/framework config to disable the old messenger channel.

### 9.2 Stop Old Daemon (if applicable)

```bash
# Find and stop old messenger daemon
sudo systemctl disable --now <old-messenger-service>
```

### 9.3 Clean Up (optional)

> ⚠️ Don't rush. Test Matrix for at least 1-2 weeks before removing old infrastructure.

---

## Pitfalls & Lessons Learned

### 🔴 Critical

1. **`_headers` file overwrite**
   - Using `write` on Cloudflare Pages `_headers` overwrites the entire file
   - Existing security headers, CSP, cache rules are gone
   - **Fix:** Always `read` → `edit` (not `write`), or back up + append

2. **Synapse port on 0.0.0.0**
   - `ports: ["8008:8008"]` instead of `"127.0.0.1:8008:8008"` exposes Synapse directly
   - Cloudflare Tunnel becomes useless as security layer
   - **Always** use `127.0.0.1:8008:8008`

3. **Registration must be OFF**
   - `enable_registration: false` — never set to true on internet-facing servers
   - Create accounts only via `register_new_matrix_user` CLI

4. **Never regenerate secrets**
   - Re-running `synapse generate` creates new secrets
   - All existing user sessions are invalidated
   - Back up `homeserver.yaml` and `.signing.key` before any regeneration

### 🟡 Important

5. **`echo "no"` for user creation**
   - `register_new_matrix_user` prompts "Make admin?" interactively
   - Even with `-a` flag, the prompt appears
   - In Docker without TTY, the command hangs forever
   - `echo "no" | docker exec -i ...` solves this

6. **`x_forwarded: true`**
   - Must be set in `homeserver.yaml`
   - Otherwise Synapse doesn't see the real client IP (rate limiting breaks)

7. **`host: postgres` in DB config**
   - Not `localhost` or `127.0.0.1` — this is the Docker service name
   - Synapse runs in the container and reaches DB via Docker DNS

8. **Federation disabled for single-server setups**
   - `federation_domain_whitelist: []` with empty list disables all federation
   - `serve_server_wellknown: false` hides federation metadata
   - `trusted_key_servers: []` prevents external key queries
   - Only use federation if you need E2EE with users on other Matrix servers

### 🟢 Nice to Know

9. **Cloudflare Tunnel: Token vs Config**
   - Token-based start (`--token <TOKEN>`) is simpler, but no local ingress config
   - Config file (`config.yml`) is more flexible (multiple hostnames, services)
   - For single service: token is fine

10. **PostgreSQL > SQLite**
    - Synapse can use SQLite (default in `generate`)
    - For anything beyond testing: use PostgreSQL
    - SQLite doesn't scale and has locking issues

11. **Backup encryption**
    - Backups are encrypted with GPG AES256 via `/etc/synapse-backup-key`
    - The passphrase file must exist on the host (or restore host) — `chmod 600`, root-only
    - `signing-key-backup.gpg` is an offline copy of the server identity key
    - Without the signing key, Synapse cannot start after data loss
    - Backup cron runs as root via `sudo crontab -e` — independent of OpenClaw

12. **Docker volume ownership**
    - `synapse-data/` is owned by UID 991 (render) in the container
    - If you `cp -r` as root, permissions may break after restore
    - Manual file copy: `chown -R 991:991 synapse-data/`

13. **`m.direct` account data missing**
    - Bot frameworks won't find the DM room without `m.direct`
    - Error: `No direct room found for @user`
    - **Fix:** Set `m.direct` via API (Phase 7.3), then restart bot framework

14. **`direct repair` creates duplicate rooms**
    - If a DM room exists but isn't in `m.direct`, repair tools may try to create a new room
    - This fails with `403: already in the room`
    - **Fix:** Set `m.direct` manually (Phase 7.3) and restart

15. **Bot device verification**
    - Bot shows as "Not Verified" in Element
    - Without verification: E2EE messages may not be readable
    - **Fix:** Element → Bot profile → Devices → "Manually verify"

16. **Cache invalidation after m.direct**
    - Setting `m.direct` via API doesn't immediately reflect in bot frameworks
    - Most frameworks cache account data on startup
    - **Fix:** Restart the bot framework after setting `m.direct`

---

## Maintenance

### Update Synapse

```bash
cd <WORKDIR>

# 1. Backup
sudo ./backup.sh   # needs root for GPG passphrase file

# 2. Pull new image
docker compose pull

# 3. Restart
docker compose up -d

# 4. Health check
docker compose ps
docker logs synapse --tail 20

# 5. Verify client API
curl -s http://localhost:8008/_matrix/client/versions | python3 -m json.tool
```

### Logs

```bash
# Live
docker logs -f synapse

# Errors only
docker logs synapse 2>&1 | grep -i error | tail -20

# Cloudflare Tunnel
sudo journalctl -u cloudflared -f
```

### Database Maintenance

```bash
# Vacuum
docker exec synapse-db psql -U synapse -c "VACUUM ANALYZE;"

# DB size
docker exec synapse-db psql -U synapse -c "SELECT pg_size_pretty(pg_database_size('synapse'));"

# Active sessions
docker exec synapse-db psql -U synapse -c "SELECT count(*) FROM access_tokens;"
```

### User Management

```bash
# List users
docker exec synapse list_matrix_users -c /data/homeserver.yaml http://localhost:8008

# Deactivate user
docker exec -it synapse deactivate_account \
  -c /data/homeserver.yaml \
  http://localhost:8008 \
  @<USERNAME>:<DOMAIN>

# Change password
docker exec -it synapse password_hash \
  -c /data/homeserver.yaml \
  http://localhost:8008 \
  @<USERNAME>:<DOMAIN> \
  --no-admin
```

---

## Security Checklist

- [ ] Synapse listens on `127.0.0.1:8008` only
- [ ] Registration is OFF
- [ ] Cloudflare Tunnel active (no open ports)
- [ ] PostgreSQL password set (not default)
- [ ] `.env` has `chmod 600`
- [ ] Backups encrypted (GPG AES256) with passphrase in `/etc/synapse-backup-key`
- [ ] `signing-key-backup.gpg` stored offline
- [ ] Federation disabled (`federation_domain_whitelist: []`, `serve_server_wellknown: false`)
- [ ] No `federation` resource in listeners (client API only)
- [ ] `trusted_key_servers: []` (no external queries)
- [ ] Rate limiting configured
- [ ] Backup runs daily via root crontab (independent of OpenClaw)
- [ ] URL preview disabled (`url_preview_enabled: false`)

---

_Self-hosted. No tracking. No middlemen. No open ports._
