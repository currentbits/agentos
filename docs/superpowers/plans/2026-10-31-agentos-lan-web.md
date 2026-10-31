# AgentOS Web UI on the Local Network Implementation Plan (Plan 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A box without Tailscale can opt in (`AGENTOS_WEB_LAN=1`) to the full web UI at `https://<LAN address>`, behind the `agent` account's password, while the Tailscale path stays the default and unchanged, and every console says how to reach the web UI.

**Architecture:**
- **One process, two listeners.** `agentos-web` keeps its loopback listener (`127.0.0.1:7070`, Tailscale identity). When `web.conf` says `LAN=1`, `main.ts` builds a second Fastify app from the same `buildApp()` (every route, `@fastify/websocket`, the static UI) with a different `onRequest` hook (`lan.ts`), over HTTPS on `[::]:7443`. A request is decided by the app, and so the listener, it arrived on.
- **443 through the firewall.** tailscaled binds `<tailnet-ip>:443` itself for `tailscale serve`, so nothing else may bind `*:443` (fact table). `firewall.nft` redirects 443/tcp on every interface but `tailscale0` to 7443 while its `lan_web` set holds 443; `agentos-firewall` fills the set from `web.conf`. The service needs no capability, and its unit is unchanged.
- **Login.** `POST /api/lan/login` sends the password on stdin to `check-password`, a root-owned perl helper run through `sudo -n` (libcrypt's `crypt()`: yescrypt and SHA-512). Sessions are 256-bit tokens, kept in memory as their SHA-256, in a `__Host-` cookie; 12 h idle, 7 days absolute; 5 failures per address and 30 overall per 10 minutes.
- **Apply.** A new `web-conf` (firstboot's web step, moved out so it can be tested) makes the certificate (`web-lan-cert`, ECDSA P-256), writes `LAN=` and `FINGERPRINT=` into `web.conf` only when `agent` has a usable password, writes the console's `Web UI:` lines, and tells firstboot when to restart `agentos-web` and reload the firewall.

**Tech Stack:**
- the existing stack: bash, systemd 257, nftables 1.1.3, OpenSSL 3.5, Debian 13, NodeSource Node 24 server (Fastify 5.12.7, `@fastify/websocket` 11.3.4, `ws` 8.22.0) and React UI, vitest 5.0.5;
- new: `perl` (`perl-base`, Essential in Debian, already in the image) for the password check. No new package.

**Builds on:** branch `lan-web` at 1b745c6 (the spec commit). Implement in the main checkout `/Users/willem/Projects/AgentOS`, on branch `lan-web`. Read `.superpowers/sdd/context.md` for the build host workflow (devvm, `devvm.sh`, `TMPDIR=/var/tmp`, foreground polling).

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-10-31-agentos-lan-web-design.md`). When this plan and the spec disagree, the spec wins, except for the deliberate, evidenced adjustments listed under "Spec adjustments" below.

- Opt-in setting `AGENTOS_WEB_LAN`: `0` or `1`, default `0`.
- HTTPS on port 443 with a self-signed certificate generated on the box. The fingerprint is shown on the console.
- Login with the `agent` account's system password (set by the installer).
- Session cookie, idle expiry, rate limiting, audit, and the same CSRF rules as today.
- **Non-goals:** other users or accounts besides `agent`; ACME or Let's Encrypt certificates for LAN names; HTTP on port 80; exposing anything other than the web UI. noVNC, MCP HTTP and SSH keep their current rules, but desktop viewing works through the web UI's own `/vnc` WebSocket proxy.
- `AGENTOS_WEB_LAN=0|1` in `/etc/agentos/agentos.env`, validated in `env.sh` like the other 0/1 settings.
- Where it can be set: the interactive installer asks "Allow the web UI on your local network (password login)?", default no; `agentos.env` for unattended installs and cloud-init; `sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply`; the agentos-config menu; the web UI Settings page.
- `apply` (firstboot) does three things when the setting is on: 1. generates the certificate if it is missing; 2. opens the firewall; 3. writes `LAN=1` (plus the certificate fingerprint) into `/etc/agentos/web.conf`, which the web server reads. It then restarts `agentos-web`.
- **Requirement:** the `agent` account must have a usable password. If it doesn't, `apply` refuses to enable LAN access and says to set one first (`sudo agentos-config password`).
- Certificate: generated once with `openssl` (ECDSA P-256, 10-year validity) as `/etc/agentos/web-lan/cert.pem` and `/etc/agentos/web-lan/key.pem`. The key is readable only by root and by the user the web server runs as; the plan verifies which user that is. The SAN covers the hostname, `<hostname>.local`, and the IPv4 addresses present at generation time. Browsers warn about self-signed certificates regardless, and the warning is checked against the fingerprint.
- The certificate is kept across reboots and updates. Deleting it forces a new one on the next `apply`.
- The SHA-256 fingerprint is written to `web.conf`. It is shown on the console banner, by `sudo agentos-config` (menu, plus a `show-web-fingerprint` command) and in the web UI's System page.
- The existing loopback listener (`127.0.0.1:7070`, Tailscale identity) is **unchanged**.
- When `LAN=1`, the same process adds an HTTPS listener on `0.0.0.0:443`. It reuses the same route registration and runs a separate auth mode, so a request is decided by the listener it arrived on. The plan verifies how to bind port 443 as a non-root service: `CAP_NET_BIND_SERVICE` through `AmbientCapabilities`, or root. Do not weaken the existing service hardening beyond that.
- **Host check:** the Host header must be the box's hostname, `<hostname>.local`, or one of its current IP addresses (IPv4/IPv6 literal, optionally with `:443`). Anything else gets 403. This blocks DNS rebinding.
- **Origin:** `https://<Host>` exactly.
- **Firewall:** the nftables rule accepts 443/tcp on non-tailscale interfaces only while `AGENTOS_WEB_LAN=1`. With the setting off, 443 is closed (except the existing Tailscale serve path on the tailnet interface).
- **Unauthenticated requests:** a GET for a page returns the login page, a static HTML form with no third-party resources; API calls and WebSocket upgrades get 401.
- **`POST /api/lan/login`** with `{password}`: checks the password against the `agent` account through a root-owned helper the web server runs via a fixed sudo rule. The helper reads the password on stdin and never takes it in argv, so it never appears in sudo's log. On success, creates a session: a 256-bit random token, stored in memory only, with a 12-hour idle timeout and a 7-day absolute limit; sets the cookie `__Host-agentos-session` (`Secure; HttpOnly; SameSite=Strict; Path=/`); audits `agent@lan(<ip>) login`. On failure, audits `login failed` and returns 401 after a constant 1 s delay.
- **Rate limiting:** at most 5 failed logins per IP per 10 minutes; after that, 429 until the window passes. There is also a global cap of 30 failures per 10 minutes across all IPs, so a distributed guesser is slowed too.
- **`POST /api/lan/logout`** deletes the session, clears the cookie and audits the logout.
- **Authorization:** an authenticated LAN session has the same permissions as an allowed Tailscale user. The `login` used in the audit log is `agent@lan(<ip>)`. CSRF rules are unchanged: Origin plus `X-AgentOS: 1` for unsafe methods and upgrades.
- A web server restart clears all sessions, which is documented.
- **The console banner** (`/etc/issue`, rendered by firstboot or console-apply) always has a `Web UI:` line: `Web UI: https://<lan-ip>  (LAN login; certificate SHA-256 AB:CD:…)` when LAN access is on, one line per IPv4 address, at most two; `Web UI: https://<tailnet-name>` when Tailscale serve is active (both can be shown); otherwise `Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)`.
- **The installer's summary screen** says how the web UI will be reachable.
- Security: the web UI is root-equivalent, so LAN access trusts everyone who can reach the box's LAN address and knows the `agent` password. The docs say so, and recommend Tailscale for anything beyond a trusted home or lab network. The password is never logged, never put in argv and never sent over plain HTTP. Sessions are in memory, with no persistent tokens. Brute force is rate-limited.
- Testing: unit tests (web server, vitest) for mode selection per listener; the Host allowlist, including IPs, `hostname.local` and a rejected rebinding host; login success and failure; the constant delay; rate limiting, per IP and global; session expiry, idle and absolute; cookie flags; logout; WebSocket upgrades with and without a session; CSRF on the LAN listener; the Tailscale listener unchanged. Unit tests (shell) for the password helper (correct, wrong, empty, no password set, argv never contains the password), certificate generation, and the `apply` behaviour. In the VM: with the setting off, 443 is closed; with it on: from the host, `curl -k https://<guest>/` shows the login page; a wrong password gets 401, and the 6th attempt gets 429; the right password gets a cookie, and `/api/me` works; an unsafe action without `X-AgentOS` gets 403, and with it succeeds; a terminal WebSocket works; the console banner shows the URL and fingerprint; Tailscale access checks still pass.

Repo conventions (from the earlier plans):
- Bash scripts are `#!/bin/bash` with `set -euo pipefail` and must be `shellcheck -S warning` clean. `check-password` is perl (`use strict; use warnings;`), checked with `perl -c`.
- Checks in `test/checks/*.sh` use `&&` chains. Don't rely on `set -e` inside check functions. Check names are unique; `smoke.sh` runs them sorted by name, so every check sets up its own state and puts it back.
- Smoke tests on devvm run with `TMPDIR=/var/tmp`. Never touch devvm's existing Docker containers or volumes; never prune. devvm's `/tmp` is a 3.9 GB tmpfs: never copy the repo (with `mkosi.output`) there.
- UI: React only, no UI framework, one stylesheet. Server: every exec goes through the `Runner` and the fixed actions table.

## Facts verified while writing this plan (2026-10-31)

| Fact | How | Result |
|---|---|---|
| Checking the `agent` password from a root helper on trixie | `docker run --rm debian:trixie`: `useradd agent; echo 'agent:pw with spaces' \| chpasswd`; devvm (Debian 13); the last image's `agentos.manifest` | Python 3.13.5 has no `crypt` (`ModuleNotFoundError: No module named 'crypt'`). `pamtester` (0.1.2-4) and `whois`/`mkpasswd` (5.6.3) exist in trixie but neither is in the image: each is a new package. **`perl-base` 5.40.1-6+deb13u1 is `Essential: yes` and in the image**, and its `crypt()` is libxcrypt's (`libcrypt1` 1:4.4.38-1): it verifies chpasswd's default `$y$j9T$…` (yescrypt, `ENCRYPT_METHOD YESCRYPT` in `login.defs`) and `$6$` (the installer's `openssl passwd -6`). Chosen: a perl helper reading `/etc/shadow` itself, so the hash is never in any argv. |
| The helper through sudo | Same container, with `sudo` 1.9.16, `agent ALL=(ALL) NOPASSWD:ALL` (the image's rule) and `Defaults logfile=/tmp/sudo.log` | `printf '%s\n' 'pw with spaces' \| sudo -n check-password` → 0, a wrong one → 1; after `passwd -l` → 2; after `passwd -d` → 2 (an empty hash must never mean "any password"); as `agent` without sudo → 2 (can't read shadow). sudo's log has `COMMAND=/usr/local/sbin/check-password` and no password. trixie's `/etc/sudoers` Defaults: `env_reset`, `mail_badpass`, `secure_path`, `use_pty`; no `log_input`, so stdin is not recorded. `test/check_password_test.sh` (Task 1) passes on devvm. |
| Who runs `agentos-web` | `package/usr/lib/systemd/system/agentos-web.service`, `package/etc/sudoers.d/agent` | `User=agent` (uid 1000, group `agent`), `NoNewPrivileges=no`, `ProtectHome=no`, `PrivateTmp=no`, `KillMode=process`. `agent` has `NOPASSWD:ALL`; the server already runs `sudo -n agentos-config …` from its actions table. So the key is `root:agent 0640` in `root:agent 0750` `/etc/agentos/web-lan`, and the existing sudo rule already covers the helper. |
| **Port 443 and `tailscale serve`** | devvm (tailscale 1.102.2, kernel TUN mode; the image has 1.104.4): `tailscale serve --bg --tcp=443 tcp://127.0.0.1:7999`, then a node 0.0.0.0:443 listener; and the reverse order with python (`SO_REUSEADDR`); `ss -Htlnp 'sport = :443'`; serve config removed afterwards (`No serve config`) | tailscaled binds **real sockets** for serve: `100.76.180.25:443` and `[fd7a:115c:a1e0::ea35:b41b]:443`. A later `0.0.0.0:443` bind fails with **`EADDRINUSE`**. With `0.0.0.0:443` held first, tailscaled got only its IPv6 socket: IPv4 Tailscale serve was lost. From the Mac, the tailnet name reached serve. So the LAN listener can't be on 443 at all, whatever its privileges. |
| `AmbientCapabilities=CAP_NET_BIND_SERVICE` | devvm: `systemd-run --wait --pipe -p User=nobody -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p NoNewPrivileges=no python3 …` binding 127.0.0.1:444 | It binds as `nobody` (without it: `[Errno 13] Permission denied`), and **every child inherits it** (`CapAmb: 0000000000000400` in a subprocess): tmux, the agents' shells and CI would all get it. Not used: the redirect below needs no capability and leaves the unit as it is. |
| nftables redirect 443 → 7443 | devvm: a network namespace with `eth0` (10.99.0.2, fd99::2) and a veth named `tailscale0` (10.98.0.2), the new `firewall.nft` loaded in it, a listener on `10.98.0.2:443` (standing in for tailscaled) and node on `[::]:7443`; cleaned up after | `lan_web` empty: `10.99.0.2:443` times out, `tailscale0`'s 443 answers `SERVE`. `lan_web = { 443 }`: `10.99.0.2:443` → `LAN ::ffff:10.99.0.1`, `[fd99::2]:443` → `LAN fd99::1`, `tailscale0`'s 443 still `SERVE`, and `10.99.0.2:7443` direct **times out** (`tcp dport 7443 ct status dnat accept` lets only redirected flows in). A redirected IPv4 client shows up as `::ffff:a.b.c.d` on the dual-stack socket. |
| Two Fastify apps, one process | Scratch script with the repo's `node_modules` (fastify 5.12.7, @fastify/websocket 11.3.4, ws 8.22.0), Node 22 on the Mac | Two instances from one build function, one plain on 127.0.0.1, one `Fastify({ https })` on `::` (IPv4 and `[::1]` both answer): each runs its own `onRequest` hook; module state is shared (one counter across both, like `system.ts`'s update lock); `ws://` and `wss://` upgrades work on each; `injectWS` works on the HTTPS instance (`onInit` attaches the listener before the first frame). `close()` with a request in flight: the response still arrives (`{"slow":"done"}`); an open WebSocket is closed (1005); the close took 6.3 s, so `main.ts` caps it at 5 s. `serverFactory` would need hand-wiring `upgrade` events; not needed. |
| Certificate and fingerprint | devvm, OpenSSL 3.5.7 (the image: 3.5.7-1~deb13u3); `test/web_lan_cert_test.sh` (Task 1) | `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 -subj /CN=<h> -addext subjectAltName=DNS:<h>,DNS:<h>.local,IP:… -addext extendedKeyUsage=serverAuth` works in one call. `openssl x509 -noout -fingerprint -sha256` prints `sha256 Fingerprint=B4:A0:…:A9:B8` (32 uppercase hex pairs, 95 characters): `sed 's/^[^=]*=//'`. `-checkend` drives the renewal. |
| Certificate lifetime on Apple clients | support.apple.com/103769, "Requirements for trusted certificates in iOS 13 and macOS 10.15" | "TLS server certificates must have a validity period of 825 days or fewer", must carry EKU `id-kp-serverAuth`, and "Connections to TLS servers violating these new requirements will fail … and websites to not load in Safari". The page doesn't exempt self-signed certificates. Not tested in a browser here (manual check 2). |
| `firewall.nft` and `agentos-firewall` | the files | One `table inet agentos`, recreated with `delete table` (Docker's and Tailscale's tables untouched), sets filled at apply time (`public_tcp` gets 22 for `AGENTOS_LAN_SSH`). Input `policy drop`, `iifname "tailscale0" accept`. So the toggle is a second set, `lan_web`, filled by `agentos-firewall`, and the rules themselves are static. |
| The console | `mkosi.extra/etc/issue` (owned by `base-files`, Plan 6), `agentos-firstboot`, `agentos-console-apply`; `agentos-firstboot.service` | `/etc/issue` is static (`\4`, `\4{tailscale0}`); firstboot already writes `/run/issue.d/50-agentos-web.issue` (only for a failed serve). `agentos-firstboot.service` is `After=network-online.target`, so DHCP addresses exist for the SAN and the banner. agetty prints `/run/issue.d/*.issue` after `/etc/issue`, and `agetty --reload` makes running agettys reprint it. |
| mDNS | the image manifest | No `avahi-daemon`, no `libnss-mdns`. `<hostname>.local` is accepted as a Host and in the SAN, and works where the network already resolves it. |
| Tests before this plan | `npx vitest run` | Server 111 passed, 1 skipped; UI 24 passed. |

All code in this plan was run while writing it:
- **vitest:** server **134 passed, 1 skipped** (+23: `lan.test.ts` 21, one each in `settings.test.ts` and `system.test.ts`), UI **29 passed** (+5, `lan.test.tsx`). Both packages pass `tsc`; the UI builds.
- **bash, on devvm:** `check_password_test.sh`, `web_lan_cert_test.sh`, `web_conf_test.sh` (both Task 1's part and the whole file with Task 4's part, each against its own `web-conf`), `env_test.sh`, `installer_test.sh`, and the existing `web_serve_test.sh`, `configure_test.sh`, `update_check_test.sh`. `perl -c check-password`: syntax OK.
- **shellcheck:** every new or changed bash file is `shellcheck -S warning` clean, including `96-web.sh` and `smoke.sh`.
- **Not run while writing:** an image build and the VM checks (Task 5), and a real browser (manual checks).

## Spec adjustments (with evidence)

1. **The LAN listener is `[::]:7443`, reached on 443 through an nftables redirect, instead of a socket on `0.0.0.0:443`.** tailscaled holds `<tailnet-ip>:443` for `tailscale serve`; a `0.0.0.0:443` socket either fails (`EADDRINUSE`) or, bound first, takes IPv4 serve away from Tailscale (fact table). The redirect applies on every interface but `tailscale0`, only while `lan_web` holds 443. `agentos-web` needs no capability (Ambient capabilities would also pass to every agent process), so the unit is unchanged. Browsers still use `https://<address>` on 443, and IPv6 works too.
2. **No new sudo rule.** `agent` already has `NOPASSWD:ALL`, and the server already runs its privileged actions through `sudo -n` from the fixed actions table. The helper is one more entry there (`check-password`, a fixed path, no arguments: it refuses any with exit 64).
3. **The certificate is valid for 825 days, with `extendedKeyUsage=serverAuth`, and is made again on apply when it is within 30 days of expiring** (firstboot runs every boot). Apple's TLS rules refuse longer-lived server certificates (fact table). The fingerprint then changes; the console, `agentos-config` and the System page show the new one.
4. **The console shows the fingerprint once, on two lines of 16 bytes**, below at most two `Web UI: https://<ip>  (LAN login)` lines. A SHA-256 fingerprint is 95 characters, so the spec's one-line form doesn't fit an 80-column console.
5. **"Opens the firewall" follows `web.conf`, not `agentos.env`.** `agentos-firewall` adds 443 to `lan_web` when `web.conf` has `LAN=1`, which `web-conf` writes only once it has found a password and made the certificate; firstboot reloads the firewall when that changes.
6. **firstboot's web step moves into `web-conf`** (`/usr/local/lib/agentos/web-conf`), so the apply behaviour has a shell unit test. It prints `restart` when the `LAN=`/`FINGERPRINT=` lines change; only then does firstboot restart `agentos-web` (a restart drops open terminals, so it isn't done on every apply). `agentos-web` closes gracefully on SIGTERM (at most 5 s), so the Settings save that caused the restart still gets its answer.
7. **How "apply refuses" is said.** Without a usable password, `web-conf` leaves `LAN=0` and warns in the journal; the console shows `Web UI: off …`. `sudo agentos-config apply` exits 3 with "LAN access to the web UI is not on: set a password for agent first (sudo agentos-config password), then apply again"; the web UI's Settings page shows that line (the server now reports apply's last stderr line). The installer asks the LAN question only after a password was entered, and an unattended install with `AGENTOS_WEB_LAN=1` but no `AGENTOS_PASSWORD_HASH` fails before the disk is touched. `agentos-config set` itself doesn't check: the installer sets settings before it sets the password.
8. **The login page comes with status 401** (HTML), not 200, so nothing caches it or mistakes it for a page of the UI.
9. **Rate limiting counts an attempt from its start and forgives it on success,** so parallel guesses from one address can't all pass the check before the first one fails. Answers of 429 are not audited (each failure is, up to the cap of 30 per 10 minutes).
10. **The API gains `lan` in `GET /api/me` and `GET /api/system/lan`** (`{enabled, fingerprint, addresses}`) for the Logout button and the System page. The LAN listener's API 401 body is `log in first`; the UI reloads on it, which shows the login page after a session expires.
11. **The Host allowlist is every address of the box's interfaces** (from `os.networkInterfaces()` at request time, IPv6 in brackets), plus the hostname and `<hostname>.local`, each optionally with `:443`. A Docker or loopback address in Host still needs a session.
12. **A session isn't bound to an address** (phones change networks); the audit login uses the request's own address.

## Security

- **The password's path.** The browser sends it only over HTTPS (the LAN listener has no HTTP side, and there is no port 80), as JSON to `POST /api/lan/login`. Fastify logs at `warn` and never logs bodies; the error handler logs only 5xx errors, and no 5xx carries the body. The route checks it is a non-empty string of at most 1024 characters with no CR, LF or NUL (a newline would end the helper's line), then passes `<password>\n` as the Runner's `input`, so `execFile` writes it to the helper's stdin. The argv is the fixed `['sudo', '-n', '/usr/local/lib/agentos/check-password']`; sudo logs only argv (no `log_input`, fact table). The helper reads at most 1025 bytes from stdin, reads `/etc/shadow` itself (the hash is never in an argv either), prints nothing and only exits 0, 1, 2 or 64. The audit lines are `agent@lan(<ip>) login -`, `login-failed -` and `logout -`; the tests check that neither the argv, the audit lines nor the response hold the password, and the VM check greps the whole journal for it.
- **Constant-time comparisons.** The helper compares `crypt()`'s result with the stored hash by XOR over the whole string and a count of non-NUL bytes, never with `eq`. Session lookups never compare the secret token: the map's keys are SHA-256 digests. The fixed 1 s failure delay, counted from the start of the request, also hides how long the helper took (a locked account answers faster than a yescrypt check).
- **Session tokens.** `crypto.randomBytes(32)` (256 bits), base64url (43 characters). The server keeps only `sha256(token)` → `{created, seen}` in memory; a restart forgets every session. The cookie is `__Host-agentos-session=<token>; Secure; HttpOnly; SameSite=Strict; Path=/` with no `Max-Age` (a browser session), and the server enforces 12 h idle and 7 days absolute. Logout deletes the entry and sends `Max-Age=0`.
- **What stays as it is:** the CSRF rule (Origin `https://<Host>` plus `X-AgentOS: 1` for every unsafe method and every upgrade, `Sec-Fetch-Site: cross-site` refused except top-level GET navigation), the anti-framing headers, the actions table, and the loopback listener with its identity rules. The Tailscale identity header means nothing on the LAN listener, and a session cookie means nothing on the loopback one (tests).

## File map

```
package/usr/local/lib/agentos/check-password       NEW  perl: is stdin agent's password? (root, via sudo -n)
package/usr/local/lib/agentos/web-lan-cert         NEW  makes/keeps /etc/agentos/web-lan/{cert,key}.pem, prints the fingerprint
package/usr/local/lib/agentos/web-conf             NEW  firstboot's web step: serve, certificate, web.conf, console lines
package/usr/local/lib/agentos/env.sh               MOD  AGENTOS_WEB_LAN validation, agent_has_password, lan_ipv4s
package/usr/local/lib/agentos/firewall.nft         MOD  lan_web set, prerouting redirect 443 -> 7443, input accept for redirected 7443
package/usr/local/sbin/agentos-firewall            MOD  443 into lan_web when web.conf has LAN=1
package/usr/local/sbin/agentos-firstboot           MOD  step 5b calls web-conf; restart/firewall on a LAN change; agetty --reload
package/usr/local/bin/agentos-config               MOD  apply refuses without a password; weblan/webfp menu items; show-web-fingerprint
web/server/src/lan.ts                              NEW  LAN auth hook, sessions, rate limits, login page, login/logout routes
web/server/src/{auth,actions,app,system,settings,main}.ts  MOD
web/server/test/lan.test.ts                        NEW
web/server/test/{auth,settings,system}.test.ts     MOD
web/ui/src/{api.ts,App.tsx,types.ts,pages/System.tsx,pages/Settings.tsx,style.css}  MOD
web/ui/test/lan.test.tsx                           NEW
installer/mkosi.extra/usr/local/sbin/agentos-install           MOD  the LAN question, the summary line, the unattended check
installer/mkosi.extra/usr/lib/agentos-installer/lib.sh         MOD  web_ui_summary
installer/mkosi.extra/usr/share/agentos/data/agentos.env.example  MOD
test/{check_password,web_lan_cert,web_conf}_test.sh  NEW  bash unit tests
test/{env,installer}_test.sh                       MOD
test/checks/96-web.sh                              MOD  LAN checks; check_web_conf_published
test/smoke.sh                                      MOD  forward host port PORT+4 to the guest's 443
test/web_ws.mjs                                    MOD  LAN mode (WS_COOKIE, WS_HOST)
.github/workflows/build.yml                        MOD  lint and run the new tests
README.md                                          MOD  Reaching the box, The web UI, Security model, Settings reference
```

## Working locally

- **Bash unit tests** run on devvm: `.superpowers/sdd/devvm.sh sh 'test/<name>_test.sh'`. They run as root there and unprivileged in CI; none of them touches the host's `/etc/shadow`, `/etc/agentos`, systemd or nftables (fake files and fake commands on `PATH`).
- **Web tests** on the Mac: `npx tsc -p tsconfig.json --noEmit && npx vitest run` in `web/server`; `npx tsc -p tsconfig.json && npx vitest run && npm run build` in `web/ui`.
- **shellcheck and `perl -c`** run on devvm.
- **The VM** (Task 5): `.superpowers/sdd/devvm.sh run 'AGENTOS_DEV=1 tools/build-deb.sh && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi'`, then `devvm.sh wait <JOB>` until it isn't 124. `SMOKE_ONLY=web_` re-runs only the web checks.

---
### Task 1: The setting, the password helper, the certificate, the firewall and `web.conf`, through firstboot and apply

**Files:**
- Create: `package/usr/local/lib/agentos/check-password` (mode 755), `package/usr/local/lib/agentos/web-lan-cert` (mode 755), `package/usr/local/lib/agentos/web-conf` (mode 755), `test/check_password_test.sh`, `test/web_lan_cert_test.sh`, `test/web_conf_test.sh` (all mode 755)
- Modify: `package/usr/local/lib/agentos/env.sh`, `package/usr/local/lib/agentos/firewall.nft`, `package/usr/local/sbin/agentos-firewall`, `package/usr/local/sbin/agentos-firstboot` (step 5b), `package/usr/local/bin/agentos-config` (`cmd_apply`), `test/env_test.sh`, `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `env.sh` (`env_get`, `validate_setting`, `AGENTOS_ENV`), `web-serve` (prints `ok | off | tailscale-down | failed: <why>`).
- Produces:
  - `check-password`: stdin = the password (first line, at most 1024 bytes); exit 0 right, 1 wrong/empty, 2 no usable password, 64 any argument. Test hook: `AGENTOS_SHADOW`.
  - `web-lan-cert`: makes `/etc/agentos/web-lan/{cert.pem 0644, key.pem 0640 root:agent}` (dir `0750 root:agent`) when missing or within 30 days of expiry; prints the fingerprint `XX:…:XX` (95 characters). Test hooks: `WEB_LAN_DIR`, `WEB_LAN_GROUP`, `AGENTOS_LIB`.
  - `web-conf`: writes `/etc/agentos/web.conf` (0644) as `USERS=`, `ENABLED=0|1`, `SERVE=`, `LAN=0|1`, `FINGERPRINT=` (empty unless `LAN=1`); prints `restart` when the `LAN=`/`FINGERPRINT=` lines changed. Test hooks: `AGENTOS_LIB`, `AGENTOS_ETC`, `ISSUE_DIR`, `TAILSCALE`.
  - `env.sh`: `agent_has_password` (0 when `passwd -S agent` says `P`), `lan_ipv4s` (the box's IPv4 addresses, not `lo`, `tailscale*`, `docker*`, `br-*`, `veth*`, one per line).
  - nftables: set `inet agentos lan_web` (`inet_service`); LAN listener port 7443.
  - `agentos-config apply` exits 3, with the message above as its last stderr line, when `AGENTOS_WEB_LAN=1` and `agent` has no usable password.

- [ ] **Step 1: Write the failing tests**

`test/check_password_test.sh`:
```bash
#!/bin/bash
# Unit test for check-password (the LAN login's password check) against a fake shadow file.
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos/check-password
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export AGENTOS_SHADOW=$d/shadow
PW='correct horse:battery$staple'
# A yescrypt hash (passwd/chpasswd's default on trixie) and a SHA-512 one (the installer's).
y=$(perl -e 'print crypt($ARGV[0], q($y$j9T$) . q(F5Jx5fExrKuPp53xLKQ..1))' "$PW")
s6=$(perl -e 'print crypt($ARGV[0], q($6$saltsaltsalt$))' "$PW")
[[ $y == '$y$j9T$'* && $s6 == '$6$'* ]] || { echo "this libcrypt cannot make the test hashes: $y $s6" >&2; exit 1; }
shadow() { printf 'root:*:20000:0:99999:7:::\nagent:%s:20000:0:99999:7:::\nother:%s:20000::::::\n' "$1" "$y" > "$AGENTOS_SHADOW"; }
rc() { local r=0; "$S" "$@" || r=$?; echo "$r"; }

for h in "$y" "$s6"; do
  shadow "$h"
  [ "$(printf '%s\n' "$PW" | rc)" = 0 ]                  # right, with the newline the server sends
  [ "$(printf '%s' "$PW" | rc)" = 0 ]                    # right, no newline
  [ "$(printf '%s\n' "${PW}x" | rc)" = 1 ]               # wrong
  [ "$(printf '%s\n' "${PW%?}" | rc)" = 1 ]              # a prefix
  [ "$(printf '\n' | rc)" = 1 ]                          # empty
  [ "$(rc </dev/null)" = 1 ]                             # nothing on stdin
  [ "$(printf '%s\nextra\n' "$PW" | rc)" = 0 ]           # only the first line counts
  [ "$(head -c 2000 /dev/zero | tr '\0' a | rc)" = 1 ]   # longer than 1024 bytes
done
# No usable password: none, locked, empty (which would accept anything), no agent line.
for h in '!' '*' "!$y" ''; do shadow "$h"; [ "$(printf '%s\n' "$PW" | rc)" = 2 ]; [ "$(printf '\n' | rc)" = 2 ]; done
printf 'root:*:20000::::::\n' > "$AGENTOS_SHADOW"; [ "$(printf '%s\n' "$PW" | rc)" = 2 ]
[ "$(printf '%s\n' "$PW" | AGENTOS_SHADOW=$d/missing rc)" = 2 ]
# Never takes the password in argv: any argument is refused before stdin is read.
shadow "$y"; [ "$(printf '%s\n' "$PW" | rc "$PW")" = 64 ]
# Prints nothing, on any outcome.
[ -z "$(printf '%s\n' "$PW" | "$S" 2>&1)" ]
[ -z "$(printf 'x\n' | "$S" 2>&1 || true)" ]
echo "check-password OK"
```

`test/web_lan_cert_test.sh`:
```bash
#!/bin/bash
# Unit test for web-lan-cert (the web UI's LAN certificate) in a temporary directory.
set -euo pipefail
export AGENTOS_LIB; AGENTOS_LIB=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos
S=$AGENTOS_LIB/web-lan-cert
# shellcheck source=../package/usr/local/lib/agentos/env.sh
. "$AGENTOS_LIB/env.sh"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export WEB_LAN_DIR=$d/web-lan WEB_LAN_GROUP; WEB_LAN_GROUP=$(id -gn)
FP_RE='^([0-9A-F]{2}:){31}[0-9A-F]{2}$'

fp=$("$S"); [[ $fp =~ $FP_RE ]] || { echo "bad fingerprint: $fp" >&2; exit 1; }
[ "$(stat -c '%a' "$WEB_LAN_DIR")" = 750 ]
[ "$(stat -c '%a %G' "$WEB_LAN_DIR/key.pem")" = "640 $WEB_LAN_GROUP" ]
[ "$(stat -c '%a' "$WEB_LAN_DIR/cert.pem")" = 644 ]
txt=$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -text)
grep -q 'ASN1 OID: prime256v1' <<< "$txt"
grep -q 'TLS Web Server Authentication' <<< "$txt"
h=$(hostname); grep -q "DNS:$h, DNS:$h.local" <<< "$txt"
for ip in $(lan_ipv4s); do
  grep -q "IP Address:$ip" <<< "$txt" || { echo "SAN lacks $ip" >&2; exit 1; }
done
openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -checkend $((824 * 86400)) >/dev/null
if openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -checkend $((826 * 86400)) >/dev/null; then echo "valid beyond 825 days" >&2; exit 1; fi
# The key matches the certificate.
[ "$(openssl pkey -in "$WEB_LAN_DIR/key.pem" -pubout)" = "$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -pubkey)" ]
# Kept: a second run prints the same fingerprint and leaves the files alone.
[ "$("$S")" = "$fp" ]
# Deleted: made again, with a new fingerprint.
rm "$WEB_LAN_DIR/cert.pem"; fp2=$("$S"); [[ $fp2 =~ $FP_RE ]]; [ "$fp2" != "$fp" ]
# Expiring within 30 days: made again.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 10 -subj /CN=old \
  -keyout "$WEB_LAN_DIR/key.pem" -out "$WEB_LAN_DIR/cert.pem" 2>/dev/null
old=$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')
fp3=$("$S"); [ "$fp3" != "$old" ]; openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -checkend $((800 * 86400)) >/dev/null
echo "web-lan-cert OK"
```

`test/web_conf_test.sh` (Task 4 appends the console lines' part):
```bash
#!/bin/bash
# Unit test for web-conf (firstboot's web UI step) with fake passwd, ip, tailscale, web-serve and
# web-lan-cert.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/lib" "$d/bin" "$d/etc"
ln -s "$R/env.sh" "$d/lib/env.sh"
FP=B4:A0:73:5F:85:CC:CE:06:76:AE:B3:64:CA:36:6A:F8:BC:6B:EF:B4:BC:FD:7F:9C:0E:CB:D9:6E:DE:D2:A9:B8
cat > "$d/lib/web-serve" <<'FAKE'
#!/bin/bash
if [ "$1" = 0 ]; then echo off; else echo "$FAKE_SERVE"; fi
FAKE
cat > "$d/lib/web-lan-cert" <<'FAKE'
#!/bin/bash
echo cert >> "$FAKE_LOG"; [ "$FAKE_CERT" = ok ] && echo "$FP"
FAKE
cat > "$d/bin/passwd" <<'FAKE'
#!/bin/bash
echo "agent $FAKE_PW 2026-10-31 0 99999 7 -1"
FAKE
cat > "$d/bin/ip" <<'FAKE'
#!/bin/bash
printf '%s\n' '2: enp1s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic enp1s0' \
  '3: tailscale0    inet 100.64.0.9/32 scope global tailscale0' '4: docker0    inet 172.17.0.1/16 scope global docker0' \
  '5: wlan0    inet 10.0.0.7/24 scope global wlan0' '6: enp2s0    inet 10.0.1.7/24 scope global enp2s0'
FAKE
cat > "$d/bin/tailscale" <<'FAKE'
#!/bin/bash
echo '{"Self":{"DNSName":"box.tail1234.ts.net."}}'
FAKE
chmod +x "$d/lib/"web-* "$d/bin/"*
export PATH=$d/bin:$PATH AGENTOS_LIB=$d/lib AGENTOS_ETC=$d/etc ISSUE_DIR=$d/issue.d FAKE_LOG=$d/log FP
ISSUE=$d/issue.d/50-agentos-web.issue
# run <AGENTOS_WEB_LAN> <passwd -S state> <serve> [cert ok|fail] [AGENTOS_WEB]: prints web-conf's stdout
run() {
  printf 'AGENTOS_WEB_USERS=a@b.com\nAGENTOS_WEB_LAN=%s\nAGENTOS_WEB=%s\n' "$1" "${5:-1}" > "$d/etc/agentos.env"
  : > "$FAKE_LOG"
  FAKE_PW=$2 FAKE_SERVE=$3 FAKE_CERT=${4:-ok} "$R/web-conf" 2> "$d/err"
}
fail() { echo "FAIL: $*"; echo "--- web.conf"; cat "$d/etc/web.conf"; echo "--- issue"; cat "$ISSUE" 2>/dev/null; echo "--- stderr"; cat "$d/err"; exit 1; } >&2
conf() { cat "$d/etc/web.conf"; }

# On, with a password: LAN=1 and the fingerprint; the first run changes the listener, the next doesn't.
[ "$(run 1 P tailscale-down)" = restart ] || fail "first run: restart"
[ "$(conf)" = "$(printf 'USERS=a@b.com\nENABLED=1\nSERVE=tailscale-down\nLAN=1\nFINGERPRINT=%s' "$FP")" ] || fail "web.conf, LAN on"
[ "$(stat -c %a "$d/etc/web.conf")" = 644 ] || fail "web.conf mode"
[ -z "$(run 1 P tailscale-down)" ] || fail "second run: no restart"
[ -z "$(run 1 P ok)" ] || fail "a serve change is no LAN change"
# No usable password (locked or none): refused, and it says how to fix it; no certificate is made.
for pw in L NP; do
  run 1 "$pw" tailscale-down >/dev/null
  grep -qx 'LAN=0' "$d/etc/web.conf" && grep -qx 'FINGERPRINT=' "$d/etc/web.conf" || fail "no password ($pw): LAN stays off"
  grep -q 'needs a password for agent (sudo agentos-config password)' "$d/err" || fail "no password ($pw): warning"
  [ ! -s "$FAKE_LOG" ] || fail "no password ($pw): certificate made anyway"
done
# Turning it on again changes the listener; turning it off too.
[ "$(run 1 P tailscale-down)" = restart ] || fail "on again: restart"
[ "$(run 0 P tailscale-down)" = restart ] || fail "off: restart"
grep -qx 'LAN=0' "$d/etc/web.conf" || fail "off: LAN=0"
# The certificate can't be made: off, with a warning.
run 1 P tailscale-down fail >/dev/null
grep -qx 'LAN=0' "$d/etc/web.conf" && grep -q 'could not make the LAN certificate' "$d/err" || fail "cert failure"
# The web UI off (AGENTOS_WEB=0) turns LAN access off too.
run 1 P ok ok 0 >/dev/null
grep -qx 'ENABLED=0' "$d/etc/web.conf" && grep -qx 'LAN=0' "$d/etc/web.conf" && grep -qx 'SERVE=off' "$d/etc/web.conf" || fail "web off"
# tailscale serve failed: a warning, and the console says why.
run 0 P 'failed: Serve is not enabled on your tailnet.' >/dev/null
grep -q 'warning: web UI: tailscale serve failed' "$d/err" || fail "serve failed warning"
grep -qx 'Web UI: tailscale serve failed: Serve is not enabled on your tailnet.' "$ISSUE" || fail "serve failed line"
# An invalid AGENTOS_WEB_LAN is the default (off).
printf 'AGENTOS_WEB_LAN=yes\n' > "$d/etc/agentos.env"; FAKE_PW=P FAKE_SERVE=off FAKE_CERT=ok "$R/web-conf" >/dev/null 2>&1
grep -qx 'LAN=0' "$d/etc/web.conf" || fail "invalid value"
echo "web-conf OK"
```

```bash
chmod 755 test/check_password_test.sh test/web_lan_cert_test.sh test/web_conf_test.sh
```

In `test/env_test.sh`, find:
```bash
ok AGENTOS_SOLENTA 0; ok AGENTOS_SOLENTA 1; bad AGENTOS_SOLENTA yes
```
Replace with:
```bash
ok AGENTOS_SOLENTA 0; ok AGENTOS_SOLENTA 1; bad AGENTOS_SOLENTA yes
ok AGENTOS_WEB_LAN 0; ok AGENTOS_WEB_LAN 1; ok AGENTOS_WEB_LAN ''; bad AGENTOS_WEB_LAN yes; bad AGENTOS_WEB_LAN 2
```

- [ ] **Step 2: Run them to see them fail**

Run: `.superpowers/sdd/devvm.sh sh 'for t in check_password web_lan_cert web_conf env; do test/${t}_test.sh >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done'`
Expected:
```
FAIL check_password
FAIL web_lan_cert
FAIL web_conf
FAIL env
```
(`env`: "should reject AGENTOS_WEB_LAN='yes'", because unknown keys are not checked yet.)

- [ ] **Step 3: The helpers in `env.sh`**

In `package/usr/local/lib/agentos/env.sh`, find:
```bash
    AGENTOS_LAN_SSH|AGENTOS_AUTO_REBOOT|AGENTOS_WEB|AGENTOS_SOLENTA) re='^[01]$'; want='0 or 1' ;;
```
Replace with:
```bash
    AGENTOS_LAN_SSH|AGENTOS_AUTO_REBOOT|AGENTOS_WEB|AGENTOS_WEB_LAN|AGENTOS_SOLENTA) re='^[01]$'; want='0 or 1' ;;
```
Append to the end of the file:
```bash

# agent_has_password: 0 if agent has a usable password (passwd -S says P: not none, not locked).
agent_has_password() { [ "$(passwd -S agent 2>/dev/null | awk '{print $2}')" = P ]; }

# lan_ipv4s: this box's IPv4 addresses on the local network, one per line: not loopback, Tailscale
# or Docker's bridges (the web server's lanAddresses() uses the same rule).
lan_ipv4s() {
  ip -4 -o addr show scope global | awk '$2 !~ /^(tailscale|docker|br-|veth)/ { sub(/\/.*/, "", $4); print $4 }'
}
```

- [ ] **Step 4: The password helper**

`package/usr/local/lib/agentos/check-password`:
```perl
#!/usr/bin/perl
# check-password: is the line on stdin the password of the agent account? Exit 0 yes, 1 no, 2 agent
# has no usable password (none, locked, or not a crypt hash), 64 when given any argument.
# Run as root: agentos-web calls it through sudo -n for the LAN login. The password comes on stdin
# only, never in argv (sudo logs argv), and nothing is printed. perl's crypt() is libcrypt's
# (libxcrypt): yescrypt ($y$, what passwd and chpasswd write) and SHA-512 ($6$, the installer's).
use strict;
use warnings;

exit 64 if @ARGV;
my $shadow = $ENV{AGENTOS_SHADOW} // '/etc/shadow';   # tests only: sudo's env_reset drops it
my $hash;
open(my $fh, '<', $shadow) or exit 2;
while (my $line = <$fh>) {
  my @f = split /:/, $line;
  if ($f[0] eq 'agent') { $hash = $f[1]; last; }
}
close $fh;
# "" (no password: would accept anything), "!", "*", "!$y$..." (locked): no usable password.
exit 2 unless defined $hash && $hash =~ /^\$[0-9a-z]+\$/;

binmode STDIN;
my $n = read(STDIN, my $in, 1025);
$in = '' unless $n;
$in =~ s/\n.*//s;
exit 1 if $in eq '' || length($in) > 1024;
my $got = crypt($in, $hash) // '*';
# Constant time over the hash: string xor (the shorter side counts as NUL-padded), then count the
# non-NUL bytes. A crypt result never contains NUL, so any length difference counts too.
exit((($got ^ $hash) =~ tr/\0//c) ? 1 : 0);
```

- [ ] **Step 5: The certificate**

`package/usr/local/lib/agentos/web-lan-cert`:
```bash
#!/bin/bash
# web-lan-cert: make sure the web UI's LAN certificate exists, then print its SHA-256 fingerprint
# (AB:CD:..., as openssl and browsers show it). Self-signed ECDSA P-256 for the hostname,
# <hostname>.local and the IPv4 addresses present now. Kept across boots and updates; made again
# when it is deleted or within 30 days of expiring. 825 days and serverAuth: Apple's TLS rules for
# macOS and iOS (support.apple.com/103769) refuse longer-lived server certificates.
set -euo pipefail
. "${AGENTOS_LIB:-/usr/local/lib/agentos}/env.sh"
D=${WEB_LAN_DIR:-/etc/agentos/web-lan}
G=${WEB_LAN_GROUP:-agent}     # agentos-web's group: it reads the key
if [ ! -s "$D/key.pem" ] || ! openssl x509 -in "$D/cert.pem" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
  h=$(hostname)
  san="DNS:$h,DNS:$h.local"
  for ip in $(lan_ipv4s); do
    san+=",IP:$ip"
  done
  install -d -m 750 -g "$G" "$D"
  rm -f "$D/key.pem.tmp" "$D/cert.pem.tmp"
  (umask 077
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 -subj "/CN=$h" \
     -addext "subjectAltName=$san" -addext "extendedKeyUsage=serverAuth" \
     -keyout "$D/key.pem.tmp" -out "$D/cert.pem.tmp" 2>/dev/null)
  chgrp "$G" "$D/key.pem.tmp"; chmod 640 "$D/key.pem.tmp"; chmod 644 "$D/cert.pem.tmp"
  mv "$D/key.pem.tmp" "$D/key.pem"; mv "$D/cert.pem.tmp" "$D/cert.pem"
fi
openssl x509 -in "$D/cert.pem" -noout -fingerprint -sha256 | sed 's/^[^=]*=//'
```

- [ ] **Step 6: `web-conf`, the firewall, firstboot and apply**

`package/usr/local/lib/agentos/web-conf` (Task 4 replaces its console block):
```bash
#!/bin/bash
# web-conf: agentos-firstboot's web UI step. Publishes the web UI on the tailnet (web-serve), makes
# the LAN certificate when AGENTOS_WEB_LAN=1 (web-lan-cert), and writes /etc/agentos/web.conf for
# agentos-web (which runs as agent: agentos.env is root-only).
# Prints "restart" when the LAN listener changed: agentos-web sets it up when it starts.
# Invalid settings fall back to their defaults.
set -euo pipefail
L=${AGENTOS_LIB:-/usr/local/lib/agentos}
. "$L/env.sh"
E=${AGENTOS_ETC:-/etc/agentos}
AGENTOS_ENV=$E/agentos.env
ISSUE=${ISSUE_DIR:-/run/issue.d}/50-agentos-web.issue

wu=$(env_get "$AGENTOS_ENV" AGENTOS_WEB_USERS)
validate_setting AGENTOS_WEB_USERS "$wu" 2>/dev/null || wu=
we=$(env_get "$AGENTOS_ENV" AGENTOS_WEB | grep -x 0 || echo 1)
wl=$(env_get "$AGENTOS_ENV" AGENTOS_WEB_LAN | grep -x 1 || echo 0)
[ "$we" = 1 ] || wl=0
fp=
if [ "$wl" = 1 ]; then
  if ! agent_has_password; then
    echo "warning: web UI: LAN access needs a password for agent (sudo agentos-config password); it stays off" >&2
    wl=0
  elif ! fp=$("$L/web-lan-cert"); then
    echo "warning: web UI: could not make the LAN certificate; LAN access stays off" >&2
    wl=0 fp=
  fi
fi
ws=$("$L/web-serve" "$we")   # ok | off | tailscale-down | failed: <why>

was=$(grep -E '^(LAN|FINGERPRINT)=' "$E/web.conf" 2>/dev/null || true)
printf 'USERS=%s\nENABLED=%s\nSERVE=%s\nLAN=%s\nFINGERPRINT=%s\n' "$wu" "$we" "$ws" "$wl" "$fp" > "$E/web.conf.tmp"
chmod 644 "$E/web.conf.tmp"
mv "$E/web.conf.tmp" "$E/web.conf"

# Say why on the console too: agetty prints /run/issue.d/*.issue after /etc/issue.
if [[ $ws == failed* ]]; then
  echo "warning: web UI: tailscale serve $ws" >&2   # to the journal (docs/tailscale-acl.md)
  install -d "$(dirname "$ISSUE")"
  printf 'Web UI: tailscale serve %s\n\n' "$ws" > "$ISSUE"
else
  rm -f "$ISSUE"
fi
[ "$was" = "$(grep -E '^(LAN|FINGERPRINT)=' "$E/web.conf")" ] || echo restart
```

```bash
chmod 755 package/usr/local/lib/agentos/check-password package/usr/local/lib/agentos/web-lan-cert package/usr/local/lib/agentos/web-conf
```

`package/usr/local/lib/agentos/firewall.nft`, whole file:
```
# AgentOS inbound policy. Own table, no `flush ruleset`: Docker and Tailscale rules stay intact.
table inet agentos
delete table inet agentos

table inet agentos {
  set public_tcp { type inet_service; }
  set lan_web { type inet_service; }      # 443 while AGENTOS_WEB_LAN=1 (agentos-firewall)

  # The web UI's LAN listener is 0.0.0.0/[::]:7443 (agentos-web, as agent): LAN connections to 443
  # are redirected to it. Not a listener on 443 itself: tailscaled binds <tailnet-ip>:443 for
  # `tailscale serve`, and either side's bind would fail while the other holds the port.
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname != "tailscale0" tcp dport @lan_web redirect to :7443
  }

  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif lo accept
    iifname "tailscale0" accept
    meta l4proto { icmp, ipv6-icmp } accept
    udp dport { 68, 546 } accept          # DHCP / DHCPv6 replies
    udp dport 41641 accept                # Tailscale direct connections
    tcp dport @public_tcp accept          # AGENTOS_LAN_SSH etc.
    tcp dport 7443 ct status dnat accept  # the web UI, only as redirected from 443 above
  }

  # The web UI (127.0.0.1:7070) trusts its identity header, so only tailscaled (root, for
  # `tailscale serve`) and agent may connect to it. Scoped to that one port: every other
  # loopback path (MCP, websockify, Docker) is untouched.
  chain output {
    type filter hook output priority filter; policy accept;
    oif "lo" tcp dport 7070 meta skuid != { 0, 1000 } reject with tcp reset
  }
}
```

In `package/usr/local/sbin/agentos-firewall`, append:
```bash
# The web UI on the LAN: 443 is redirected to agentos-web's LAN listener (firewall.nft). web.conf,
# not agentos.env: LAN=1 only once web-conf found a password and made the certificate.
if grep -qx LAN=1 /etc/agentos/web.conf 2>/dev/null; then
  nft add element inet agentos lan_web '{ 443 }'
fi
```

In `package/usr/local/sbin/agentos-firstboot`, replace everything from `# 5b. Web UI settings for agentos-web` up to (not including) `# 5c. Solenta Mode A` with:
```bash
# 5b. The web UI: tailscale serve, the LAN certificate, web.conf and the console's "Web UI:" lines
# (web-conf). A LAN change also changes the firewall (agentos-firewall reads web.conf) and needs a
# restart of agentos-web. --no-block: agentos-web is ordered after this unit, so waiting would deadlock.
web=$(/usr/local/lib/agentos/web-conf)
[ "$web" != restart ] || /usr/local/sbin/agentos-firewall
if grep -qx ENABLED=1 /etc/agentos/web.conf; then
  systemctl enable --quiet agentos-web.service
  [ "$web" != restart ] || systemctl try-restart --no-block agentos-web.service
  systemctl start --no-block agentos-web.service
else
  systemctl disable --quiet --now --no-block agentos-web.service
fi

```
(`try-restart` is a no-op while the service is stopped; the `start` job then merges into the restart job.)

In `package/usr/local/bin/agentos-config`, find:
```bash
cmd_apply() { systemctl restart agentos-firstboot.service; }
```
Replace with:
```bash
# LAN access to the web UI needs a password for agent: firstboot (web-conf) leaves it off without
# one, and apply says so, last on stderr (the web UI's Settings page shows that line).
cmd_apply() {
  local rc=0
  systemctl restart agentos-firstboot.service || rc=$?
  if [ "$(env_get "$AGENTOS_ENV" AGENTOS_WEB_LAN)" = 1 ] && ! agent_has_password; then
    echo "LAN access to the web UI is not on: set a password for agent first (sudo agentos-config password), then apply again" >&2
    rc=3
  fi
  return "$rc"
}
```

In `.github/workflows/build.yml`, find:
```yaml
            package/usr/local/lib/agentos/web-serve test/web_serve_test.sh \
```
Replace with:
```yaml
            package/usr/local/lib/agentos/web-serve test/web_serve_test.sh \
            package/usr/local/lib/agentos/web-conf package/usr/local/lib/agentos/web-lan-cert \
            test/web_conf_test.sh test/web_lan_cert_test.sh test/check_password_test.sh \
```
Then find:
```yaml
          test/web_serve_test.sh
```
Replace with:
```yaml
          test/web_serve_test.sh
          perl -c package/usr/local/lib/agentos/check-password
          test/check_password_test.sh
          test/web_lan_cert_test.sh
          test/web_conf_test.sh
```

- [ ] **Step 7: Run the tests and the linters**

Run: `.superpowers/sdd/devvm.sh sh 'for t in check_password web_lan_cert web_conf env web_serve; do test/${t}_test.sh; done && perl -c package/usr/local/lib/agentos/check-password && shellcheck -S warning package/usr/local/lib/agentos/{web-conf,web-lan-cert,env.sh} package/usr/local/sbin/agentos-firstboot package/usr/local/sbin/agentos-firewall package/usr/local/bin/agentos-config test/{web_conf,web_lan_cert,check_password,env}_test.sh && echo SC-OK'`
Expected:
```
check-password OK
web-lan-cert OK
web-conf OK
env.sh OK
profile.d OK
validate_setting OK
web-serve OK
package/usr/local/lib/agentos/check-password syntax OK
SC-OK
```

- [ ] **Step 8: Commit**

```bash
git add package/usr/local/lib/agentos/{check-password,web-lan-cert,web-conf,env.sh,firewall.nft} \
  package/usr/local/sbin/agentos-firewall package/usr/local/sbin/agentos-firstboot package/usr/local/bin/agentos-config \
  test/{check_password,web_lan_cert,web_conf,env}_test.sh .github/workflows/build.yml
git commit -m "feat(web-lan): AGENTOS_WEB_LAN: password helper, certificate, 443 redirect, web.conf via firstboot"
```

---
### Task 2: The web server's LAN listener: auth mode, login, logout, sessions, rate limits, audit

**Files:**
- Create: `web/server/src/lan.ts`, `web/server/test/lan.test.ts`
- Modify: `web/server/src/auth.ts`, `web/server/src/actions.ts`, `web/server/src/app.ts`, `web/server/src/system.ts`, `web/server/src/settings.ts`, `web/server/src/main.ts` (whole file), `web/server/test/auth.test.ts`, `web/server/test/settings.test.ts`, `web/server/test/system.test.ts`

**Interfaces:**
- Consumes: `web.conf`'s `LAN=` and `FINGERPRINT=` and `/etc/agentos/web-lan/{key,cert}.pem` (Task 1); `check-password`'s exit codes (Task 1); `agentos-config apply`'s last stderr line (Task 1).
- Produces:
  - `WebConf` gains `lan: boolean; fingerprint: string`; `FastifyRequest` gains `lan: boolean`; `auth.ts` exports `one`.
  - `buildApp(deps: Deps, lan?: LanListener): Promise<FastifyInstance>`, `LanListener = { opts: LanOpts; https?: { key: Buffer; cert: Buffer } }`.
  - `lan.ts`: `LAN_PORT = 7443`, `LAN_DIR`, `COOKIE = '__Host-agentos-session'`, `IDLE_MS`, `ABSOLUTE_MS`, `WINDOW_MS`, `MAX_FAILS_PER_IP = 5`, `MAX_FAILS_TOTAL = 30`, `FAIL_DELAY_MS = 1000`, `LanOpts { now, sleep, hostname, addresses }`, `defaultLanOpts()`, `clientIp`, `lanLogin`, `lanHostAllowed(host, name, addrs)`, `LanState`, `sessionToken(cookie)`, `LOGIN_PAGE`, `lanDecide`, `lanAuthHook`, `lanRoutes`.
  - HTTP: `POST /api/lan/login` `{password}` → 200 `{ok:true}` + cookie, 401 `{error:'wrong password'}`, 429 `{error}`; `POST /api/lan/logout` → 200 `{ok:true}`; unauthenticated API → 401 `text/plain` `log in first`; unauthenticated page GET → 401 `text/html` `LOGIN_PAGE`.
  - `GET /api/me` gains `lan: boolean`; `GET /api/system/lan` → `{ enabled: boolean, fingerprint: string | null, addresses: string[] }` (both listeners). `system.ts` exports `lanAddresses()`.
  - Action `{ name: 'check-password' }` → `['sudo', '-n', '/usr/local/lib/agentos/check-password']` (`CHECK_PASSWORD`).
  - A failed apply: `502 { error: 'saved, but applying failed: <apply's last stderr line>' }`.

- [ ] **Step 1: Write the failing tests**

`web/server/test/lan.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { CHECK_PASSWORD } from '../src/actions.js';
import { parseWebConf } from '../src/auth.js';
import { ABSOLUTE_MS, IDLE_MS, LanState, LOGIN_PAGE, lanHostAllowed, sessionToken, WINDOW_MS, type LanOpts } from '../src/lan.js';
import { fakeDeps, H, LOGIN } from './helpers.js';

const PW = 'correct horse battery';
const NAME = 'box';
const ADDRS = ['127.0.0.1', '192.168.1.50', '::1', 'fe80::1', '2001:db8::5'];
const HOST = '192.168.1.50';
const ORIGIN = `https://${HOST}`;
const CSRF = { host: HOST, origin: ORIGIN, 'x-agentos': '1' };
const IP = '::ffff:192.0.2.7';   // how an IPv4 client shows up on the dual-stack socket

// The LAN app with a fake clock and a recording sleep; check-password accepts PW.
async function lanApp(conf = '') {
  let t = 1_000_000;
  const sleeps: number[] = [];
  const opts: LanOpts = { now: () => t, sleep: async (ms) => { sleeps.push(ms); }, hostname: () => NAME, addresses: () => ADDRS };
  const f = fakeDeps((argv, o) => (argv.includes(CHECK_PASSWORD) ? { code: o?.input === `${PW}\n` ? 0 : 1 } : {}),
    { webConf: () => parseWebConf(conf) });
  const app = await buildApp(f.deps, { opts });
  const login = (password: unknown, remoteAddress = IP, headers: Record<string, string> = CSRF) =>
    app.inject({ method: 'POST', url: '/api/lan/login', headers, remoteAddress, payload: { password } });
  const cookieOf = async () => {
    const r = await login(PW);
    expect(r.statusCode).toBe(200);
    return `__Host-agentos-session=${sessionToken(String(r.headers['set-cookie']))}`;
  };
  return { app, ...f, sleeps, login, cookieOf, advance: (ms: number) => { t += ms; } };
}

describe('Host allowlist', () => {
  it('accepts the hostname, hostname.local and this box\'s addresses, optionally with :443', () => {
    for (const h of ['box', 'BOX', 'box.local', 'box:443', '192.168.1.50', '192.168.1.50:443', '[::1]', '[2001:db8::5]:443', '[fe80::1]']) {
      expect(lanHostAllowed(h, NAME, ADDRS)).toBe(true);
    }
  });
  it('rejects a rebinding name, another port, an unknown address and a bare IPv6 literal', () => {
    for (const h of [undefined, '', 'evil.example', 'box.evil.example', 'evil.example:443', '192.168.1.50:8443', '192.168.1.51', '2001:db8::5', '[2001:db8::6]', 'box.local.']) {
      expect(lanHostAllowed(h, NAME, ADDRS)).toBe(false);
    }
  });
  it('403 for a bad Host, also on the login route', async () => {
    const { app, login } = await lanApp();
    expect((await app.inject({ url: '/', headers: { host: 'evil.example' } })).statusCode).toBe(403);
    expect((await login(PW, IP, { ...CSRF, host: 'evil.example', origin: 'https://evil.example' })).statusCode).toBe(403);
  });
});

describe('without a session', () => {
  it('a page GET gets the login page (static, no third-party resources); the API and WebSockets get 401', async () => {
    const { app } = await lanApp();
    for (const url of ['/', '/sessions/ag-x', '/novnc/core/rfb.js']) {
      const r = await app.inject({ url, headers: { host: HOST } });
      expect(r.statusCode).toBe(401);
      expect(r.headers['content-type']).toMatch(/text\/html/);
      expect(r.body).toBe(LOGIN_PAGE);
    }
    expect(LOGIN_PAGE).not.toMatch(/https?:\/\/|src=|href=/);
    const api = await app.inject({ url: '/api/sessions', headers: { host: HOST } });
    expect([api.statusCode, api.body]).toEqual([401, 'log in first']);
    await app.ready();
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, origin: ORIGIN } })).rejects.toThrow(/401/);
  });
  it('a Tailscale identity header means nothing here', async () => {
    const { app } = await lanApp();
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, 'tailscale-user-login': LOGIN } })).statusCode).toBe(401);
  });
});

describe('login', () => {
  it('succeeds with the password: a 256-bit token in a __Host- cookie with every flag, audited', async () => {
    const { login, calls, audits, sleeps } = await lanApp();
    const r = await login(PW);
    expect(r.statusCode).toBe(200);
    expect(String(r.headers['set-cookie'])).toMatch(/^__Host-agentos-session=[A-Za-z0-9_-]{43}; Secure; HttpOnly; SameSite=Strict; Path=\/$/);
    expect(Buffer.from(sessionToken(String(r.headers['set-cookie']))!, 'base64url')).toHaveLength(32);
    expect(audits).toEqual(['agent@lan(192.0.2.7) login -']);
    expect(sleeps).toEqual([]);
    expect(calls).toEqual([{ argv: ['sudo', '-n', CHECK_PASSWORD], opts: { input: `${PW}\n`, timeoutMs: 15_000 } }]);
  });
  it('fails with a wrong, empty, missing or multi-line password: 401 after ~1 s, audited, the password nowhere', async () => {
    const { login, calls, audits, sleeps } = await lanApp();
    for (const pw of ['wrong', '', undefined, 42, `${PW}\nx`]) {
      const r = await login(pw);
      expect(r.statusCode).toBe(401);
      expect(r.body).not.toContain('wrong"');
      expect(r.headers['set-cookie']).toBeUndefined();
    }
    expect(sleeps).toEqual([1000, 1000, 1000, 1000, 1000]);
    expect(audits).toEqual(Array(5).fill('agent@lan(192.0.2.7) login-failed -'));
    expect(calls).toHaveLength(1);   // only 'wrong' reaches the helper; the others are refused before it
    expect(calls[0].argv.join(' ')).not.toContain('wrong');
    expect(JSON.stringify(audits)).not.toContain('wrong');
  });
  it('the delay is measured from the start: a slow check sleeps less', async () => {
    let t = 0;
    const sleeps: number[] = [];
    const opts: LanOpts = { now: () => t, sleep: async (ms) => { sleeps.push(ms); }, hostname: () => NAME, addresses: () => ADDRS };
    const { deps } = fakeDeps((argv) => { if (argv.includes(CHECK_PASSWORD)) t += 300; return { code: 1 }; });
    const app = await buildApp(deps, { opts });
    await app.inject({ method: 'POST', url: '/api/lan/login', headers: CSRF, payload: { password: 'x' } });
    expect(sleeps).toEqual([700]);
  });
  it('needs the same CSRF headers as any unsafe request', async () => {
    const { login, calls } = await lanApp();
    expect((await login(PW, IP, { host: HOST, origin: ORIGIN })).statusCode).toBe(403);
    expect((await login(PW, IP, { host: HOST, 'x-agentos': '1' })).statusCode).toBe(403);
    expect((await login(PW, IP, { ...CSRF, origin: `http://${HOST}` })).statusCode).toBe(403);
    expect(calls).toEqual([]);
  });
});

describe('rate limiting', () => {
  it('5 failures per IP in 10 minutes, then 429 (even for the right password) until the window passes', async () => {
    const { login, advance, calls } = await lanApp();
    for (let i = 0; i < 5; i++) expect((await login('wrong')).statusCode).toBe(401);
    expect((await login(PW)).statusCode).toBe(429);
    expect(calls).toHaveLength(5);
    expect((await login(PW, '192.0.2.8')).statusCode).toBe(200);   // another address is not affected
    advance(WINDOW_MS);
    expect((await login(PW)).statusCode).toBe(200);
  });
  it('a success does not count', async () => {
    const { login } = await lanApp();
    for (let i = 0; i < 4; i++) await login('wrong');
    for (let i = 0; i < 3; i++) expect((await login(PW)).statusCode).toBe(200);
    expect((await login('wrong')).statusCode).toBe(401);
    expect((await login(PW)).statusCode).toBe(429);
  });
  it('30 failures in 10 minutes across all addresses, then 429 for everyone', async () => {
    const { login } = await lanApp();
    for (let i = 0; i < 30; i++) expect((await login('wrong', `198.51.100.${Math.floor(i / 5)}`)).statusCode).toBe(401);
    expect((await login(PW, '203.0.113.1')).statusCode).toBe(429);
  });
  it('parallel guesses from one address can\'t pass the limit together', async () => {
    const { login } = await lanApp();
    const codes = (await Promise.all(Array.from({ length: 8 }, () => login('wrong')))).map((r) => r.statusCode).sort();
    expect(codes).toEqual([401, 401, 401, 401, 401, 429, 429, 429]);
  });
});

describe('sessions', () => {
  it('a session cookie authorizes the API as agent@lan(<ip>), with /api/me saying so', async () => {
    const { app, cookieOf } = await lanApp();
    const cookie = await cookieOf();
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(404);
    const me = await app.inject({ url: '/api/me', headers: { host: HOST, cookie }, remoteAddress: '192.0.2.9' });
    expect(me.json()).toMatchObject({ login: 'agent@lan(192.0.2.9)', lan: true });
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie: `${cookie.slice(0, -1)}A` } })).statusCode).toBe(401);
  });
  it('expires after 12 hours idle', async () => {
    const { app, cookieOf, advance } = await lanApp();
    const cookie = await cookieOf();
    advance(IDLE_MS - 1000);
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(404);
    advance(IDLE_MS + 1);
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(401);
  });
  it('expires after 7 days however active', async () => {
    const st = (() => { let t = 0; const s = new LanState(() => t); return { s, go: (ms: number) => { t += ms; } }; })();
    const token = st.s.create();
    for (let used = 0; used + 11 * 3600_000 <= ABSOLUTE_MS; used += 11 * 3600_000) { expect(st.s.check(token)).toBe(true); st.go(11 * 3600_000); }
    st.go(ABSOLUTE_MS);   // well past 7 days in total
    expect(st.s.check(token)).toBe(false);
  });
  it('logout deletes the session, clears the cookie and is audited', async () => {
    const { app, cookieOf, audits } = await lanApp();
    const cookie = await cookieOf();
    const r = await app.inject({ method: 'POST', url: '/api/lan/logout', headers: { ...CSRF, cookie }, remoteAddress: IP });
    expect(r.statusCode).toBe(200);
    expect(r.headers['set-cookie']).toBe('__Host-agentos-session=; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
    expect(audits.at(-1)).toBe('agent@lan(192.0.2.7) logout -');
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(401);
  });
  it('CSRF: an unsafe request with a session still needs Origin https://<Host> and X-AgentOS', async () => {
    const { app, cookieOf } = await lanApp();
    const cookie = await cookieOf();
    const post = (h: Record<string, string>) => app.inject({ method: 'POST', url: '/api/nope', headers: { cookie, ...h }, payload: {} });
    expect((await post({ host: HOST, origin: ORIGIN })).statusCode).toBe(403);
    expect((await post({ host: HOST, 'x-agentos': '1' })).statusCode).toBe(403);
    expect((await post({ host: HOST, origin: 'https://box.local', 'x-agentos': '1' })).statusCode).toBe(403);
    expect((await post({ host: 'box.local', origin: 'https://box.local', 'x-agentos': '1' })).statusCode).toBe(404);
    expect((await post(CSRF)).statusCode).toBe(404);
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie, 'sec-fetch-site': 'cross-site' } })).statusCode).toBe(403);
  });
  it('WebSocket upgrades need the session and the Origin', async () => {
    const { app, cookieOf } = await lanApp();
    const cookie = await cookieOf();
    await app.ready();
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, origin: ORIGIN } })).rejects.toThrow(/401/);
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, cookie, origin: 'https://evil.example' } })).rejects.toThrow(/403/);
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, cookie, origin: ORIGIN } })).rejects.toThrow(/404/);
  });
  it('/api/system/lan reports the fingerprint from web.conf', async () => {
    const { app, cookieOf } = await lanApp('LAN=1\nFINGERPRINT=AB:CD\n');
    const r = await app.inject({ url: '/api/system/lan', headers: { host: HOST, cookie: await cookieOf() } });
    expect(r.json()).toMatchObject({ enabled: true, fingerprint: 'AB:CD' });
  });
});

describe('the Tailscale listener is unchanged', () => {
  it('has no LAN routes, ignores session cookies, and reports lan: false', async () => {
    const { deps } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/lan/login', headers: { host: H.host }, payload: { password: PW } })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/api/lan/login', headers: { ...H, origin: 'http://127.0.0.1:7070', 'x-agentos': '1' }, payload: {} })).statusCode).toBe(404);
    expect((await app.inject({ url: '/api/nope', headers: { host: H.host, cookie: `__Host-agentos-session=${'A'.repeat(43)}` } })).statusCode).toBe(401);
    expect((await app.inject({ url: '/api/system/lan', headers: H })).json()).toMatchObject({ enabled: false, fingerprint: null });
    expect((await app.inject({ url: '/', headers: { host: HOST } })).statusCode).toBe(403);   // a LAN Host is a bad host here
  });
});
```

In `web/server/test/auth.test.ts`, find:
```ts
    expect(parseWebConf('USERS=a@x.com, B@y.org\nENABLED=1\nSERVE=ok\n')).toEqual({ users: ['a@x.com', 'b@y.org'], enabled: true, serve: 'ok' });
    expect(parseWebConf('')).toEqual({ users: [], enabled: true, serve: '' });
```
Replace with:
```ts
    expect(parseWebConf('USERS=a@x.com, B@y.org\nENABLED=1\nSERVE=ok\nLAN=1\nFINGERPRINT=AB:CD\n'))
      .toEqual({ users: ['a@x.com', 'b@y.org'], enabled: true, serve: 'ok', lan: true, fingerprint: 'AB:CD' });
    expect(parseWebConf('')).toEqual({ users: [], enabled: true, serve: '', lan: false, fingerprint: '' });
    expect(parseWebConf('LAN=0\nFINGERPRINT=\n').lan).toBe(false);
```
Then find:
```ts
    expect(readWebConf('/nonexistent/path/web.conf')).toEqual({ users: [], enabled: true, serve: '' });
```
Replace with:
```ts
    expect(readWebConf('/nonexistent/path/web.conf')).toEqual({ users: [], enabled: true, serve: '', lan: false, fingerprint: '' });
```

Append to `web/server/test/settings.test.ts`:
```ts

describe('apply failures', () => {
  it('a failed apply reports agentos-config\'s last stderr line (LAN access without a password)', async () => {
    const why = 'LAN access to the web UI is not on: set a password for agent first (sudo agentos-config password), then apply again';
    const { deps } = fakeDeps((argv) => (argv[3] === 'apply' ? { code: 3, stderr: `Job ok\n${why}\n` } : {}));
    const r = await (await buildApp(deps)).inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values: { AGENTOS_WEB_LAN: '1' } } });
    expect(r.statusCode).toBe(502);
    expect(r.json().error).toBe(`saved, but applying failed: ${why}`);
  });
});
```

In `web/server/test/system.test.ts`, find:
```ts
import { cpuPercent, parseCpu,
```
Replace with:
```ts
import { cpuPercent, lanAddresses, parseCpu,
```
And append:
```ts

describe('lanAddresses', () => {
  it('lists IPv4 addresses on the local network only: not loopback, Tailscale or Docker', () => {
    const a = (address: string, family = 'IPv4', internal = false) => ({ address, family, internal, netmask: '', mac: '', cidr: null });
    const ifs = { lo: [a('127.0.0.1', 'IPv4', true)], enp1s0: [a('192.168.1.50'), a('fe80::1', 'IPv6')], wlan0: [a('10.0.0.7')],
      tailscale0: [a('100.64.0.1')], docker0: [a('172.17.0.1')], 'br-4a06': [a('172.18.0.1')], veth1: [a('169.254.1.1')] };
    expect(lanAddresses(ifs as never)).toEqual(['192.168.1.50', '10.0.0.7']);
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd web/server && npx vitest run 2>&1 | tail -5`
Expected: `test/lan.test.ts` fails to load (`Failed to load url ../src/lan.js`), `auth.test.ts` fails on the two `toEqual`s (no `lan`, `fingerprint`), `settings.test.ts` on the message (`saved, but applying failed: see journalctl -u agentos-firstboot`), `system.test.ts` on the missing export.

- [ ] **Step 3: `lan.ts`**

`web/server/src/lan.ts`:
```ts
// The LAN listener (AGENTOS_WEB_LAN=1): HTTPS on [::]:7443, which the firewall reaches from 443 on
// every interface but tailscale0. Password login for the agent account, sessions in memory, rate
// limits. The loopback listener (Tailscale identity, auth.ts) never sees any of this.
import { createHash, randomBytes } from 'node:crypto';
import { hostname, networkInterfaces } from 'node:os';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { runAction } from './actions.js';
import type { Deps } from './app.js';
import { one, type Verdict } from './auth.js';

export const LAN_PORT = 7443;
export const LAN_DIR = '/etc/agentos/web-lan';
export const COOKIE = '__Host-agentos-session';
export const IDLE_MS = 12 * 3600_000;
export const ABSOLUTE_MS = 7 * 24 * 3600_000;
export const WINDOW_MS = 10 * 60_000;
export const MAX_FAILS_PER_IP = 5;
export const MAX_FAILS_TOTAL = 30;
export const FAIL_DELAY_MS = 1000;
const LOGIN_PATH = '/api/lan/login';

export interface LanOpts {
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  hostname: () => string;
  addresses: () => string[];       // every address of this box, as os.networkInterfaces() prints it
}

export const defaultLanOpts = (): LanOpts => ({
  now: Date.now,
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  hostname,
  addresses: () => Object.values(networkInterfaces()).flatMap((l) => (l ?? []).map((a) => a.address)),
});

// IPv4 clients reach the dual-stack socket as ::ffff:a.b.c.d. (injectWS requests have no address.)
export const clientIp = (ip: string | undefined) => (ip ?? '-').replace(/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)/, '');
export const lanLogin = (ip: string | undefined) => `agent@lan(${clientIp(ip)})`;

// Host must name this box: its hostname, <hostname>.local or one of its addresses (IPv6 in
// brackets), optionally with :443. Anything else is DNS rebinding, or a mistake.
export function lanHostAllowed(host: string | undefined, name: string, addrs: string[]): boolean {
  if (!host) return false;
  const h = host.toLowerCase().replace(/:443$/, '');
  const n = name.toLowerCase();
  return h === n || h === `${n}.local` || addrs.some((a) => h === (a.includes(':') ? `[${a.toLowerCase()}]` : a));
}

const digest = (token: string) => createHash('sha256').update(token).digest('hex');

interface Session { created: number; seen: number }
interface Attempt { at: number; ip: string }

// Sessions are keyed by the token's SHA-256, so the map holds no usable token and a lookup never
// compares the secret itself. A restart forgets them all.
export class LanState {
  private sessions = new Map<string, Session>();
  private fails: Attempt[] = [];
  constructor(private now: () => number) {}

  create(): string {
    const t = this.now();
    for (const [k, s] of this.sessions) if (this.expired(s, t)) this.sessions.delete(k);
    const token = randomBytes(32).toString('base64url');   // 256 bits
    this.sessions.set(digest(token), { created: t, seen: t });
    return token;
  }
  check(token: string | null): boolean {
    if (!token) return false;
    const k = digest(token);
    const s = this.sessions.get(k);
    if (!s) return false;
    const t = this.now();
    if (this.expired(s, t)) { this.sessions.delete(k); return false; }
    s.seen = t;
    return true;
  }
  drop(token: string | null): void { if (token) this.sessions.delete(digest(token)); }
  private expired(s: Session, t: number) { return t - s.seen > IDLE_MS || t - s.created > ABSOLUTE_MS; }

  // An attempt counts as a failure from the start, and is forgiven when it succeeds: parallel
  // guesses from one address can't all pass the limit check before the first one fails.
  // ponytail: one list for every address; it never holds more than MAX_FAILS_TOTAL entries.
  attempt(ip: string): Attempt | null {
    const t = this.now();
    this.fails = this.fails.filter((f) => t - f.at < WINDOW_MS);
    if (this.fails.length >= MAX_FAILS_TOTAL || this.fails.filter((f) => f.ip === ip).length >= MAX_FAILS_PER_IP) return null;
    const a = { at: t, ip };
    this.fails.push(a);
    return a;
  }
  forgive(a: Attempt): void { this.fails = this.fails.filter((f) => f !== a); }
}

export function sessionToken(cookie: string | undefined): string | null {
  return cookie?.match(/(?:^|;\s*)__Host-agentos-session=([A-Za-z0-9_-]{43})(?:;|$)/)?.[1] ?? null;
}

export const LOGIN_PAGE = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>AgentOS: log in</title>
<body style="font-family:sans-serif;background:#111;color:#eee;padding:2em">
<form id="f"><h1>AgentOS</h1>
<p><label>Password of <code>agent</code><br><input id="p" type="password" autocomplete="current-password" autofocus required></label></p>
<p><button>Log in</button> <span id="e" role="alert"></span></p></form>
<script>
document.getElementById('f').onsubmit = async (ev) => {
  ev.preventDefault();
  const e = document.getElementById('e');
  e.textContent = '';
  const r = await fetch('/api/lan/login', { method: 'POST', headers: { 'X-AgentOS': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: document.getElementById('p').value }) });
  if (r.ok) location.reload();
  else e.textContent = r.status === 429 ? 'Too many failed logins: try again in 10 minutes.' : r.status === 401 ? 'Wrong password.' : 'Login failed (' + r.status + ').';
};
</script>`;

export interface LanFacts {
  method: string; path: string; host: string | undefined; hostOk: boolean; ip: string | undefined; session: boolean;
  origin: string | undefined; xAgentOS: string | undefined;
  fetchSite?: string; fetchMode?: string; fetchDest?: string; upgrade: boolean;
}

// The same rules as decide() in auth.ts, with a session in place of the Tailscale identity.
export function lanDecide(f: LanFacts): Verdict {
  if (!f.hostOk) return { ok: false, status: 403, body: 'bad host' };
  const navigation = f.method === 'GET' && f.fetchMode === 'navigate' && f.fetchDest === 'document';
  if (f.fetchSite === 'cross-site' && !navigation) return { ok: false, status: 403, body: 'cross-site request' };
  const safe = f.method === 'GET' || f.method === 'HEAD' || f.method === 'OPTIONS';
  if (!f.session && !(f.method === 'POST' && f.path === LOGIN_PATH)) {
    if (safe && !f.upgrade && !f.path.startsWith('/api/')) return { ok: false, status: 401, body: LOGIN_PAGE, html: true };
    return { ok: false, status: 401, body: 'log in first' };
  }
  if (!safe || f.upgrade) {
    if (f.origin !== `https://${f.host}`) return { ok: false, status: 403, body: 'bad origin' };
    if (!safe && f.xAgentOS !== '1') return { ok: false, status: 403, body: 'missing X-AgentOS header' };
  }
  return { ok: true, login: lanLogin(f.ip) };
}

export function lanAuthHook(state: LanState, opts: LanOpts) {
  return async (req: FastifyRequest, reply: FastifyReply) => {
    const host = one(req.headers.host);
    const v = lanDecide({
      method: req.method,
      path: req.url.split('?')[0],
      host,
      hostOk: lanHostAllowed(host, opts.hostname(), opts.addresses()),
      ip: req.ip,
      session: state.check(sessionToken(one(req.headers.cookie))),
      origin: one(req.headers.origin),
      xAgentOS: one(req.headers['x-agentos']),
      fetchSite: one(req.headers['sec-fetch-site']),
      fetchMode: one(req.headers['sec-fetch-mode']),
      fetchDest: one(req.headers['sec-fetch-dest']),
      upgrade: one(req.headers.upgrade)?.toLowerCase() === 'websocket',
    });
    if (v.ok) {
      req.login = v.login;
      req.lan = true;
      return;
    }
    return reply.code(v.status).type(v.html ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8').send(v.body);
  };
}

const COOKIE_FLAGS = 'Secure; HttpOnly; SameSite=Strict; Path=/';

export function lanRoutes(app: FastifyInstance, deps: Deps, state: LanState, opts: LanOpts): void {
  // The password goes to check-password on stdin only: never argv (sudo logs it), the audit log,
  // a response or an error message.
  app.post<{ Body: { password?: unknown } }>(LOGIN_PATH, async (req, reply) => {
    const who = lanLogin(req.ip);
    const attempt = state.attempt(clientIp(req.ip));
    if (!attempt) return reply.code(429).send({ error: 'too many failed logins: try again in 10 minutes' });
    const started = opts.now();
    const pw = req.body?.password;
    const ok = typeof pw === 'string' && pw !== '' && pw.length <= 1024 && !/[\r\n\0]/.test(pw) &&
      (await runAction(deps.run, { name: 'check-password' }, { input: `${pw}\n`, timeoutMs: 15_000 })).code === 0;
    if (!ok) {
      deps.audit(who, 'login-failed', '-');
      await opts.sleep(Math.max(0, FAIL_DELAY_MS - (opts.now() - started)));   // ~1 s, however long the check took
      return reply.code(401).send({ error: 'wrong password' });
    }
    state.forgive(attempt);
    deps.audit(who, 'login', '-');
    return reply.header('Set-Cookie', `${COOKIE}=${state.create()}; ${COOKIE_FLAGS}`).send({ ok: true });
  });
  app.post('/api/lan/logout', async (req, reply) => {
    state.drop(sessionToken(one(req.headers.cookie)));
    deps.audit(req.login, 'logout', '-');
    return reply.header('Set-Cookie', `${COOKIE}=; ${COOKIE_FLAGS}; Max-Age=0`).send({ ok: true });
  });
}
```

- [ ] **Step 4: Wire it in**

In `web/server/src/auth.ts`, find:
```ts
export interface WebConf { users: string[]; enabled: boolean; serve: string }
```
Replace with:
```ts
export interface WebConf { users: string[]; enabled: boolean; serve: string; lan: boolean; fingerprint: string }
```
Find:
```ts
    serve: get('SERVE'),
  };
```
Replace with:
```ts
    serve: get('SERVE'),
    lan: get('LAN') === '1',            // the LAN listener (lan.ts), written by web-conf
    fingerprint: get('FINGERPRINT'),    // its certificate's SHA-256, AB:CD:...
  };
```
Find:
```ts
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);
```
Replace with:
```ts
export const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);
```
Find:
```ts
  interface FastifyRequest { login: string }
```
Replace with:
```ts
  interface FastifyRequest { login: string; lan: boolean }   // lan: arrived on the LAN listener
```

In `web/server/src/actions.ts`, find:
```ts
export const UPDATE = '/usr/local/bin/agentos-update';
```
Replace with:
```ts
export const UPDATE = '/usr/local/bin/agentos-update';
export const CHECK_PASSWORD = '/usr/local/lib/agentos/check-password';
```
Find:
```ts
  | { name: 'reboot' }
```
Replace with:
```ts
  | { name: 'check-password' }                      // the password on stdin, never argv
  | { name: 'reboot' }
```
Find:
```ts
    case 'reboot': return [...sudo, 'systemctl', 'reboot'];
```
Replace with:
```ts
    case 'check-password': return [...sudo, CHECK_PASSWORD];
    case 'reboot': return [...sudo, 'systemctl', 'reboot'];
```

In `web/server/src/app.ts`, find:
```ts
import { execRunner, HttpError, type Runner } from './run.js';
```
Replace with:
```ts
import { execRunner, HttpError, type Runner } from './run.js';
import { LanState, lanAuthHook, lanRoutes, type LanOpts } from './lan.js';
```
Find:
```ts
export async function buildApp(deps: Deps): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: 'warn' }, bodyLimit: 1024 * 1024 });
```
Replace with:
```ts
// One app per listener, from the same routes: without `lan`, the loopback listener (Tailscale
// identity); with it, the LAN listener (password login, lan.ts), over HTTPS when `https` is given.
export interface LanListener { opts: LanOpts; https?: { key: Buffer; cert: Buffer } }

export async function buildApp(deps: Deps, lan?: LanListener): Promise<FastifyInstance> {
  const base = { logger: { level: 'warn' }, bodyLimit: 1024 * 1024 };
  const app = (lan?.https ? Fastify({ ...base, https: lan.https }) : Fastify(base)) as unknown as FastifyInstance;
  const lanState = lan && new LanState(lan.opts.now);
```
Find:
```ts
  app.decorateRequest('login', '');
```
Replace with:
```ts
  app.decorateRequest('login', '');
  app.decorateRequest('lan', false);
```
Find:
```ts
  app.addHook('onRequest', authHook(deps.webConf, deps.tsName));
```
Replace with:
```ts
  app.addHook('onRequest', lan ? lanAuthHook(lanState!, lan.opts) : authHook(deps.webConf, deps.tsName));
```
Find:
```ts
  updateRoutes(app, deps);
```
Replace with:
```ts
  updateRoutes(app, deps);
  if (lan) lanRoutes(app, deps, lanState!, lan.opts);
```

In `web/server/src/system.ts`, find:
```ts
import { hostname, loadavg } from 'node:os';
```
Replace with:
```ts
import { hostname, loadavg, networkInterfaces } from 'node:os';
```
Find:
```ts
let prevCpu: CpuSample | null = null;
```
Replace with:
```ts
// This box's IPv4 addresses on the local network: not loopback, Tailscale or Docker's bridges
// (web-conf's lan_ipv4s, for the console, uses the same rule).
export function lanAddresses(ifs = networkInterfaces()): string[] {
  return Object.entries(ifs).flatMap(([name, l]) => (/^(lo|tailscale|docker|br-|veth)/.test(name) ? [] : l ?? [])
    .filter((a) => a.family === 'IPv4' && !a.internal).map((a) => a.address));
}

let prevCpu: CpuSample | null = null;
```
Find:
```ts
    return { login: req.login, hostname: hostname(), tailnetIp: ts.ip, tailnetName: ts.dnsName };
  });
```
Replace with:
```ts
    return { login: req.login, hostname: hostname(), tailnetIp: ts.ip, tailnetName: ts.dnsName, lan: req.lan };
  });
  // LAN access, for the System page: the certificate's fingerprint and the addresses to type.
  app.get('/api/system/lan', async () => {
    const c = deps.webConf();
    return { enabled: c.lan, fingerprint: c.lan && c.fingerprint ? c.fingerprint : null, addresses: lanAddresses() };
  });
```

In `web/server/src/settings.ts`, find:
```ts
  'AGENTOS_SCREENSHOT_WIDTH', 'AGENTOS_DESKTOP_IDLE_MINUTES', 'AGENTOS_WEB_USERS', 'AGENTOS_WEB',
```
Replace with:
```ts
  'AGENTOS_SCREENSHOT_WIDTH', 'AGENTOS_DESKTOP_IDLE_MINUTES', 'AGENTOS_WEB_USERS', 'AGENTOS_WEB', 'AGENTOS_WEB_LAN',
```
Find:
```ts
  if (r.code !== 0) throw new HttpError(502, 'saved, but applying failed: see journalctl -u agentos-firstboot');
```
Replace with:
```ts
  // agentos-config apply says why on its last stderr line (e.g. LAN access needs a password).
  const why = r.stderr.trim().split('\n').pop();
  if (r.code !== 0) throw new HttpError(502, `saved, but applying failed: ${why || 'see journalctl -u agentos-firstboot'}`);
```

`web/server/src/main.ts`, whole file:
```ts
import { readFileSync } from 'node:fs';
import type { FastifyInstance } from 'fastify';
import { buildApp, defaultDeps } from './app.js';
import { PORT } from './auth.js';
import { defaultLanOpts, LAN_DIR, LAN_PORT } from './lan.js';

const deps = defaultDeps();
const apps: FastifyInstance[] = [await buildApp(deps)];
await apps[0].listen({ host: '127.0.0.1', port: PORT });

// The LAN listener, when web-conf turned it on (it restarts this service on a change). A failure
// here leaves the loopback listener, and so Tailscale access, running.
if (deps.webConf().lan) {
  try {
    const https = { key: readFileSync(`${LAN_DIR}/key.pem`), cert: readFileSync(`${LAN_DIR}/cert.pem`) };
    const lan = await buildApp(deps, { opts: defaultLanOpts(), https });
    // Dual-stack; IPv4 only on a box with IPv6 turned off.
    await lan.listen({ host: '::', port: LAN_PORT }).catch(() => lan.listen({ host: '0.0.0.0', port: LAN_PORT }));
    apps.push(lan);
  } catch (e) {
    console.error(`LAN listener not started: ${(e as Error).message}`);
  }
}

// A restart (web-conf after a LAN change, an update) lets requests in flight finish, such as the
// Settings save that caused it. Open WebSockets are closed; at most 5 s.
process.on('SIGTERM', () => {
  setTimeout(() => process.exit(0), 5000).unref();
  void Promise.allSettled(apps.map((a) => a.close())).then(() => process.exit(0));
});
```

- [ ] **Step 5: Run the tests**

Run: `cd web/server && npx tsc -p tsconfig.json --noEmit && npx vitest run 2>&1 | tail -4`
Expected: `Tests  134 passed | 1 skipped (135)`.

- [ ] **Step 6: Commit**

```bash
git add web/server/src/{lan,auth,actions,app,system,settings,main}.ts web/server/test/{lan,auth,settings,system}.test.ts
git commit -m "feat(web-lan): the LAN listener: password login, in-memory sessions, rate limits, audit"
```

---
### Task 3: The UI: Logout, the expired-session reload, LAN access on System, the setting in Settings

The login page itself is the server's static `LOGIN_PAGE` (Task 2): it must work before any of the UI's JavaScript is allowed to load.

**Files:**
- Create: `web/ui/test/lan.test.tsx`
- Modify: `web/ui/src/api.ts`, `web/ui/src/App.tsx`, `web/ui/src/types.ts`, `web/ui/src/pages/System.tsx`, `web/ui/src/pages/Settings.tsx`, `web/ui/src/style.css`

**Interfaces:**
- Consumes: `GET /api/me` `lan`, `GET /api/system/lan`, `POST /api/lan/logout`, the `log in first` 401 body, the 502 apply message (Task 2).
- Produces: `api.ts` exports `page = { reload }` (replaceable in tests); `types.ts` `Me.lan: boolean`, `LanInfo { enabled; fingerprint: string | null; addresses: string[] }`.

- [ ] **Step 1: Write the failing tests**

`web/ui/test/lan.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { App } from '../src/App';
import { api, page } from '../src/api';
import { Settings } from '../src/pages/Settings';
import { System } from '../src/pages/System';
import type { Me } from '../src/types';

const realReload = page.reload;
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks(); page.reload = realReload; });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const text = (body: string, status: number) => new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });
const FP = 'B4:A0:73:5F:85:CC:CE:06:76:AE:B3:64:CA:36:6A:F8:BC:6B:EF:B4:BC:FD:7F:9C:0E:CB:D9:6E:DE:D2:A9:B8';
const ME: Me = { login: 'agent@lan(192.168.1.20)', hostname: 'box', tailnetIp: null, tailnetName: null, lan: true };

// Routes by "METHOD path" or path (query ignored): a JSON body, or a function making the Response.
// Anything else gets an empty list.
const OVERVIEW = { '/api/system/health': { cpuPercent: 1, load: [0, 0, 0], memory: { totalBytes: 1, usedBytes: 0 }, disk: { totalBytes: 1, usedBytes: 0 } },
  '/api/desktops': { desktops: [] }, '/api/system/tailscale': { state: 'Running', dnsName: null, ip: null, serve: 'ok' }, '/api/update': { installed: '1.0.2' } };
function stubFetch(routes: Record<string, unknown>) {
  const f = vi.fn(async (url: string, init?: RequestInit) => {
    const path = url.split('?')[0];
    const hit = routes[`${init?.method ?? 'GET'} ${path}`] ?? routes[path];
    return typeof hit === 'function' ? (hit as () => Response)() : json(hit ?? []);
  });
  vi.stubGlobal('fetch', f);
  return f;
}

it('an expired LAN session reloads the page (which then shows the login page); other 401s do not', async () => {
  page.reload = vi.fn();
  stubFetch({ '/api/a': () => text('log in first', 401), '/api/b': () => text('no Tailscale identity', 401) });
  await expect(api('/api/a')).rejects.toThrow('log in first');
  expect(page.reload).toHaveBeenCalledTimes(1);
  await expect(api('/api/b')).rejects.toThrow('no Tailscale identity');
  expect(page.reload).toHaveBeenCalledTimes(1);
});

it('shows Log out on the LAN listener only; it posts with the CSRF header, then reloads', async () => {
  page.reload = vi.fn();
  const f = stubFetch({ ...OVERVIEW, '/api/me': ME, 'POST /api/lan/logout': { ok: true } });
  render(<App />);
  fireEvent.click(await screen.findByText('Log out'));
  await vi.waitFor(() => expect(page.reload).toHaveBeenCalled());
  expect(f.mock.calls.find(([u]) => u === '/api/lan/logout')![1]).toMatchObject({ method: 'POST', headers: { 'X-AgentOS': '1' } });
  cleanup();
  stubFetch({ ...OVERVIEW, '/api/me': { ...ME, login: 'alice@example.com', lan: false } });
  render(<App />);
  await screen.findByText('alice@example.com');
  expect(screen.queryByText('Log out')).toBeNull();
});

it('System shows the LAN addresses and the certificate fingerprint, or that LAN access is off', async () => {
  stubFetch({ '/api/system/lan': { enabled: true, fingerprint: FP, addresses: ['192.168.1.50', '10.0.0.7'] }, '/api/update': { installed: '1.0.2' } });
  render(<System me={null} />);
  expect((await screen.findByText(FP)).tagName).toBe('CODE');
  expect(screen.getByText('https://192.168.1.50', { exact: false })).toBeTruthy();
  expect(screen.getByText('https://10.0.0.7', { exact: false })).toBeTruthy();
  cleanup();
  stubFetch({ '/api/system/lan': { enabled: false, fingerprint: null, addresses: ['192.168.1.50'] }, '/api/update': { installed: '1.0.2' } });
  render(<System me={null} />);
  await screen.findByText(/^Off\. Turn it on in Settings/);
  expect(screen.queryByText(/Certificate SHA-256/)).toBeNull();
});

const SETTINGS = { values: { AGENTOS_WEB_LAN: '' }, secrets: {} };
const settingsRoutes = (put = () => json({ ok: true })) => ({
  '/api/settings': SETTINGS, 'PUT /api/settings': put,
  '/api/system/tailscale': { state: 'Running', dnsName: null, ip: null, serve: 'ok' },
  '/api/dirs': { path: '/home/agent', parent: null, dirs: [] },
  '/api/solenta': { host: 'b', remoteHost: 'agent@b', remotePath: null, tailscaleSsh: true, hostKeys: [], keyscan: '', modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] },
});
const lanBox = async () => (await screen.findByLabelText(/Also on the local network/)) as HTMLInputElement;
const saveWeb = (box: HTMLInputElement) => fireEvent.click(box.closest('form')!.querySelector('button')!);

it('Settings turns LAN access on after a warning, and shows why applying failed', async () => {
  const why = 'saved, but applying failed: LAN access to the web UI is not on: set a password for agent first (sudo agentos-config password), then apply again';
  const f = stubFetch(settingsRoutes(() => json({ error: why }, 502)));
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
  render(<Settings me={{ ...ME, lan: false }} />);
  const box = await lanBox();
  expect(box.checked).toBe(false);
  fireEvent.click(box);
  saveWeb(box);
  await screen.findByText(why);
  expect(confirm.mock.calls[0][0]).toMatch(/full control of this machine/);
  const put = f.mock.calls.find(([u, i]) => u === '/api/settings' && i?.method === 'PUT')!;
  expect(JSON.parse(String(put[1]!.body))).toEqual({ values: { AGENTOS_WEB_LAN: '1' } });
});

it('Settings asks before a LAN user turns LAN access off, and saves nothing on No', async () => {
  const f = stubFetch({ ...settingsRoutes(), '/api/settings': { values: { AGENTOS_WEB_LAN: '1' }, secrets: {} } });
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  render(<Settings me={ME} />);
  const box = await lanBox();
  fireEvent.click(box);
  saveWeb(box);
  expect(confirm.mock.calls[0][0]).toMatch(/You are using LAN access/);
  expect(f.mock.calls.some(([, i]) => i?.method === 'PUT')).toBe(false);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd web/ui && npx vitest run test/lan.test.tsx 2>&1 | tail -4`
Expected: every test fails (`page` is not exported from `../src/api`; no "Log out", no "LAN access" panel, no LAN checkbox).

- [ ] **Step 3: Implement**

In `web/ui/src/api.ts`, find:
```ts
export async function api<T
```
Replace with:
```ts
// The page itself, behind an object so tests can replace reload().
export const page = { reload: () => location.reload() };

export async function api<T
```
Find:
```ts
  if (!r.ok) throw new ApiError(
```
Replace with:
```ts
  // A LAN session that expired (or a restart forgot it): reloading shows the login page.
  if (r.status === 401 && data === 'log in first') page.reload();
  if (!r.ok) throw new ApiError(
```

In `web/ui/src/types.ts`, find:
```ts
export interface Me { login: string; hostname: string; tailnetIp: string | null; tailnetName: string | null }
```
Replace with:
```ts
export interface Me { login: string; hostname: string; tailnetIp: string | null; tailnetName: string | null; lan: boolean }
export interface LanInfo { enabled: boolean; fingerprint: string | null; addresses: string[] }
```

In `web/ui/src/App.tsx`, find:
```tsx
import { api } from './api';
```
Replace with:
```tsx
import { api, page as browser } from './api';
```
Find:
```tsx
        <span className="login">{me?.login}</span>
```
Replace with:
```tsx
        <span className="login">{me?.login}</span>
        {me?.lan && <button onClick={() => { void api('/api/lan/logout', 'POST').finally(browser.reload); }}>Log out</button>}
```

In `web/ui/src/pages/System.tsx`, find:
```tsx
import { openTerminal } from '../quick';
import type { Me } from '../types';
```
Replace with:
```tsx
import { api } from '../api';
import { openTerminal } from '../quick';
import type { LanInfo, Me } from '../types';
import { usePoll } from '../usePoll';

// LAN access (AGENTOS_WEB_LAN): where to point a browser, and the fingerprint to compare with the
// browser's certificate warning.
function LanCard() {
  const { data } = usePoll(() => api<LanInfo>('/api/system/lan'));
  if (!data) return null;
  return (
    <div className="panel">
      <h2>LAN access</h2>
      {data.enabled ? (
        <>
          <p>{data.addresses.map((a) => <code key={a}>https://{a} </code>)}(password of <code>agent</code>)</p>
          <p>Certificate SHA-256: <code className="fingerprint">{data.fingerprint}</code></p>
          <p className="hint">Your browser warns about this self-signed certificate: continue only if it shows this fingerprint.</p>
        </>
      ) : <p>Off. Turn it on in Settings, Web UI.</p>}
    </div>
  );
}
```
Find:
```tsx
      <UpdateCard />
```
Replace with:
```tsx
      <LanCard />
      <UpdateCard />
```

In `web/ui/src/pages/Settings.tsx`, find:
```tsx
  { key: 'AGENTOS_WEB', label: 'Web UI enabled', type: 'bool' },
];
```
Replace with:
```tsx
  { key: 'AGENTOS_WEB', label: 'Web UI enabled', type: 'bool' },
  { key: 'AGENTOS_WEB_LAN', label: 'Also on the local network, with the password of agent (https://<LAN address>)', type: 'bool' },
];
```
Find:
```tsx
    return changed.AGENTOS_WEB !== '0' || confirmAction('Disable the web UI? You will need SSH or the console to turn it back on.');
```
Replace with:
```tsx
    if (changed.AGENTOS_WEB_LAN === '1' && !confirmAction('Anyone on your local network who knows the password of agent gets full control of this machine. Tailscale is safer. Allow LAN access?')) return false;
    if (changed.AGENTOS_WEB_LAN === '0' && me?.lan && !confirmAction('You are using LAN access: you will lose this page. Continue?')) return false;
    return changed.AGENTOS_WEB !== '0' || confirmAction('Disable the web UI? You will need SSH or the console to turn it back on.');
```

Append to `web/ui/src/style.css`:
```css
.fingerprint { word-break: break-all; }
```

- [ ] **Step 4: Run the tests and the build**

Run: `cd web/ui && npx tsc -p tsconfig.json && npx vitest run 2>&1 | tail -4 && npm run build 2>&1 | tail -1`
Expected: `Tests  29 passed (29)`, then `✓ built in …`.

- [ ] **Step 5: Commit**

```bash
git add web/ui/src/{api.ts,App.tsx,types.ts,style.css} web/ui/src/pages/{System,Settings}.tsx web/ui/test/lan.test.tsx
git commit -m "feat(web-lan): UI: Log out, reload on an expired session, LAN access on System, the setting in Settings"
```

---
### Task 4: The console banner, the installer question, and `agentos-config`

**Files:**
- Modify: `package/usr/local/lib/agentos/web-conf` (the console block), `package/usr/local/sbin/agentos-firstboot`, `package/usr/local/bin/agentos-config`, `test/web_conf_test.sh` (append), `installer/mkosi.extra/usr/local/sbin/agentos-install`, `installer/mkosi.extra/usr/lib/agentos-installer/lib.sh`, `installer/mkosi.extra/usr/share/agentos/data/agentos.env.example`, `test/installer_test.sh`, `test/checks/96-web.sh` (`check_web_conf_published`)

**Interfaces:**
- Consumes: `web-conf`'s variables `wl`, `fp`, `ws`; `lan_ipv4s`, `agent_has_password` (Task 1); `web.conf`'s `FINGERPRINT=`.
- Produces:
  - `/run/issue.d/50-agentos-web.issue`, always: `Web UI: https://<ip>  (LAN login)` (at most two), `LAN certificate SHA-256: <bytes 1-16>` and an indented line with bytes 17-32; `Web UI: https://<tailnet name>` when serve is `ok`; `Web UI: tailscale serve failed: …`; else `Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)`.
  - `sudo agentos-config show-web-fingerprint`: prints the fingerprint, or exits 1 with "LAN access to the web UI is off: …"; menu items `weblan`, `webfp`.
  - `lib.sh` `web_ui_summary <1|other> <0|1>`; the installer writes `AGENTOS_WEB_LAN=0|1`.

- [ ] **Step 1: Write the failing tests**

Append to `test/web_conf_test.sh`:
```bash

# The console's "Web UI:" lines: two LAN addresses at most (not Tailscale or Docker), the fingerprint
# in two halves, each line within 80 columns; the tailnet name when serve is on; else how to turn it on.
OFF='Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)'
run 1 P tailscale-down >/dev/null
[ "$(cat "$ISSUE")" = "Web UI: https://192.168.1.50  (LAN login)
Web UI: https://10.0.0.7  (LAN login)
LAN certificate SHA-256: B4:A0:73:5F:85:CC:CE:06:76:AE:B3:64:CA:36:6A:F8
                         BC:6B:EF:B4:BC:FD:7F:9C:0E:CB:D9:6E:DE:D2:A9:B8" ] || fail "console, LAN on"
awk 'length > 80 { exit 1 }' "$ISSUE" || fail "console line over 80 columns"
run 1 P ok >/dev/null
grep -qx 'Web UI: https://box.tail1234.ts.net' "$ISSUE" && grep -qx 'Web UI: https://192.168.1.50  (LAN login)' "$ISSUE" || fail "console, both"
run 0 P ok >/dev/null
[ "$(cat "$ISSUE")" = 'Web UI: https://box.tail1234.ts.net' ] || fail "console, tailscale only"
for args in '1 L tailscale-down' '0 P tailscale-down' '1 P ok ok 0'; do
  # shellcheck disable=SC2086 # deliberate word splitting into run's arguments
  run $args >/dev/null; grep -qx "$OFF" "$ISSUE" || fail "console, off ($args)"
done
run 0 P 'failed: Serve is not enabled on your tailnet.' >/dev/null
grep -qx 'Web UI: tailscale serve failed: Serve is not enabled on your tailnet.' "$ISSUE" && grep -qx "$OFF" "$ISSUE" || fail "console, serve failed"
echo "web-conf console OK"
```

In `test/installer_test.sh`, find:
```bash
echo "installer lib OK"
```
Replace with:
```bash
# web_ui_summary: how the summary screen says the web UI will be reachable
[ "$(web_ui_summary 0 0)" = 'off (turn it on later: sudo agentos-config)' ] || fail "web_ui_summary off"
[ "$(web_ui_summary '' 0)" = 'off (turn it on later: sudo agentos-config)' ] || fail "web_ui_summary no key"
[ "$(web_ui_summary 1 0)" = 'on the tailnet, once you allow your login (AGENTOS_WEB_USERS)' ] || fail "web_ui_summary tailnet"
[ "$(web_ui_summary 0 1)" = 'https://<LAN address> (password login)' ] || fail "web_ui_summary LAN"
[ "$(web_ui_summary 1 1)" = 'https://<LAN address> (password login); also on the tailnet, once you allow your login (AGENTOS_WEB_USERS)' ] || fail "web_ui_summary both"

echo "installer lib OK"
```

In `test/checks/96-web.sh`, find:
```bash
      grep -qx SERVE=tailscale-down /etc/agentos/web.conf && test ! -e /run/issue.d/50-agentos-web.issue'
```
Replace with:
```bash
      grep -qx SERVE=tailscale-down /etc/agentos/web.conf && grep -qx LAN=0 /etc/agentos/web.conf &&
      grep -qx "Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)" /run/issue.d/50-agentos-web.issue'
```

- [ ] **Step 2: Run them to see them fail**

Run: `.superpowers/sdd/devvm.sh sh 'test/web_conf_test.sh; test/installer_test.sh'`
Expected: `web-conf OK`, then `FAIL: console, LAN on` (with the files printed: no issue file); `test/installer_test.sh: line …: web_ui_summary: command not found` and `FAIL: web_ui_summary off`.

- [ ] **Step 3: The console lines**

In `package/usr/local/lib/agentos/web-conf`, find:
```bash
# agentos-web (which runs as agent: agentos.env is root-only).
```
Replace with:
```bash
# agentos-web (which runs as agent: agentos.env is root-only) and the console's "Web UI:" lines.
```
Then replace the block from `# Say why on the console too` through its closing `fi` with:
```bash
# The console: agetty prints /run/issue.d/*.issue after /etc/issue. The fingerprint is split in two
# halves of 16 bytes, so each line fits 80 columns.
[[ $ws != failed* ]] || echo "warning: web UI: tailscale serve $ws" >&2   # docs/tailscale-acl.md
install -d "$(dirname "$ISSUE")"
{
  if [ "$wl" = 1 ]; then
    ips=$(lan_ipv4s | head -2)
    for ip in ${ips:-$(hostname)}; do printf 'Web UI: https://%s  (LAN login)\n' "$ip"; done
    printf 'LAN certificate SHA-256: %s\n                         %s\n' "${fp:0:47}" "${fp:48}"
  fi
  if [ "$ws" = ok ]; then
    n=$("${TAILSCALE:-tailscale}" status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//') || n=
    [ -z "$n" ] || printf 'Web UI: https://%s\n' "$n"
  elif [[ $ws == failed* ]]; then
    printf 'Web UI: tailscale serve %s\n' "$ws"
  fi
  [ "$wl" = 1 ] || [ "$ws" = ok ] || echo 'Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)'
  echo
} > "$ISSUE"
```

In `package/usr/local/sbin/agentos-firstboot`, find:
```bash
web=$(/usr/local/lib/agentos/web-conf)
```
Replace with:
```bash
web=$(/usr/local/lib/agentos/web-conf)
agetty --reload 2>/dev/null || true   # login prompts already shown reprint the new lines
```

- [ ] **Step 4: `agentos-config`**

In `package/usr/local/bin/agentos-config`, find:
```bash
  return "$rc"
}
```
(the end of `cmd_apply`, Task 1) and replace with:
```bash
  return "$rc"
}
cmd_show_web_fingerprint() {
  local fp; fp=$(sed -n 's/^FINGERPRINT=//p' /etc/agentos/web.conf 2>/dev/null)
  [ -n "$fp" ] || { echo "LAN access to the web UI is off: sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply" >&2; return 1; }
  printf '%s\n' "$fp"
}
```
Find:
```bash
    c=$(whiptail --title "AgentOS configuration" --menu "Choose a setting" 22 72 12 \
```
Replace with:
```bash
    c=$(whiptail --title "AgentOS configuration" --menu "Choose a setting" 24 72 14 \
```
Find:
```bash
      webui     "Web UI: tailnet logins allowed to use it" \
```
Replace with:
```bash
      webui     "Web UI: tailnet logins allowed to use it" \
      weblan    "Web UI on the local network (password login)" \
      webfp     "Show the web UI's LAN certificate fingerprint" \
```
Find:
```bash
      solenta)   whiptail --scrolltext
```
Replace with:
```bash
      weblan)    if whiptail --defaultno --yesno "Allow the web UI on your local network, at https://<this machine's address>, with the password of 'agent'?\n\nAnyone on your network who knows that password gets full control of this machine. Tailscale is safer." 12 74; then
                   agent_has_password || { whiptail --msgbox "LAN access needs a password for 'agent'. Set one now." 8 60; passwd agent || true; }
                   cmd_set AGENTOS_WEB_LAN 1
                 else cmd_set AGENTOS_WEB_LAN 0; fi ;;
      webfp)     whiptail --msgbox "$(fp=$(cmd_show_web_fingerprint 2>&1) && printf 'Compare this with the certificate your browser shows for https://<this machine>:\n\n%s' "$fp" || printf '%s' "$fp")" 12 76 ;;
      solenta)   whiptail --scrolltext
```
Find:
```bash
  show-mcp-token)  cat /etc/agentos/mcp-token ;;
```
Replace with:
```bash
  show-mcp-token)  cat /etc/agentos/mcp-token ;;
  show-web-fingerprint) cmd_show_web_fingerprint ;;
```
And in the usage line, replace `|apply|show-mcp-token|solenta [PATH]` with `|apply|show-mcp-token|show-web-fingerprint|solenta [PATH]`.

- [ ] **Step 5: The installer**

Append to `installer/mkosi.extra/usr/lib/agentos-installer/lib.sh`:
```bash

# web_ui_summary <tailscale key: 1, else none> <LAN access 0|1>: the summary screen's "Web UI:" value.
web_ui_summary() {
  local t=""
  [ "$1" != 1 ] || t="on the tailnet, once you allow your login (AGENTOS_WEB_USERS)"
  if [ "$2" = 1 ]; then printf 'https://<LAN address> (password login)%s' "${t:+; also $t}"
  elif [ -n "$t" ]; then printf '%s' "$t"
  else printf 'off (turn it on later: sudo agentos-config)'; fi
}
```

In `installer/mkosi.extra/usr/local/sbin/agentos-install`, find:
```bash
  v=$(get AGENTOS_PASSWORD_HASH); [ -z "$v" ] || valid_password_hash "$v" || die "AGENTOS_PASSWORD_HASH must be a \$6\$ or \$y\$ crypt hash (openssl passwd -6)"
```
Replace with:
```bash
  v=$(get AGENTOS_PASSWORD_HASH); [ -z "$v" ] || valid_password_hash "$v" || die "AGENTOS_PASSWORD_HASH must be a \$6\$ or \$y\$ crypt hash (openssl passwd -6)"
  [ "$(get AGENTOS_WEB_LAN)" != 1 ] || [ -n "$v" ] || die "AGENTOS_WEB_LAN=1 needs AGENTOS_PASSWORD_HASH: the LAN login is the password of agent"
```
Find:
```bash
  local pw pw2 hash="" key gh ts lan k v cm parts apikeys=""
```
Replace with:
```bash
  local pw pw2 hash="" key gh ts lan weblan=0 k v cm parts apikeys=""
```
Find:
```bash
  [ -n "$ts" ] || ! W --title "SSH from LAN" --yesno "No Tailscale key. Allow SSH (key-only) from your local network?" 8 70 || lan=1
```
Replace with:
```bash
  [ -n "$ts" ] || ! W --title "SSH from LAN" --yesno "No Tailscale key. Allow SSH (key-only) from your local network?" 8 70 || lan=1
  # LAN access logs in with the password above, so it is offered only when one is set.
  if [ -n "$hash" ] && W --title "Web UI" --defaultno --yesno "Allow the web UI on your local network (password login)?\n\nIt is then at https://<this machine's address>, behind the password you set. Anyone on your network who knows it gets full control of this machine. Tailscale is safer." 13 72; then
    weblan=1
  fi
```
Find:
```bash
\nLAN SSH:   $lan\n\nInstall now?" 18 72 || return 1
```
Replace with:
```bash
\nLAN SSH:   $lan\nWeb UI:    $(web_ui_summary "${ts:+1}" "$weblan")\n\nInstall now?" 20 76 || return 1
```
Find:
```bash
     printf 'AGENTOS_INSTALL_DISK=%s\nAGENTOS_HOSTNAME=%s\nAGENTOS_CONSOLE=%s\nAGENTOS_LAN_SSH=%s\n' "$disk" "$hn" "$cm" "$lan"
```
Replace with:
```bash
     printf 'AGENTOS_INSTALL_DISK=%s\nAGENTOS_HOSTNAME=%s\nAGENTOS_CONSOLE=%s\nAGENTOS_LAN_SSH=%s\nAGENTOS_WEB_LAN=%s\n' "$disk" "$hn" "$cm" "$lan" "$weblan"
```
(`install_from_env` runs `agentos-config set` for each setting before it sets the password hash, which is why `agentos-config set` doesn't check the password: firstboot does, on the installed box.)

In `installer/mkosi.extra/usr/share/agentos/data/agentos.env.example`, find:
```
#AGENTOS_LAN_SSH=1
```
Replace with:
```
#AGENTOS_LAN_SSH=1
# The web UI on the local network, https://<LAN address>, logging in with the password above
#AGENTOS_WEB_LAN=1
```

- [ ] **Step 6: Run the tests and shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'test/web_conf_test.sh && test/installer_test.sh && shellcheck -S warning package/usr/local/lib/agentos/web-conf package/usr/local/sbin/agentos-firstboot package/usr/local/bin/agentos-config installer/mkosi.extra/usr/local/sbin/* installer/mkosi.extra/usr/lib/agentos-installer/lib.sh test/web_conf_test.sh test/installer_test.sh test/checks/96-web.sh && echo SC-OK'`
Expected:
```
web-conf OK
web-conf console OK
installer lib OK
SC-OK
```

- [ ] **Step 7: Commit**

```bash
git add package/usr/local/lib/agentos/web-conf package/usr/local/sbin/agentos-firstboot package/usr/local/bin/agentos-config \
  installer/mkosi.extra/usr/local/sbin/agentos-install installer/mkosi.extra/usr/lib/agentos-installer/lib.sh \
  installer/mkosi.extra/usr/share/agentos/data/agentos.env.example test/web_conf_test.sh test/installer_test.sh test/checks/96-web.sh
git commit -m "feat(web-lan): the console's Web UI lines, the installer question, agentos-config weblan/show-web-fingerprint"
```

---
### Task 5: In-VM checks, docs, and the full smoke run

**Files:**
- Modify: `test/smoke.sh`, `test/web_ws.mjs`, `test/checks/96-web.sh` (append), `README.md`

**Interfaces:**
- Consumes: everything above. From `smoke.sh`: `vm`, `$HERE`, `$PORT`; QEMU user networking (guest 10.0.2.15, and the host's forwarded connections arrive from 10.0.2.2).
- Produces: `$HOSTPORT_HTTPS` (`$PORT + 4`, forwarded to the guest's 443); `WS_COOKIE=… WS_HOST=… node web_ws.mjs term …` (the LAN listener).

- [ ] **Step 1: Write the checks**

In `test/smoke.sh`, find:
```bash
  PORT=$2; HOSTPORT_HTTP=$(( $2 + 1 )); HOSTPORT_NOVNC=$(( $2 + 2 )); HOSTPORT_MCP=$(( $2 + 3 ))
  export PORT HOSTPORT_HTTP HOSTPORT_NOVNC HOSTPORT_MCP MODE=$mode
```
Replace with:
```bash
  PORT=$2; HOSTPORT_HTTP=$(( $2 + 1 )); HOSTPORT_NOVNC=$(( $2 + 2 )); HOSTPORT_MCP=$(( $2 + 3 )); HOSTPORT_HTTPS=$(( $2 + 4 ))
  export PORT HOSTPORT_HTTP HOSTPORT_NOVNC HOSTPORT_MCP HOSTPORT_HTTPS MODE=$mode
```
Find:
```bash
hostfwd=tcp:127.0.0.1:$HOSTPORT_MCP-:8765" \
```
Replace with:
```bash
hostfwd=tcp:127.0.0.1:$HOSTPORT_MCP-:8765,hostfwd=tcp:127.0.0.1:$HOSTPORT_HTTPS-:443" \
```
(Modes are 10 ports apart, so `PORT + 4` is free.)

In `test/web_ws.mjs`, find:
```js
// Prints "WS OK" and exits 0 once the expected text arrives; exits 1 on close, HTTP error or timeout.
```
Replace with:
```js
// Prints "WS OK" and exits 0 once the expected text arrives; exits 1 on close, HTTP error or timeout.
// LAN listener: WS_COOKIE=<__Host-agentos-session=...> WS_HOST=<guest address> connects to
// wss://<WS_HOST>:7443 with that session instead of a Tailscale identity.
```
Find:
```js
const ws = new WebSocket(`ws://127.0.0.1:7070${path}`, {
  headers: { 'Tailscale-User-Login': process.env.LOGIN ?? 'smoke@example.com', Origin: 'http://127.0.0.1:7070' },
});
```
Replace with:
```js
const lan = process.env.WS_COOKIE;
const ws = lan
  ? new WebSocket(`wss://${process.env.WS_HOST}:7443${path}`, {
    headers: { Cookie: lan, Host: process.env.WS_HOST, Origin: `https://${process.env.WS_HOST}` }, rejectUnauthorized: false })
  : new WebSocket(`ws://127.0.0.1:7070${path}`, {
    headers: { 'Tailscale-User-Login': process.env.LOGIN ?? 'smoke@example.com', Origin: 'http://127.0.0.1:7070' } });
```
(From the guest itself, traffic to its own address never passes prerouting, so the probe connects to 7443 directly; `iif lo accept` lets it in.)

In `test/checks/96-web.sh`, find:
```bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.
```
Replace with:
```bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.
# shellcheck disable=SC2154 # HOSTPORT_HTTPS comes from smoke.sh
```
And append:
```bash

# LAN access (AGENTOS_WEB_LAN), from the host: QEMU forwards $HOSTPORT_HTTPS to the guest's 443, and
# --connect-to keeps the guest's own address in the URL, so Host and Origin are what a LAN browser
# sends. The guest sees these connections come from 10.0.2.2.
GIP=10.0.2.15   # the guest's address on QEMU's user network
LANPW='smoke LAN pw 7'
lan()      { curl -sk -m 15 --connect-to "$GIP:443:127.0.0.1:$HOSTPORT_HTTPS" "$@"; }
lan_code() { lan -o /dev/null -w '%{http_code}' "$@"; }
lan_post() { lan_code -X POST -H "Origin: https://$GIP" -H 'X-AgentOS: 1' -H 'Content-Type: application/json' "$@"; }
lan_up()   { vm 'for _ in $(seq 1 30); do ss -Htln "sport = :7443" | grep -q . && exit 0; sleep 1; done; exit 1'; }

check_web_lan_closed_when_off() {
  # Off (the default): no listener, nothing redirected, nothing answers on 443.
  vm 'grep -qx LAN=0 /etc/agentos/web.conf && ! sudo nft list set inet agentos lan_web | grep -qw 443 &&
      ! ss -Htln "sport = :7443" | grep -q .' &&
  [ "$(lan_code -m 8 "https://$GIP/")" = 000 ]
}
check_web_lan_refused_without_password() {
  # No password for agent (the smoke image has none): apply says so, and LAN access stays off.
  local rc=0
  vm 'test "$(sudo passwd -S agent | cut -d" " -f2)" != P && sudo agentos-config set AGENTOS_WEB_LAN 1 &&
      { out=$(sudo agentos-config apply 2>&1); test $? = 3; } &&
      echo "$out" | grep -q "set a password for agent first (sudo agentos-config password)" &&
      grep -qx LAN=0 /etc/agentos/web.conf && ! ss -Htln "sport = :7443" | grep -q .' || rc=1
  vm 'sudo agentos-config set AGENTOS_WEB_LAN 0 && sudo agentos-config apply' || rc=1
  return "$rc"
}
check_web_lan_login_end_to_end() {
  local rc=0 orig hdr cookie fp
  orig=$(vm 'sudo getent shadow agent | cut -d: -f2') || return 1
  # chpasswd: yescrypt, as `passwd` and `agentos-config password` write it.
  vm 'sudo chpasswd' <<< "agent:$LANPW" &&
  vm 'sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply && grep -qx LAN=1 /etc/agentos/web.conf' && lan_up || rc=1
  if [ "$rc" = 0 ]; then
    # Unauthenticated: the login page for a page, 401 for the API; a foreign Host is refused.
    lan "https://$GIP/" | grep -q 'Password of <code>agent</code>' &&
    [ "$(lan_code "https://$GIP/api/me")" = 401 ] &&
    [ "$(lan_code -H 'Host: evil.example' "https://$GIP/")" = 403 ] &&
    # 5 wrong passwords get 401, the 6th attempt 429, even with the right password.
    [ "$(lan_post -d '{"password":"wrong1"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong2"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong3"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong4"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong5"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d "{\"password\":\"$LANPW\"}" "https://$GIP/api/lan/login")" = 429 ] || rc=1
    # A restart forgets the failures (and every session), as documented.
    vm 'sudo systemctl restart agentos-web.service' && lan_up || rc=1
    hdr=$(lan -D - -o /dev/null -X POST -H "Origin: https://$GIP" -H 'X-AgentOS: 1' -H 'Content-Type: application/json' \
            -d "{\"password\":\"$LANPW\"}" "https://$GIP/api/lan/login") || rc=1
    cookie=$(printf '%s' "$hdr" | tr -d '\r' | sed -n 's/^set-cookie: \(__Host-agentos-session=[A-Za-z0-9_-]\{43\}\); Secure; HttpOnly; SameSite=Strict; Path=\/$/\1/ip')
    [ -n "$cookie" ] &&
    lan -H "Cookie: $cookie" "https://$GIP/api/me" | grep -q '"login":"agent@lan(10.0.2.2)".*"lan":true' &&
    # CSRF: an unsafe action needs X-AgentOS (and the Origin), then works.
    [ "$(lan_code -X POST -H "Cookie: $cookie" -H "Origin: https://$GIP" -H 'Content-Type: application/json' \
          -d '{"cli":"shell","name":"lan"}' "https://$GIP/api/sessions")" = 403 ] &&
    [ "$(lan_post -H "Cookie: $cookie" -d '{"cli":"shell","name":"lan"}' "https://$GIP/api/sessions")" = 200 ] &&
    # The terminal WebSocket, from the guest straight to the listener (local traffic skips the redirect).
    vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" &&
    vm "WS_COOKIE='$cookie' WS_HOST=$GIP node /tmp/web_ws.mjs term ag-lan 'echo lan-\$((40+2))' lan-42" &&
    [ "$(lan_post -H "Cookie: $cookie" "https://$GIP/api/sessions/ag-lan/stop")" = 200 ] &&
    [ "$(lan_code -X DELETE -H "Cookie: $cookie" -H "Origin: https://$GIP" -H 'X-AgentOS: 1' "https://$GIP/api/sessions/ag-lan")" = 200 ] &&
    # The fingerprint the console, agentos-config and the System page show is the served certificate's.
    fp=$(vm 'sudo agentos-config show-web-fingerprint') &&
    [ "$(openssl s_client -connect "127.0.0.1:$HOSTPORT_HTTPS" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | sed 's/^[^=]*=//')" = "$fp" ] &&
    lan -H "Cookie: $cookie" "https://$GIP/api/system/lan" | grep -q "\"fingerprint\":\"$fp\"" &&
    vm "grep -qx 'Web UI: https://$GIP  (LAN login)' /run/issue.d/50-agentos-web.issue &&
        grep -qx 'LAN certificate SHA-256: ${fp:0:47}' /run/issue.d/50-agentos-web.issue" &&
    # Logout ends the session; the audit log has every step and never the password.
    [ "$(lan_post -H "Cookie: $cookie" "https://$GIP/api/lan/logout")" = 200 ] &&
    [ "$(lan_code -H "Cookie: $cookie" "https://$GIP/api/me")" = 401 ] &&
    vm 'j=$(sudo journalctl -b -t agentos-web -p notice --no-pager -o cat) &&
        for l in "agent@lan(10.0.2.2) login-failed -" "agent@lan(10.0.2.2) login -" "agent@lan(10.0.2.2) logout -"; do
          echo "$j" | grep -qxF "$l" || { echo "no audit line: $l"; exit 1; }
        done' &&
    ! vm "sudo journalctl -b --no-pager | grep -qF '$LANPW'" || rc=1
  fi
  # Off again: the password goes back to what it was, and 443 is closed.
  vm 'sudo agentos-config set AGENTOS_WEB_LAN 0 && sudo agentos-config apply && grep -qx LAN=0 /etc/agentos/web.conf' || rc=1
  vm "sudo usermod -p '$orig' agent" || rc=1
  [ "$(lan_code -m 8 "https://$GIP/")" = 000 ] || rc=1
  return "$rc"
}
```

The checks run sorted: `check_web_lan_closed_when_off`, `check_web_lan_login_end_to_end` (gives `agent` a password, turns LAN access on, and puts both back), `check_web_lan_refused_without_password` (needs the image's state: no password). The existing Tailscale-path checks (`check_web_identity_codes`, `check_web_csrf`, `check_web_session_terminal`, `check_web_e2e`, …) stay as they are and must still pass.

- [ ] **Step 2: shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning test/smoke.sh test/checks/96-web.sh && node --check test/web_ws.mjs && echo SC-OK'`
Expected: `SC-OK`.

- [ ] **Step 3: Docs**

In `README.md`, find:
```markdown
- **SSH:** `ssh agent@<box>` over Tailscale, with Tailscale SSH or your key. Password SSH is off. Set `AGENTOS_LAN_SSH=1` to also accept key-only SSH on the LAN.
- **User:** everything runs as **`agent`**, which has passwordless sudo and is in the `docker` group.
```
Replace with:
````markdown
- **SSH:** `ssh agent@<box>` over Tailscale, with Tailscale SSH or your key. Password SSH is off. Set `AGENTOS_LAN_SSH=1` to also accept key-only SSH on the LAN.
- **User:** everything runs as **`agent`**, which has passwordless sudo and is in the `docker` group.

### Without Tailscale: the web UI on your local network

On a trusted home or lab network you can also open the web UI at **`https://<the box's LAN address>`**, logging in with the password of `agent`. It is off by default. Turn it on in the installer, in the web UI's Settings page, in `sudo agentos-config` ("Web UI on the local network"), or with:

```bash
sudo agentos-config password                    # if agent has no password yet
sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply
```

The box makes its own certificate, so your browser warns about it the first time. Continue only if the certificate's SHA-256 fingerprint matches the one on the box's console, in `sudo agentos-config show-web-fingerprint`, or on the web UI's System page. The certificate lasts 825 days, and the box makes a new one (with a new fingerprint) a month before it expires, or after you delete `/etc/agentos/web-lan/`.

- `https://<hostname>` and `https://<hostname>.local` work too, where your network resolves those names.
- A session ends after 12 hours without use, after 7 days, on **Log out**, and when the web UI restarts (an update or `agentos-config apply` that changes LAN access), which logs everyone out.
- After 5 wrong passwords from one address, or 30 from anywhere, within 10 minutes, logins are refused until the 10 minutes have passed. Every login, failed login and logout is in the audit log (`journalctl -t agentos-web`), as `agent@lan(<address>)`.
- Without a password for `agent`, LAN access stays off, and `apply` says so.
- Tailscale keeps working as before, alongside it.
````

Find:
```markdown
The footer shows the installed AgentOS version. Access requires a Tailscale identity in `AGENTOS_WEB_USERS`.
```
Replace with:
```markdown
The footer shows the installed AgentOS version. Access requires a Tailscale identity in `AGENTOS_WEB_USERS`, or, with LAN access on, the password of `agent` (see [Without Tailscale](#without-tailscale-the-web-ui-on-your-local-network)).
```

Find:
```markdown
- **The network is closed by default.** SSH is reachable only over Tailscale unless you set `AGENTOS_LAN_SSH=1`, and password SSH is off. The web UI, noVNC and VNC listen on loopback only and are published only through `tailscale serve`. The tailnet ACL above stops the box from reaching your other devices.
```
Replace with:
```markdown
- **The network is closed by default.** SSH is reachable only over Tailscale unless you set `AGENTOS_LAN_SSH=1`, and password SSH is off. The web UI, noVNC and VNC listen on loopback only and are published only through `tailscale serve`, unless you set `AGENTOS_WEB_LAN=1`. The tailnet ACL above stops the box from reaching your other devices.
- **LAN access to the web UI is root-equivalent access for anyone who can reach the box's LAN address and knows the `agent` password.** Use it only on a network you trust (home, lab), with a strong password, and prefer Tailscale for anything else. It is HTTPS only (no port 80); the password is checked by a root helper that reads it on stdin, so it never appears in a command line, a log or the audit trail. Sessions live only in the web server's memory, and logins are rate-limited. noVNC, MCP HTTP and SSH are not opened by it.
```

In the settings table, find:
```markdown
| `AGENTOS_WEB_USERS` | — | Comma-separated tailnet logins allowed into the web UI. Empty means nobody. |
```
Replace with:
```markdown
| `AGENTOS_WEB_USERS` | — | Comma-separated tailnet logins allowed into the web UI. Empty means nobody. |
| `AGENTOS_WEB_LAN` | `0` | `1` = also serve the web UI at `https://<LAN address>`, with the password of `agent`. |
```

In "First boot and configuration", find:
```bash
sudo agentos-config solenta            # Solenta pairing info
```
Replace with:
```bash
sudo agentos-config solenta            # Solenta pairing info
sudo agentos-config show-web-fingerprint   # the LAN certificate's SHA-256 (AGENTOS_WEB_LAN=1)
```

- [ ] **Step 4: Build, and run every check in every mode**

Run: `.superpowers/sdd/devvm.sh run 'AGENTOS_DEV=1 tools/build-deb.sh && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed'`, then `.superpowers/sdd/devvm.sh wait <JOB>` until it isn't 124.
Expected: every earlier check still passes, and in `uefi` and `bios`:
```
PASS [uefi] check_web_conf_published
PASS [uefi] check_web_lan_closed_when_off
PASS [uefi] check_web_lan_login_end_to_end
PASS [uefi] check_web_lan_refused_without_password
PASS [uefi] check_web_unit_shape
…
ALL CHECKS PASSED (N skipped)
```
`check_web_lan_login_end_to_end` takes about a minute: two applies, a restart and five 1 s failure delays. To re-run only the web checks: prefix the smoke command with `SMOKE_ONLY=web_`.

- [ ] **Step 5: Manual checks (from the spec; not automated)**

1. **A real browser on the LAN:** on a box (or a bridged VM) with LAN access on, open `https://<LAN address>` in Firefox and Chrome. Expect the certificate warning, with a SHA-256 that matches the console's two lines; then the login page, a wrong password ("Wrong password."), the right one (the Overview), a terminal, a desktop through `/vnc`, **Log out** (back to the login page).
2. **Safari on macOS and iOS:** the same. The 825-day certificate with `serverAuth` should offer "visit this website" after the warning. If Safari refuses to connect at all, look at the certificate's details first (Apple's rules, fact table).
3. **Tailscale and LAN together:** on a box joined to a tailnet with HTTPS certificates, with LAN access on: `https://<box>.<tailnet>.ts.net` still works with Tailscale identity (no login page), and `tailscale serve status` still shows 443; the console shows both `Web UI:` lines.
4. **The console:** on a monitor, the login prompt shows the `Web UI:` lines; after `sudo agentos-config set AGENTOS_WEB_LAN 0 && sudo agentos-config apply` it reprints with `Web UI: off …` (`agetty --reload`).

- [ ] **Step 6: Commit**

```bash
git add test/smoke.sh test/web_ws.mjs test/checks/96-web.sh README.md
git commit -m "test(web-lan): LAN access in the VM (closed when off, login, 429, CSRF, terminal, fingerprint, banner); docs"
```

---

## Spec coverage

| Spec item | Task (test) |
|---|---|
| `AGENTOS_WEB_LAN=0\|1`, default 0, validated in `env.sh` | 1 (`env_test.sh`, `web_conf_test.sh` invalid value) |
| Set from the installer (default no), `agentos.env`, `agentos-config set`/menu, the Settings page | 4 (installer question, `web_ui_summary`, menu `weblan`), 2 (`PLAIN_KEYS`), 3 (`lan.test.tsx` Settings) |
| Apply: certificate if missing, firewall, `LAN=1` + fingerprint in `web.conf`, restart `agentos-web` | 1 (`web_conf_test.sh`: `restart` on a change only; firstboot; `agentos-firewall`), 5 (`check_web_lan_login_end_to_end`); adjustments 5, 6 |
| No usable password: apply refuses and says `sudo agentos-config password` | 1 (`web_conf_test.sh` L/NP, `cmd_apply`), 2 (502 message test), 3 (Settings shows it), 4 (installer, menu), 5 (`check_web_lan_refused_without_password`); adjustment 7 |
| Certificate: openssl ECDSA P-256 in `/etc/agentos/web-lan`, key root + the web user only, SAN hostname/.local/IPv4s, kept, deleted → new | 1 (`web_lan_cert_test.sh`); fact table (`User=agent`); adjustment 3 (825 days, renewal) |
| Fingerprint in `web.conf`, on the console, `agentos-config` (menu + `show-web-fingerprint`), the System page | 1 (`web.conf`), 4 (console lines, `webfp`, `show-web-fingerprint`), 2 (`/api/system/lan` test), 3 (System test), 5 (served certificate = shown fingerprint); adjustment 4 |
| Loopback listener unchanged | 2 ("the Tailscale listener is unchanged", the existing suites pass), 5 (existing checks, `check_web_unit_shape`) |
| Same process, same routes, separate auth mode per listener; how to bind 443 without weakening hardening | 2 (`buildApp(deps, lan)`, `lan.test.ts` mode tests); fact table (Fastify, tailscaled's 443, ambient caps); adjustment 1 |
| Host check (hostname, `.local`, IPs, `:443`; else 403; rebinding) | 2 (`Host allowlist` tests), 5 (`Host: evil.example` → 403); adjustment 11 |
| Origin `https://<Host>` exactly | 2 (CSRF tests, login CSRF test) |
| Firewall: 443 on non-tailscale interfaces only while on; closed when off | 1 (`firewall.nft`, `agentos-firewall`); fact table (netns probe); 5 (`check_web_lan_closed_when_off`, closed again after) |
| Unauthenticated: login page (static, no third-party), API and upgrades 401 | 2 (`without a session` tests), 5 (curl login page, `/api/me` 401); adjustment 8 |
| Login via a root helper, stdin only, never argv/sudo log; mechanism verified | 1 (`check_password_test.sh`), 2 (argv/input test); fact table (perl crypt, sudo log) |
| Session: 256-bit token, memory only, 12 h idle, 7 days absolute; cookie flags | 2 (cookie and token-length test, idle and absolute tests), 5 (cookie flags from the real server) |
| Audit `agent@lan(<ip>) login`, `login failed`; 401 after a constant 1 s | 2 (audit, sleep 1000, "measured from the start"), 5 (journal lines) |
| Rate limits: 5 per IP / 10 min → 429; 30 global | 2 (per-IP, window, global, parallel tests), 5 (6th attempt 429); adjustment 9 |
| Logout: deletes the session, clears the cookie, audited | 2 (logout test), 3 (Log out button), 5 (401 after logout, audit line) |
| Same permissions as a Tailscale user; login label; CSRF unchanged | 2 (`/api/me` login, CSRF tests), 5 (403 without `X-AgentOS`, 200 with) |
| Restart clears sessions, documented | 2 (`LanState` in memory), 5 (restart clears the limiter; README) |
| Console banner: always a `Web UI:` line (LAN lines + fingerprint, tailnet, or off) | 4 (`web_conf_test.sh` console part, `check_web_conf_published`), 5 (banner check); adjustment 4 |
| Installer summary says how the web UI is reachable | 4 (`web_ui_summary` in `installer_test.sh`) |
| Security notes: root-equivalent, docs recommend Tailscale; never logged/argv/plain HTTP; in-memory sessions; rate limits | "Security" above; 5 (README "Security model", "Without Tailscale"; journal grep for the password) |
| Unit tests (vitest), shell tests, in-VM checks as listed | 1, 2, 3, 4, 5 |
| Non-goals: no other accounts, no ACME, no port 80, nothing else exposed | Nothing added for them: only `agent`'s password is checked, only 443 is redirected (to the web UI), noVNC/MCP/SSH rules unchanged |

## Self-review

- **Spec coverage:** every row above maps to a task and a test. Deviations are under "Spec adjustments", each with its evidence in the fact table.
- **Placeholders:** none in code. Every new file is complete, and every edit to an existing file gives the exact text to find and its replacement, or the whole file. Task 1's `web-conf` and Task 1's part of `web_conf_test.sh` are the exact files Task 4 then edits; both stages were run.
- **Names and types across tasks:**
  - `web.conf`'s `LAN=`/`FINGERPRINT=` (Task 1, `web-conf`) are what `parseWebConf` reads (Task 2), what `agentos-firewall` greps (Task 1), what `show-web-fingerprint` prints (Task 4) and what the VM checks grep (Tasks 4, 5).
  - Port 7443 is `LAN_PORT` (Task 2), the redirect target in `firewall.nft` (Task 1), `lan_up` and `web_ws.mjs` (Task 5).
  - `/etc/agentos/web-lan/{key,cert}.pem` and group `agent` (Task 1, `web-lan-cert`) are `LAN_DIR` in `main.ts` (Task 2).
  - `check-password`'s path and exit code 0 are `CHECK_PASSWORD` and the `code === 0` test (Task 2).
  - `agentos-config apply`'s message (Task 1) is the string in `settings.test.ts` (Task 2), `lan.test.tsx` (Task 3) and `check_web_lan_refused_without_password` (Task 5).
  - `log in first` (Task 2, `lanDecide`) is what `api.ts` reloads on (Task 3). `/api/system/lan`'s shape (Task 2) is `LanInfo` (Task 3). `lanAddresses()` (Task 2) and `lan_ipv4s` (Task 1) use the same interface rule.
  - The console's line formats (Task 4) are the same strings in `web_conf_test.sh`, `96-web.sh` and the README.
- **Ordering:** each task's tests pass with only the earlier tasks applied: Task 1's shell tests with Task 1's `web-conf`; Task 2's vitest with Tasks 1-2; Task 3's with Tasks 1-3; Task 4's complete `web_conf_test.sh` with the final `web-conf`. Tasks 2 and 3 don't need a box: `buildApp` is tested with fake deps and a fake clock.
