# AgentOS web UI on the local network (opt-in, password login)

Date: 2026-10-31. Status: approved design.

## Problem

A box installed without Tailscale is reachable only from its console. The web UI listens on `127.0.0.1:7070`, is published only through `tailscale serve`, and authenticates only by Tailscale identity. A user who skipped Tailscale in the installer typed the box's LAN IP into a browser, got nothing, and the console didn't say why.

## Goal

An **opt-in** way to use the full web UI from the local network, with a password login, while Tailscale stays the default and keeps working unchanged. Every console makes it obvious how to reach the web UI.

## Decisions (from brainstorming)

- Opt-in setting `AGENTOS_WEB_LAN`: `0` or `1`, default `0`.
- HTTPS on port 443 with a self-signed certificate generated on the box. The fingerprint is shown on the console.
- Login with the `agent` account's system password (set by the installer).
- Session cookie, idle expiry, rate limiting, audit, and the same CSRF rules as today.

**Non-goals:**
- other users or accounts besides `agent`;
- ACME or Let's Encrypt certificates for LAN names;
- HTTP on port 80;
- exposing anything other than the web UI. noVNC, MCP HTTP and SSH keep their current rules, but desktop viewing works through the web UI's own `/vnc` WebSocket proxy.

## 1. Setting and where it is set

- `AGENTOS_WEB_LAN=0|1` in `/etc/agentos/agentos.env`, validated in `env.sh` like the other 0/1 settings.
- Where it can be set:
  - the interactive installer asks "Allow the web UI on your local network (password login)?", default no;
  - `agentos.env` for unattended installs and cloud-init;
  - `sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply`;
  - the agentos-config menu;
  - the web UI Settings page.
- `apply` (firstboot) does three things when the setting is on:
  1. generates the certificate if it is missing;
  2. opens the firewall;
  3. writes `LAN=1` (plus the certificate fingerprint) into `/etc/agentos/web.conf`, which the web server reads.

  It then restarts `agentos-web`.
- **Requirement:** the `agent` account must have a usable password. If it doesn't, `apply` refuses to enable LAN access and says to set one first (`sudo agentos-config password`).

## 2. Certificate

- Generated once with `openssl` (ECDSA P-256, 10-year validity) as `/etc/agentos/web-lan/cert.pem` and `/etc/agentos/web-lan/key.pem`.
  - The key is readable only by root and by the user the web server runs as; the plan verifies which user that is.
  - The SAN covers the hostname, `<hostname>.local`, and the IPv4 addresses present at generation time. Browsers warn about self-signed certificates regardless, and the warning is checked against the fingerprint.
- The certificate is kept across reboots and updates. Deleting it forces a new one on the next `apply`.
- The SHA-256 fingerprint is written to `web.conf`. It is shown on the console banner, by `sudo agentos-config` (menu, plus a `show-web-fingerprint` command) and in the web UI's System page.

## 3. Serving

- The existing loopback listener (`127.0.0.1:7070`, Tailscale identity) is **unchanged**.
- When `LAN=1`, the same process adds an HTTPS listener on `0.0.0.0:443`. It reuses the same route registration and runs a separate auth mode, so a request is decided by the listener it arrived on.
  - The plan verifies how to bind port 443 as a non-root service: `CAP_NET_BIND_SERVICE` through `AmbientCapabilities`, or root. Do not weaken the existing service hardening beyond that.
- **Host check:** the Host header must be the box's hostname, `<hostname>.local`, or one of its current IP addresses (IPv4/IPv6 literal, optionally with `:443`). Anything else gets 403. This blocks DNS rebinding.
- **Origin:** `https://<Host>` exactly.
- **Firewall:** the nftables rule accepts 443/tcp on non-tailscale interfaces only while `AGENTOS_WEB_LAN=1`. With the setting off, 443 is closed (except the existing Tailscale serve path on the tailnet interface).

## 4. Login and sessions (LAN listener only)

- **Unauthenticated requests:**
  - a GET for a page returns the login page, a static HTML form with no third-party resources;
  - API calls and WebSocket upgrades get 401.
- **`POST /api/lan/login`** with `{password}`:
  - checks the password against the `agent` account through a root-owned helper the web server runs via a fixed sudo rule. The helper reads the password on stdin and never takes it in argv, so it never appears in sudo's log. The plan verifies the mechanism, e.g. PAM with `pamtester`, or a crypt check against `/etc/shadow` that supports yescrypt;
  - on success, creates a session: a 256-bit random token, stored in memory only, with a 12-hour idle timeout and a 7-day absolute limit;
  - sets the cookie `__Host-agentos-session` (`Secure; HttpOnly; SameSite=Strict; Path=/`);
  - audits `agent@lan(<ip>) login`;
  - on failure, audits `login failed` and returns 401 after a constant 1 s delay.
- **Rate limiting:** at most 5 failed logins per IP per 10 minutes; after that, 429 until the window passes. There is also a global cap of 30 failures per 10 minutes across all IPs, so a distributed guesser is slowed too.
- **`POST /api/lan/logout`** deletes the session, clears the cookie and audits the logout.
- **Authorization:** an authenticated LAN session has the same permissions as an allowed Tailscale user. The `login` used in the audit log is `agent@lan(<ip>)`. CSRF rules are unchanged: Origin plus `X-AgentOS: 1` for unsafe methods and upgrades.
- A web server restart clears all sessions, which is documented.

## 5. Discoverability (console)

- **The console banner** (`/etc/issue`, rendered by firstboot or console-apply) always has a `Web UI:` line:
  - `Web UI: https://<lan-ip>  (LAN login; certificate SHA-256 AB:CD:…)` when LAN access is on, one line per IPv4 address, at most two;
  - `Web UI: https://<tailnet-name>` when Tailscale serve is active (both can be shown);
  - otherwise `Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)`.
- **The installer's summary screen** says how the web UI will be reachable.

## 6. Security notes

- The web UI is root-equivalent, so LAN access trusts everyone who can reach the box's LAN address and knows the `agent` password. The docs say so, and recommend Tailscale for anything beyond a trusted home or lab network.
- The password is never logged, never put in argv and never sent over plain HTTP.
- Sessions are in memory, with no persistent tokens.
- Brute force is rate-limited.

## 7. Testing

- **Unit tests (web server, vitest):**
  - mode selection per listener;
  - the Host allowlist, including IPs, `hostname.local` and a rejected rebinding host;
  - login success and failure;
  - the constant delay;
  - rate limiting, per IP and global;
  - session expiry, idle and absolute;
  - cookie flags;
  - logout;
  - WebSocket upgrades with and without a session;
  - CSRF on the LAN listener;
  - the Tailscale listener unchanged.
- **Unit tests (shell):** the password helper (correct, wrong, empty, no password set, argv never contains the password), certificate generation, and the `apply` behaviour.
- **In the VM (`test/checks/96-web.sh` or a new check):**
  - with the setting off, 443 is closed;
  - with it on:
    - from the host, `curl -k https://<guest>/` shows the login page;
    - a wrong password gets 401, and the 6th attempt gets 429;
    - the right password gets a cookie, and `/api/me` works;
    - an unsafe action without `X-AgentOS` gets 403, and with it succeeds;
    - a terminal WebSocket works;
    - the console banner shows the URL and fingerprint;
  - Tailscale access checks still pass.
