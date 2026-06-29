# Bot Connection Guide

> How to connect Matrix bot gateways (OpenClaw, Hermes Agent, mautrix-based bots, matrix-nio scripts) to your Synapse instance **without routing their traffic through Cloudflare**.

## Why this matters

In the default setup, Synapse listens on `127.0.0.1:8008` and is exposed to the internet via a Cloudflare Tunnel. Mobile clients (Element, Element X, SchildiChat) have no choice — they must reach Synapse through the public URL, so their traffic traverses Cloudflare.

Bots, however, usually run on infrastructure you control. If a bot connects to `https://matrix.<your-domain>` it sends its `Authorization: Bearer <access_token>` header through Cloudflare, which terminates TLS and can therefore see:

- the bot's long-lived access token (the highest-value credential in the system)
- `/sync` polling patterns (continuous, 24/7 — a distinct traffic fingerprint)
- room memberships, room IDs, sync intervals
- the mere fact that a bot exists

Bots typically have broader room access than individual users, run continuously, and their tokens are the most sensitive credentials in the deployment. Routing them through Cloudflare is an unnecessary exposure.

**The fix:** connect server-side components to Synapse's internal address. Only mobile clients traverse Cloudflare.

```
   Mobile phones ────► Cloudflare Tunnel ───► Synapse (:8008)
                                                    ▲
   Bots ───────────────────────────────────────────┘  (internal, no CF)
```

Cloudflare sees two human users with irregular mobile traffic instead of two humans plus two bots with 24/7 sync polling. The bot tokens never leave the host.

## Prerequisite: make Synapse listen on an internal interface

By default Synapse binds to `127.0.0.1:8008` only. To let other hosts (VMs, containers, other machines on a private network) reach it, add their interface address to `bind_addresses` in `synapse-data/homeserver.yaml`:

```yaml
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses:
      - 127.0.0.1        # localhost — always keep this (CF tunnel + local bots)
      - 192.168.122.1    # libvirt NAT gateway (example) — for KVM guests on this host
      # - 100.x.x.x      # Tailscale IP — for bots on other machines in your tailnet
      # - 10.0.0.5       # private LAN IP — for bots on other hosts in your LAN
    resources:
      - names: [client]
```

Restart Synapse:

```bash
docker compose restart synapse
```

The Cloudflare Tunnel config (`/etc/cloudflared/config.yml`) still points to `http://localhost:8008` — no change there. Mobile clients are unaffected.

## Three deployment topologies

Pick the one that matches where your bot runs.

### Variant 1: Bot on the same host as Synapse

Use when the bot runs on the same machine as the Synapse Docker container (e.g. a bot on the host, or in another container on the same Docker network).

```
Bot ──► http://localhost:8008   (or http://synapse:8008 if in the same compose network)
```

- No TLS needed — traffic never leaves the host.
- No VPN needed.
- Lowest latency, lowest complexity.

Config example (bot env):

```bash
MATRIX_HOMESERVER=http://localhost:8008
MATRIX_ACCESS_TOKEN=<bot-token>
```

If the bot is another container in the same `docker-compose.yml`, use the service name instead of `localhost`:

```bash
MATRIX_HOMESERVER=http://synapse:8008
```

### Variant 2: Bot in a VM or container on the same physical host

Use when the bot runs in a KVM guest, LXC container, or separate Docker network on the same physical server as Synapse.

```
Bot (in VM) ──► http://<host-gateway-ip>:8008
```

The host's IP on the private network between host and guest is the gateway. Common defaults:

| Hypervisor / network | Host gateway IP |
|---|---|
| libvirt default NAT (`virbr0`) | `192.168.122.1` |
| Docker user-defined bridge | `172.x.x.1` (check `docker network inspect`) |
| LXC default bridge (`lxcbr0`) | `10.0.3.1` |

Config example:

```bash
MATRIX_HOMESERVER=http://<host-gateway-ip>:8008
```

- No TLS, no VPN — the libvirt/Docker bridge is already a private internal network.
- Verify connectivity from the guest: `curl -s http://<host-gateway-ip>:8008/health` → `OK`.

### Variant 3: Bot on a different physical machine

Use when the bot runs on a separate server (another box in your LAN, a rented VPS, a remote colocation). Synapse must not be exposed to the public internet for the bot — use a private tunnel.

```
Bot (remote) ──► WireGuard / Tailscale ──► Synapse (listens on tailnet IP only)
```

**Tailscale option (simplest):**

1. Install Tailscale on both Synapse host and bot host, join them to the same tailnet.
2. In `homeserver.yaml`, add the Synapse host's Tailscale IP (`100.x.x.x`) to `bind_addresses`.
3. Bot connects to `http://100.x.x.x:8008`.

**WireGuard option (manual, no third party):**

1. Set up a WireGuard tunnel between the two hosts (point-to-point, e.g. `10.10.0.1` ↔ `10.10.0.2`).
2. Add `10.10.0.1` to Synapse `bind_addresses`.
3. Bot connects to `http://10.10.0.1:8008`.

Tradeoff vs. Variant 2: a real VPN is needed, but the bot can live anywhere without exposing Synapse publicly. Tailscale is the convenience choice; WireGuard the maximum-trust choice (no third party involved beyond the two endpoints).

## Getting a bot access token

Regardless of which variant you use, the bot needs its own Matrix user and an access token:

```bash
# 1. Register the bot user (run on the Synapse host)
echo "no" | docker exec -i synapse register_new_matrix_user \
  -u <bot-username> \
  -p "<strong-password>" \
  -c /data/homeserver.yaml \
  http://localhost:8008

# 2. Get an access token (run from wherever the bot will connect from)
curl -X POST http://<synapse-internal-address>:8008/_matrix/client/v3/login \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "user": "@<bot-username>:<your-domain>",
    "password": "<strong-password>"
  }'
# → copy "access_token" from the response
```

Note: the login request in step 2 goes to the **internal** address, so the token never traverses Cloudflare.

## E2EE (encrypted rooms)

If the bot will participate in end-to-end encrypted rooms (recommended), it needs Olm/Megolm support. This is independent of which connection variant you use:

- **Hermes Agent:** `uv pip install -e ".[matrix]"` plus `libolm-dev` system package (see [Hermes Matrix docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix)).
- **mautrix-based bots:** install with the `[encryption]` extra.
- **matrix-nio / simplematrixbotlib:** install `matrix-nio[e2e]`.

The bot's device keys are stored locally on the bot host. Keep them backed up — losing them means the bot can no longer decrypt historical messages in encrypted rooms.

## Verification checklist

After switching a bot to the internal address:

- [ ] Bot starts without connection errors in its logs.
- [ ] Bot's `/sync` polling shows up in `docker logs synapse` (you should see regular `GET /_matrix/client/v3/sync` lines from the bot's IP — `127.0.0.1`, the libvirt bridge IP, or the tailnet IP, **not** the Cloudflare Tunnel's source IP).
- [ ] Sending a message to the bot from a mobile client still produces a reply within the expected latency.
- [ ] If E2EE: verify the bot's device in Element (QR or emoji) so encrypted messages flow cleanly.
- [ ] From outside the host/network, `https://matrix.<your-domain>/health` still returns `OK` (Cloudflare Tunnel still works for mobile clients).

## What this does not protect

- Mobile clients still traverse Cloudflare. Their access tokens, sync patterns, and room IDs are visible to Cloudflare. There is no way around this while using Element + a public domain — Cloudflare must terminate TLS to route the request.
- E2EE message content (Olm/Megolm ciphertext) was never visible to Cloudflare regardless of this change — the protection here is about **metadata and credentials**, not message bodies.
- If the Synapse host itself is compromised, all bot tokens on it are compromised too. The host remains the central trust anchor.

## Summary table

| Bot location | Connect to | VPN needed? | TLS needed? |
|---|---|---|---|
| Same host as Synapse | `http://localhost:8008` | no | no |
| KVM guest / container on same host | `http://<libvirt-or-bridge-gateway>:8008` | no (private bridge) | no |
| Other machine in LAN | `http://<lan-ip>:8008` | no (if LAN trusted) | optional |
| Remote server (VPS, another site) | `http://<tailnet-or-wg-ip>:8008` | yes (Tailscale or WireGuard) | optional |

## Pitfalls encountered during setup

These are real issues hit while switching bots from the public Cloudflare URL to the internal address. Documented so others don't repeat the debugging.

### 1. SSRF protection blocks private network URLs silently

**Symptom:** Bot fails to reach `http://localhost:8008` or `http://<host-gateway-ip>:8008`. The connection times out after 30s with a generic "did not reach ready sync state" error. No explicit error message about private networks.

**Cause:** Bot frameworks with built-in SSRF (Server-Side Request Forgery) protection refuse connections to loopback/private IP ranges (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) unless explicitly opted in. This is a security feature — a compromised agent should not be able to scan internal services.

**Frameworks affected:**
- **OpenClaw** (uses `matrix-js-sdk`): blocked by default. Config:
  ```json
  "matrix": {
    "network": { "dangerouslyAllowPrivateNetwork": true }
  }
  ```
- **mautrix-based bots** (Hermes Agent, mautrix-python): no SSRF gate by default, but worth checking your framework's docs.

**The `dangerously` prefix is intentional** — only enable it if you control what the bot can do (which you do, since it's your agent). Don't enable it for untrusted bots.

### 2. Docker port mapping controls host-side access, not Synapse's `bind_addresses`

**Symptom:** You add `bind_addresses: [<host-internal-ip>]` to `homeserver.yaml`, restart Synapse, and it crashes with `ListenerException: Failed to listen on TCP port`.

**Cause:** Synapse runs **inside** the Docker container. The container only sees its own network interfaces — the host's `virbr0` IP exists on the host, not inside the container. Synapse can't bind to an IP it doesn't have.

**Fix:** Bind Synapse to `0.0.0.0` (or `::`) inside the container, then use **Docker's port mapping** in `docker-compose.yml` to control which host interfaces can reach it:

```yaml
services:
  synapse:
    ports:
      - "127.0.0.1:8008:8008"          # Cloudflare Tunnel + same-host bots
      - "<host-internal-ip>:8008:8008"  # libvirt guests (KVM VMs on this host)
```

Synapse's `bind_addresses` field is only useful when running Synapse directly on the host (no Docker). In Docker, the container's networking layer (Docker's bridge, host networking, or port-published interfaces) is what controls reachability.

### 3. Crypto store path is tied to the homeserver URL

**Symptom:** After switching the bot's homeserver from `https://matrix.example.com` to `http://localhost:8008`, E2EE breaks. Old messages can't be decrypted ("The sender's device has not sent us the keys for this message"). The bot appears to start fresh as a new device.

**Cause:** Many Matrix bot SDKs key their Olm/Megolm crypto store by the homeserver URL. Changing the URL creates a new directory/database, leaving the old Olm keys (device identity, Megolm sessions) behind. The bot effectively becomes a new device — your phone's Element app still encrypts to the old device ID and the new one can't decrypt.

**Frameworks:**
- **OpenClaw:** crypto store lives at `~/.openclaw/matrix/accounts/default/<HOMESERVER_HOST>__<USER_ID>/`. Rename the old directory to match the new URL:
  ```bash
  cd ~/.openclaw/matrix/accounts/default/
  mv matrix.example.com__@bot:example.com localhost_8008__@bot:example.com
  ```
  Then restart the gateway. The bot resumes with its original device ID and keys.
- **mautrix-python / Hermes:** crypto store path is usually configurable. Point it at the old store instead of letting it create a new one.

**If the rename doesn't help** (device ID already changed during failed restarts): you may need to set `deviceId` explicitly in the bot config to force the SDK to reuse the original device, otherwise it logs in as a new device and you must re-verify in Element.

### 4. After device changes, only new messages decrypt

**Symptom:** Bot is connected, sync works, but every historical message in encrypted rooms shows `DecryptionError: This message was sent before this device logged in, and key backup is not working`.

**Cause:** Megolm keys are sent to specific devices at the time the message is sent. If your bot wasn't a known device then (or was a different device ID), the keys were never delivered to it. There's no retroactive key delivery unless key backup is configured (which Synapse doesn't enable by default for bots).

**Fix:** No fix for old messages — accept the loss. New messages will work once the bot's device appears in your phone's Element device list. To force key sharing, you can sometimes send a new message in the room (which rotates the Megolm session and shares keys to all current devices including the bot).

### 5. `cloudflared service install` overwrites custom config

**Symptom:** You write `/etc/cloudflared/config.yml` with custom ingress rules, run `cloudflared service install`, and your config is replaced with a stub pointing at a different origin.

**Cause:** `service install` generates its own config from the tunnel token. It doesn't merge with your existing file.

**Fix:** Write the systemd unit manually instead of using `service install`:

```ini
# /etc/systemd/system/cloudflared.service
[Service]
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
# or with token:
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token <TUNNEL_TOKEN>
```

### 6. Element X device verification UI is non-obvious

**Symptom:** You need to verify a bot's new device but can't find the option in Element X.

**Where it is:** Open the DM with the bot → tap the bot's display name/avatar at the top → scroll to "Devices" (or "Sessions") → tap the unverified device → "Verify" (QR or emoji).

If verification isn't offered, the bot may have appeared as "known" because you've DM'd it before. In that case, the encryption works but Element shows a shield icon — tap it to review the device list.

**For bots, verification is optional** — unverified bots can still send/receive encrypted messages. Verification just removes the "unverified device" warning UI. The Megolm key sharing happens regardless of verification status.
