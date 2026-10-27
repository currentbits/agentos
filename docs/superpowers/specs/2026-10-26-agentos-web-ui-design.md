# AgentOS Web UI — Design

Date: 2026-10-26
Status: Approved in brainstorming. Awaiting the user's spec review.
Builds on: `docs/superpowers/specs/2026-10-21-agentos-design.md` (the AgentOS base, desktops, installer), plus the `small-fixes` branch (idle-desktop reaper, `IDLE_MINUTES`). That branch must be merged before implementation starts.

## Goal

A web UI to control one AgentOS machine from a browser. You can:
- run and attach to agent sessions;
- watch and drive desktops;
- change every setting;
- operate the system (health, services, logs, updates, power).

It's reachable only over the tailnet, by allowlisted tailnet users.

## Decisions

| Topic | Decision |
|---|---|
| Scope v1 | Overview, Sessions, Desktops, Settings, System (incl. browser terminal) |
| Stack | Node 24 (already in image). Backend: TypeScript + Fastify. Frontend: React + Vite + TypeScript SPA |
| Reachability | `tailscale serve` HTTPS on `https://<host>.<tailnet>.ts.net`; app binds `127.0.0.1:7070` only |
| Authentication | Tailscale identity header (`Tailscale-User-Login`) checked against allowlist `AGENTOS_WEB_USERS` |
| Agent sessions | Interactive tmux sessions running a CLI in a directory; attached via browser terminal |
| State | No database: systemd, tmux, agentos-config, plus a small JSON sidecar per session |
| Shipping | Built at image-build time; static UI + compiled server in `/usr/local/lib/agentos/web` |

## 1. Architecture

### Process

`agentos-web.service`:
- runs Node 24 as user `agent`;
- listens on `127.0.0.1:7070` only;
- serves the compiled SPA and a JSON + WebSocket API.

It's enabled by default. `AGENTOS_WEB=0` (in agentos.env, via agentos-config) disables both the service and the tailscale serve config.

### Code layout

```
web/
  server/   TypeScript, Fastify, @fastify/websocket, node-pty, vitest
    src/auth.ts        identity + allowlist + CSRF/Origin checks (HTTP and WS)
    src/actions.ts     fixed table: action name → exact argv (sudo where needed)
    src/sessions.ts    tmux session lifecycle + sidecars
    src/desktops.ts    desktop list/create/destroy/thumbnail (systemd + scrot)
    src/settings.ts    read/write via agentos-config (secrets write-only)
    src/system.ts      health, services, journal tail, updates, power
    src/vnc.ts         same-origin WebSocket proxy to websockify, token added server-side
    src/terminal.ts    WebSocket ↔ node-pty running `tmux attach`
    src/audit.ts       journal audit lines for every mutating action
  ui/       React + Vite + TypeScript, xterm.js, noVNC client (from the Debian novnc package)
```

### Privilege

The service runs as `agent`. Root-requiring actions run through `sudo -n` with argv from the fixed table in `actions.ts`. Never a shell string, never user-supplied argv beyond validated parameters. The table:

- `agentos-config set KEY VALUE`, `agentos-config add-ssh-key KEY`, `agentos-config github-keys USER`, `agentos-config apply`
- `systemctl restart <unit>`, restricted to `agentos-*`, `docker`, `tailscaled`
- `journalctl -u <unit> -f -n 200 -o short-iso`, with the same unit restriction
- `agentos-update`, which runs as agent with no sudo
- `systemctl reboot`, `systemctl poweroff`
- removing an SSH key: a new `agentos-config remove-ssh-key FINGERPRINT` subcommand (see section 4)

Values are validated by `agentos-config` itself, so console and web behaviour are identical.

### Reachability and TLS

- Firstboot step: when Tailscale is up and `AGENTOS_WEB` isn't `0`, run `tailscale serve --bg --https=443 http://127.0.0.1:7070`. This is idempotent.
- It requires the tailnet to have HTTPS certificates enabled. If the serve command fails, firstboot logs a warning, and the Overview page and `/etc/issue` say why.
- No firewall change is needed: traffic arrives over `tailscale0`.

## 2. Authentication and request security

- **Identity.** `tailscale serve` adds `Tailscale-User-Login` (plus name and profile pic headers) to proxied requests. Every HTTP request and every WebSocket upgrade must carry a login in `AGENTOS_WEB_USERS` (comma-separated, exact match, case-insensitive):
  - missing header → 401;
  - login not on the list → 403.
- **Not configured.** When `AGENTOS_WEB_USERS` is empty, every request gets a static page: "You are `<login>`. Add yourself: `sudo agentos-config set AGENTOS_WEB_USERS <login>`". No API is reachable.
- **CSRF.** Mutating requests (POST, PUT, DELETE) need the header `X-AgentOS: 1` and an `Origin` equal to the serve hostname. WebSocket upgrades check `Origin` the same way.
- **Accepted residual risk.** Processes on the machine that run as root (tailscaled, for `tailscale serve`) or as `agent` can reach `127.0.0.1:7070` and forge the identity header. Both already have root or sudo, so this grants nothing new. Every other local user is refused: an nftables output rule in `table inet agentos` resets loopback connections to TCP port 7070 from any uid but 0 and 1000. Cross-site browser requests (`Sec-Fetch-Site: cross-site`) are refused too, except a top-level GET navigation.
- **Secrets.**
  - The API never returns secret values. "Set / not set" comes from reading key names only.
  - Secret values are sent only on write.
  - They never appear in logs or the audit trail; the audit records the key name only.
- **Desktops.** The browser connects to `/api/desktops/N/vnc` (same origin, authenticated). The server opens the websockify connection with the per-desktop token, so tokens never reach the browser. View-only is a noVNC client setting. That's acceptable because only allowlisted admins reach this page.
- **Audit.** Every mutating action writes a journal line, `agentos-web: <login> <action> <target>`, at notice level.
- **Unit hardening.** Deliberately light, because the service must run sudo. `NoNewPrivileges` must stay off. `ProtectHome` is off, because sessions live in `/home/agent`. It keeps `PrivateTmp=no` (the tmux socket lives in `/tmp/tmux-1000`) and `Restart=on-failure`.

## 3. Pages

The layout is a sidebar (Overview, Sessions, Desktops, Settings, System). The header shows the hostname, the tailnet address and the login. Dark-first; usable on tablets.

### Overview
- CPU, RAM, disk and load, polled every 5 s.
- Counts of sessions and desktops.
- Tailscale state and serve status.
- Quick actions: New session, New desktop, Open terminal.

### Sessions
- **List.** Every tmux server session of user `agent`: name, CLI, directory, created, attached-client count, state.
  - Sessions created by the UI have a sidecar `~/.config/agentos/sessions/<name>.json` (`cli`, `dir`, `created`, `createdBy`).
  - Other tmux sessions (console `main`, SSH-started ones) are listed as *external*.
- **New.** Pick a CLI (`claude | codex | grok | opencode | shell`) and a directory.
  - The directory is either a folder under `/home/agent`, chosen from a server-listed tree, or "clone repo": a git URL cloned into `~/work/<name>`.
  - The name is optional. Valid names match `[a-z0-9-]{1,32}`, unique; default `<cli>-<n>`.
  - The server runs `tmux new-session -d -s ag-<name> -c <dir> -- bash -lc '<cli>'` as agent (login shell: PATH and API keys load).
  - The directory must resolve, via realpath, inside `/home/agent`.
- **Open.** A full-page xterm.js terminal over `/api/sessions/<name>/terminal`. The server spawns `tmux attach -t <name>` in a pty and resizes on window resize. Multiple viewers can attach at once. Closing the tab detaches; it never kills.
- **Stop.** Confirm, then `tmux kill-session`. The sidecar stays, marked ended.
- **Open terminal** (Overview, System) creates a `shell` session.
- **After a reboot.** tmux sessions don't survive a reboot. The UI lists their sidecars as *ended*, with a Remove button.
- **tmux environment.** All of agent's sessions share one tmux server, and whichever process starts that server first (the web service, an SSH login or the console) sets its global environment. Sessions created later inherit it; `bash -l` still loads the login profile, so PATH and API keys are current.

### Desktops
- **Grid.** One card per running desktop:
  - a thumbnail refreshed every 5 s (a PNG from `scrot`, scaled to 480 px wide);
  - idle time against the reaper's limit;
  - whether a viewer is attached. Only an open live view counts as a viewer: the thumbnails don't, so the reaper can still stop a desktop that is only shown in the grid. The page says so in a hint line.
- **New / Destroy.** Same semantics as the MCP tools: systemd `agentos-desktop@N`, max from `desktop.conf`. Destroy asks for confirmation.
- **Open.** An embedded noVNC view with a *View only* (default) / *Take control* toggle and full-screen.

### Settings
Forms for everything `agentos-config` does:
- API keys and OAuth token: write-only fields showing set / not set, plus a Clear button.
- Tailscale: status, auth-key entry, link to the ACL doc.
- SSH keys: list with fingerprints, add, remove, import from GitHub.
- LAN SSH, console mode, auto-reboot.
- Desktops: max, screenshot width, idle minutes.
- Web UI: `AGENTOS_WEB_USERS`. Removing your own login asks for confirmation.

Saving runs `agentos-config set …` then `apply`. Validation errors from agentos-config appear inline next to the field.

### System
- Service status for `agentos-*`, docker and tailscaled, with Restart.
- A live journal tail for the selected unit, over WebSocket.
- Updates: run `agentos-update` with live output, and show the last unattended-upgrades run time.
- Reboot and power off: confirm by typing the hostname.

## 4. Changes outside `web/`

- **`agentos-config`:**
  - new `remove-ssh-key FINGERPRINT` subcommand;
  - new key `AGENTOS_WEB_USERS` (validated as a comma-separated list of `[^,\s]+@[^,\s]+` logins), plus a menu item;
  - new key `AGENTOS_WEB` (`0|1`).
- **`agentos-firstboot`:** the tailscale serve step (section 1). It publishes `/etc/agentos/web.conf` (world-readable, root-written) with `USERS=` and `ENABLED=`, because the service runs as agent and `agentos.env` is root-only.
- **Image:**
  - build `web/` in the mkosi build step (`npm ci`, build, `npm prune --omit=dev`), installed to `/usr/local/lib/agentos/web`;
  - `node-pty` compiles against the image's Node;
  - add `agentos-web.service`;
  - size budget: +60–100 MB within the existing 7168 MiB.

## 5. Testing

- **Unit (vitest, `web/server`).** Runs in CI lint and locally.
  - auth: missing, unlisted and listed logins; case-insensitivity; not-configured mode; WebSocket upgrade checks;
  - CSRF: missing header, wrong Origin;
  - the actions table: exact argv for every action, unit allowlist, no shell;
  - session name and directory validation (traversal, symlinks out of `/home/agent`);
  - settings: secrets are never present in any response body.
- **UI.** Typecheck and build, plus component tests for the settings forms (write-only secret fields).
- **In-VM smoke checks** (`test/checks/96-web.sh`, existing harness):
  - service active and bound to `127.0.0.1:7070` only;
  - responses by identity header: 401 without, 403 for an unlisted login, 200 for an allowlisted one;
  - create a session via the API → the tmux session exists; the terminal WebSocket echoes typed input;
  - create a desktop via the API → the thumbnail is a PNG; destroy it;
  - set a non-secret setting → read it back; set a secret → it's never returned;
  - an audit line appears in the journal.
- **E2E.** Headless Playwright inside the VM (already installed), with the identity header injected through a request route. It loads every page, then runs New session → type in the terminal → see the output.
- **Not automated.** `tailscale serve` HTTPS needs a real tailnet. CI checks only the firstboot serve command logic; the real path is checked manually once.

## Out of scope (v1)

Multi-machine fleet view, headless prompt runs, a file browser or editor, user roles (every allowlisted login is admin), mobile-first design, in-UI image updates.
