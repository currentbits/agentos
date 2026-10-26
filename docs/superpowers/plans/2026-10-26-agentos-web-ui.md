# AgentOS Web UI Implementation Plan (Plan 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A browser UI, reachable only over the tailnet by allowlisted logins, to run and attach to agent sessions, watch and drive desktops, change every setting, and operate one AgentOS machine (health, services, logs, updates, power).

**Architecture:**
- **Server:** `agentos-web.service` runs a compiled TypeScript Fastify app (Node 24) as `agent` on `127.0.0.1:7070`. `tailscale serve` publishes it as `https://<host>.<tailnet>.ts.net` and adds the `Tailscale-User-Login` header.
- **Requests:** one `onRequest` hook checks the Host, the identity against `AGENTOS_WEB_USERS`, and CSRF (Origin plus `X-AgentOS: 1`) on every HTTP request and WebSocket upgrade.
- **Privilege:** every root action is `sudo -n` with argv from one fixed table (`actions.ts`). Values travel on stdin, never in argv.
- **State and streams:** state lives in systemd, tmux and `agentos-config`; there's no database. Terminals are node-pty running `tmux attach`. Desktops are proxied to websockify with the token added server-side.
- **UI:** a React + Vite SPA, built into the image at build time and served by the same process.

**Tech Stack:** Node 24 (NodeSource, already in the image), TypeScript 7.0.2, Fastify 5.12.7, @fastify/websocket 11.3.4, @fastify/static 10.1.7, ws 8.22.0, node-pty 1.1.0, vitest 5.0.5; React 19.3.1, Vite 8.3.5, @xterm/xterm 6.0.0, @xterm/addon-fit 0.11.0, jsdom 30.1.3, @testing-library/react 16.3.3; noVNC from the Debian `novnc` package; Playwright (already in the image) for e2e; mkosi 27, bash, systemd.

**Builds on:** `master` at ab6df50 **plus the `small-fixes` branch, which must be merged before Task 1.** The plan relies on what it adds:
- the idle reaper;
- `IDLE_MINUTES=` in `/etc/agentos/desktop.conf` and `AGENTOS_DESKTOP_IDLE_MINUTES` in `agentos-config`;
- `/run/agentos/desktops/N.last`;
- the post-small-fixes `agentos-config` menu text that Task 2 edits;

Before starting, rebase `web-ui` onto `master` (`git rebase master`), then check two things: `git log --oneline master | grep -q "idle desktop reaper"` succeeds, and `grep -q IDLE_MINUTES mkosi.extra/usr/local/sbin/agentos-firstboot` succeeds.

Read `.superpowers/sdd/context.md` for the build host workflow (devvm, `devvm.sh`, `TMPDIR=/var/tmp`, foreground polling). That scratch directory exists only in the main checkout `/Users/willem/Projects/AgentOS`, so implement from there, on branch `web-ui`.

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-10-26-agentos-web-ui-design.md`). When this plan and the spec disagree, the spec wins: stop and flag it. The deliberate refinements are listed under "Spec ambiguities resolved" below.

- Stack: Node 24 (already in image). Backend: TypeScript + Fastify. Frontend: React + Vite + TypeScript SPA
- Reachability: `tailscale serve` HTTPS on `https://<host>.<tailnet>.ts.net`; app binds `127.0.0.1:7070` only
- Authentication: Tailscale identity header (`Tailscale-User-Login`) checked against allowlist `AGENTOS_WEB_USERS`
- Agent sessions: Interactive tmux sessions running a CLI in a directory; attached via browser terminal
- State: No database: systemd, tmux, agentos-config, plus a small JSON sidecar per session
- Shipping: Built at image-build time; static UI + compiled server in `/usr/local/lib/agentos/web`
- `agentos-web.service`: runs Node 24 as user `agent`; listens on `127.0.0.1:7070` only; serves the compiled SPA and a JSON + WebSocket API.
- It's enabled by default. `AGENTOS_WEB=0` (in agentos.env, via agentos-config) disables both the service and the tailscale serve config.
- The service runs as `agent`. Root-requiring actions run through `sudo -n` with argv from the fixed table in `actions.ts`. Never a shell string, never user-supplied argv beyond validated parameters.
- Values are validated by `agentos-config` itself, so console and web behaviour are identical.
- Every HTTP request and every WebSocket upgrade must carry a login in `AGENTOS_WEB_USERS` (comma-separated, exact match, case-insensitive): missing header → 401; login not on the list → 403.
- When `AGENTOS_WEB_USERS` is empty, every request gets a static page: "You are `<login>`. Add yourself: `sudo agentos-config set AGENTOS_WEB_USERS <login>`". No API is reachable.
- Mutating requests (POST, PUT, DELETE) need the header `X-AgentOS: 1` and an `Origin` equal to the serve hostname. WebSocket upgrades check `Origin` the same way.
- The API never returns secret values. "Set / not set" comes from reading key names only. Secret values are sent only on write. They never appear in logs or the audit trail; the audit records the key name only.
- The browser connects to `/api/desktops/N/vnc` (same origin, authenticated). The server opens the websockify connection with the per-desktop token, so tokens never reach the browser. View-only is a noVNC client setting.
- Every mutating action writes a journal line, `agentos-web: <login> <action> <target>`, at notice level.
- Unit hardening: deliberately light, because the service must run sudo. `NoNewPrivileges` must stay off. `ProtectHome` is off, because sessions live in `/home/agent`. It keeps `PrivateTmp=no` (the tmux socket lives in `/tmp/tmux-1000`) and `Restart=on-failure`.
- The name is optional. Valid names match `[a-z0-9-]{1,32}`, unique; default `<cli>-<n>`. The server runs `tmux new-session -d -s ag-<name> -c <dir> -- bash -lc '<cli>'` as agent. The directory must resolve, via realpath, inside `/home/agent`.
- Closing the tab detaches; it never kills.
- Thumbnails: a PNG from `scrot`, scaled to 480 px wide, refreshed every 5 s. Overview: CPU, RAM, disk and load, polled every 5 s.
- `AGENTOS_WEB_USERS` validated as a comma-separated list of `[^,\s]+@[^,\s]+` logins; `AGENTOS_WEB` (`0|1`).
- `agentos-firstboot` publishes `/etc/agentos/web.conf` (world-readable, root-written) with `USERS=` and `ENABLED=`.
- Size budget: +60–100 MB within the existing 7168 MiB.
- Out of scope (v1): multi-machine fleet view, headless prompt runs, a file browser or editor, user roles (every allowlisted login is admin), mobile-first design, in-UI image updates.

Repo conventions:
- Bash scripts are `#!/bin/bash` with `set -euo pipefail`, and must be `shellcheck -S warning` clean.
- Checks in `test/checks/*.sh` use `&&` chains (don't rely on `set -e` inside check functions). Check names must be unique across all check files; `smoke.sh` runs them sorted by name, so every check sets up its own state.
- Smoke tests on devvm run with `TMPDIR=/var/tmp`.
- UI dependencies stay minimal: React only, no UI framework, no CSS framework, one stylesheet.
- Root used space ≤ 7168 MiB (`check_root_size_budget`).
- No CLI state in the image (finalize invariants stay green).

## Library versions (pinned exactly) and choices

All versions below were checked against the npm registry on 2026-10-26. While this plan was written, all the server and UI code in it was compiled and its tests were run: on macOS with Node 22.23, in a Linux `node:24` container (Node 24.22.1, real tmux), and end to end with Playwright 1.64.1 against the built UI.

| Package | Version | Where | Notes |
|---|---|---|---|
| fastify | 5.12.7 | server | `app.inject` for tests |
| @fastify/websocket | 11.3.4 | server | v11 handler signature `(socket: WebSocket, request)`. `onRequest`/`preValidation` hooks run before the upgrade, and a reply sent from them (401/403) refuses the upgrade. `app.injectWS()` for tests |
| @fastify/static | 10.1.7 | server | registered twice (`/novnc/` with `decorateReply: false`, then `/`); `reply.sendFile('index.html')` for the SPA fallback |
| ws | 8.22.0 | server | already a dependency of @fastify/websocket; listed directly because `vnc.ts` uses it as the websockify client and `test/web_ws.mjs` loads it in the VM |
| node-pty | 1.1.0 | server | `spawn(file, args, {name, cols, rows, cwd, env})`, `onData`, `onExit`, `write`, `resize`, `kill`. 1.1.0 ships no Linux prebuild, so `npm ci` compiles it with node-gyp against the image's Node 24 (build-essential and python3 are in the image). `allowScripts` in package.json keeps npm ≥ 11 from blocking that build |
| typescript | 7.0.2 | both | the native compiler; `tsc -p` emit and `--noEmit` verified for this code |
| vitest | 5.0.5 | both | needs Node ^22.12 or ^24 |
| @types/node | 24.19.2 | server | |
| @types/ws | 8.18.2 | server | |
| react, react-dom | 19.3.1 | ui | |
| @types/react, @types/react-dom | 19.3.0 | ui | |
| vite | 8.3.5 | ui | transforms TSX itself (`jsx: react-jsx` in tsconfig). **No `@vitejs/plugin-react`**: it only adds Fast Refresh, which we don't need |
| @xterm/xterm | 6.0.0 | ui | `new Terminal()`, `open`, `onData`, `onResize`, `write`, `dispose`; CSS at `@xterm/xterm/css/xterm.css` |
| @xterm/addon-fit | 0.11.0 | ui | `new FitAddon()`, `fit()` |
| jsdom | 30.1.3 | ui (test) | needs Node ^22.22.2 or ^24.15 |
| @testing-library/react | 16.3.3 | ui (test) | its peer @testing-library/dom is pinned to 10.4.2. `fireEvent` only: no user-event dependency |

Choices:
- **noVNC comes from the Debian `novnc` package, not npm `@novnc/novnc`.** It's already installed (it's what `agentos-novnc` serves). The server serves `/usr/share/novnc` at `/novnc/` behind the same auth. The UI loads `/novnc/core/rfb.js` at runtime with a dynamic `import()`, which Vite leaves alone (`/* @vite-ignore */`). Debian trixie's novnc 1.6 ships `core/rfb.js` as an ES module plus `vendor/pako`. This adds no npm dependency, and unattended-upgrades patches it. The cost is no compile-time types, so `DesktopView.tsx` declares the small subset of `RFB` it uses (`new RFB(target, url, {wsProtocols})`, `viewOnly`, `scaleViewport`, `disconnect()`, `connect`/`disconnect` events).
- **Playwright header injection uses `browser.newContext({ extraHTTPHeaders })`**, not `page.route`. `page.route` can't touch WebSocket handshakes. `extraHTTPHeaders` reaches both HTTP requests and the terminal WebSocket upgrade: verified with the server rejecting upgrades without the header.
- **The web build runs in `mkosi.prepare.chroot`**, in the final phase: it has network access, and `$SRCDIR` is the repo, mounted into the chroot. No new mkosi build-script machinery is needed. Only `dist/` plus production `node_modules` land in `/usr/local/lib/agentos/web` (measured at about 26 MiB).

## Spec ambiguities resolved

1. **Values go on stdin, not argv.** sudo logs every command line to the journal. So `agentos-config set KEY VALUE` from the web would log secrets, contradicting "never appear in logs". `agentos-config set KEY -` and `add-ssh-key -` now read the value from stdin. The web uses only those forms, and a check asserts that the journal never contains a test secret.
2. **The actions table also includes `agentos-config get KEY`**, to show current values. `get` already refuses secret keys. `TS_AUTHKEY` isn't matched by `is_secret_key`, so the server never reads it: it's write-only in the UI, which shows Tailscale's live status instead.
3. **Validation moves into `agentos-config`.** Until now, `agentos-config set` validated nothing: firstboot silently fell back to defaults. The spec says "Values are validated by agentos-config itself", so `validate_setting` (in `env.sh`, shared by `agentos-config` and firstboot) now validates every key the UI writes. Empty always means "default". The existing check that set `AGENTOS_SCREENSHOT_WIDTH 99999` through `agentos-config` now writes it straight into `agentos.env`, to keep testing firstboot's fallback.
4. **Clearing a secret.** `set SECRET ""` removes the key from `secrets.env`, rather than writing `KEY=`. That way "not set" is accurate, and the CLIs don't see an empty variable.
5. **Which Origin counts as the serve hostname.** It's `https://<Self.DNSName>` from `tailscale status --json` (cached for 60 s). `tailscale serve` preserves the Host header, which was checked against `ipn/ipnlocal/serve.go`. On-box clients (smoke checks, e2e) use `http://127.0.0.1:7070` or `http://localhost:7070`. The Host header itself is pinned to those three names on every request, which blocks DNS rebinding from a browser on the box.
6. **The not-configured page.** It returns HTTP 403, and its command also says `&& sudo agentos-config apply`, because `web.conf` is only republished on apply.
7. **"`/etc/issue` says why".** On a serve failure, firstboot writes `/run/issue.d/50-agentos-web.issue`, which agetty in util-linux 2.41 prints after `/etc/issue`. `web.conf` gains `SERVE=ok|off|tailscale-down|failed: <why>` for the Overview page.
8. **`tmux new-session … -- bash -lc '<cli>'`** is implemented as argv `['tmux','new-session','-d','-s','ag-<name>','-c',<dir>,'bash','-lc',<cli>]`, with no `--`: the trailing arguments are fixed words. A `shell` session runs `bash -l`.
9. **Session ids.** The session id in URLs is the tmux session name (`ag-<name>` for UI sessions; external sessions such as `main` keep their own name). It's always targeted as `-t =<id>` (exact match).
10. **`KillMode=process`.** A tmux server started by the web service lives in its cgroup, and `Restart=on-failure` (or `systemctl restart`) would otherwise kill every session. A smoke check restarts the service and expects the session to survive.
11. **No `apply` after SSH key changes.** `add`/`remove`/`github` key changes don't run `apply`: they take effect at once, and the console lockout check runs on the next apply or boot.
12. **Updates keep running if the tab closes.** `agentos-update` runs over a WebSocket and isn't killed when the socket closes, so apt is never interrupted. The journal tail is killed on close.
13. **The ACL doc link.** The repo has no public URL, so Settings names `docs/tailscale-acl.md` in the AgentOS repository and links Tailscale's tags documentation. `docs/tailscale-acl.md` gains port 443 and the HTTPS-certificates prerequisite.
14. **Desktop number race.** Desktop creation shares no lock with `agentos-computer`'s `create_desktop`. This is accepted, and marked with a `ponytail:` comment: two simultaneous creates can pick the same N.

## File map

```
web/server/package.json, package-lock.json, tsconfig.json
web/server/src/run.ts          HttpError, Runner, execRunner (execFile, argv only, optional stdin)
web/server/src/auth.ts         web.conf parsing, Host pinning, identity/allowlist, CSRF/Origin, not-configured page, onRequest hook
web/server/src/audit.ts        "<5><login> <action> <target>" journal lines
web/server/src/app.ts          Deps, buildApp(), static UI + /novnc/, SPA fallback, error handler
web/server/src/main.ts         listen on 127.0.0.1:7070
web/server/src/actions.ts      the fixed table: action -> exact argv (sudo -n where needed)
web/server/src/settings.ts     settings + SSH keys API (secrets write-only)
web/server/src/sessions.ts     tmux sessions + sidecars, directory validation, /api/dirs
web/server/src/terminal.ts     WebSocket <-> node-pty `tmux attach-session -t =<id>`
web/server/src/desktops.ts     desktop list/create/destroy/thumbnail
web/server/src/vnc.ts          WebSocket proxy to websockify with the token added server-side
web/server/src/system.ts       /api/me, health, tailscale, services, restart, journal + update streams, power
web/server/test/*.test.ts      vitest (helpers.ts: fake runner + header sets)
web/ui/package.json, package-lock.json, tsconfig.json, vite.config.ts, index.html
web/ui/src/{main.tsx,App.tsx,api.ts,router.tsx,usePoll.ts,types.ts,format.ts,quick.ts,style.css}
web/ui/src/pages/{Overview,Settings,Sessions,Terminal,Desktops,DesktopView,System}.tsx
web/ui/src/components/{Confirm.ts,ErrorText,SecretField,SettingsForm,SshKeys,NewSessionForm,DirPicker,Services,LogStream,Power}.tsx
web/ui/test/*.test.ts(x)       vitest + jsdom + Testing Library
mkosi.extra/usr/local/lib/agentos/env.sh          + validate_setting
mkosi.extra/usr/local/bin/agentos-config          + set KEY -, validation, clear secret, remove-ssh-key, add-ssh-key -, web UI menu item
mkosi.extra/usr/local/sbin/agentos-firstboot      + 5b: web.conf, web-serve, enable/disable, issue note
mkosi.extra/usr/local/lib/agentos/web-serve       tailscale serve on/off, prints SERVE status
mkosi.extra/etc/systemd/system/agentos-web.service
mkosi.prepare.chroot                              + build web/ into /usr/local/lib/agentos/web
mkosi.finalize.chroot                             + web manifest lines + build-output invariants
docs/tailscale-acl.md                             + port 443, HTTPS certificates
.gitignore                                        + web/*/node_modules/, web/*/dist/
.github/workflows/build.yml                       + tmux, setup-node 24, web unit tests, web-serve test, shellcheck list
test/env_test.sh                                  + validate_setting cases
test/web_serve_test.sh                            web-serve against a fake tailscale
test/web_ws.mjs                                   in-VM WebSocket probe (terminal echo, VNC banner)
test/web_e2e.mjs                                  in-VM Playwright e2e
test/checks/70-config.sh                          + validation, stdin, remove-ssh-key, web.conf checks
test/checks/91-desktop-lifecycle.sh               fallback check writes 99999 into agentos.env directly
test/checks/96-web.sh                             web service, API, terminal, desktops, settings, audit, e2e
```

## Working locally

- npm runs on the Mac, in `web/server` and `web/ui`, and needs Node ≥ 22.22: `~/.local/bin/node` is 22.23. The image build runs `npm ci` itself, on devvm.
- The live tmux terminal test in `web/server/test/terminal.test.ts` runs only on Linux (CI installs tmux). On macOS it's skipped: node-pty's darwin prebuild ships a `spawn-helper` without the exec bit. The in-VM smoke check covers that path too.
- Optional speed-up (scratch tooling, not committed): `devvm.sh` rsyncs the working tree, including `web/*/node_modules`. Add `--exclude node_modules` to `sync_tree` in `.superpowers/sdd/devvm.sh`. The image build excludes them anyway.

---

### Task 1: Server skeleton: auth, CSRF, not-configured mode, static UI

**Files:**
- Create: `web/server/package.json`, `web/server/package-lock.json` (generated), `web/server/tsconfig.json`
- Create: `web/server/src/run.ts`, `web/server/src/auth.ts`, `web/server/src/audit.ts`, `web/server/src/app.ts`, `web/server/src/main.ts`
- Test: `web/server/test/helpers.ts`, `web/server/test/run.test.ts`, `web/server/test/auth.test.ts`, `web/server/test/audit.test.ts`, `web/server/test/app.test.ts`
- Modify: `.gitignore` (append)

**Interfaces:**
- Consumes: nothing (first task).
- Produces (used by every later server task):
  - `run.ts`: `class HttpError(status: number, message: string, field?: string)`; `interface RunResult {code: number; stdout: string; stderr: string}`; `interface RunOpts {input?: string; timeoutMs?: number; env?: NodeJS.ProcessEnv; cwd?: string}`; `type Runner = (argv: readonly string[], opts?: RunOpts) => Promise<RunResult>`; `execRunner: Runner`.
  - `auth.ts`: `PORT = 7070`; `interface WebConf {users: string[]; enabled: boolean; serve: string}`; `parseWebConf(text)`, `readWebConf(path?)`, `parseTailnetName(statusJson): string | null`, `decide(facts, users, tsName): Verdict`, `authHook(conf, tsName)`; it declares `request.login: string`.
  - `audit.ts`: `type Audit = (login: string, action: string, target: string) => void`; `auditLine()`; `journalAudit`.
  - `app.ts`: `interface Deps {run: Runner; webConf: () => WebConf; tsName: () => Promise<string | null>; audit: Audit; home: string; uiRoot: string | null; novncRoot: string | null}`; `buildApp(deps): Promise<FastifyInstance>`; `defaultDeps()`; `cachedTailnetName(run)`. There are two marker comments, `// Route modules (one import per task):` and `// API routes (one line per task):`. Later tasks append their import and their `xxxRoutes(app, deps);` call under them.
  - Route modules export `xxxRoutes(app: FastifyInstance, deps: Deps): void`, and throw `HttpError` for client errors. The error handler maps it to `{error, field}` JSON with the status.
  - `test/helpers.ts`: `fakeDeps(reply?, over?) -> {deps, calls, audits}`; header sets `H` (identity plus Host) and `HM` (plus `Origin` and `X-AgentOS: 1`); `LOGIN = 'alice@example.com'`.

- [ ] **Step 1: Scaffold the package and install pinned dependencies**

`web/server/package.json`:
```json
{
  "name": "agentos-web-server",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run"
  },
  "dependencies": {
    "@fastify/static": "10.1.7",
    "@fastify/websocket": "11.3.4",
    "fastify": "5.12.7",
    "node-pty": "1.1.0",
    "ws": "8.22.0"
  },
  "devDependencies": {
    "@types/node": "24.19.2",
    "@types/ws": "8.18.2",
    "typescript": "7.0.2",
    "vitest": "5.0.5"
  },
  "allowScripts": {
    "node-pty@1.1.0": true
  }
}
```

`web/server/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "es2023",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "strict": true,
    "outDir": "dist",
    "rootDir": "src",
    "types": ["node"],
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

Append to `.gitignore`:
```
web/*/node_modules/
web/*/dist/
```

Run: `cd web/server && npm install`
Expected: it creates `package-lock.json` and ends with `found 0 vulnerabilities`. On macOS it doesn't compile node-pty (darwin prebuild); on Linux it does.

- [ ] **Step 2: Write the failing tests**

`web/server/test/helpers.ts`:
```ts
import { mkdtempSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { RunOpts, RunResult } from '../src/run.js';
import type { Deps } from '../src/app.js';
import { parseWebConf } from '../src/auth.js';

export const LOGIN = 'alice@example.com';
export const HOST = '127.0.0.1:7070';
export const ORIGIN = 'http://127.0.0.1:7070';
export const H = { host: HOST, 'tailscale-user-login': LOGIN };
export const HM = { ...H, origin: ORIGIN, 'x-agentos': '1' };   // headers for mutating requests

export interface Call { argv: string[]; opts?: RunOpts }

// A fake runner: records every call; `reply` maps argv to a result (default: success, no output).
export function fakeDeps(reply: (argv: string[], opts?: RunOpts) => Partial<RunResult> = () => ({}), over: Partial<Deps> = {}) {
  const calls: Call[] = [];
  const audits: string[] = [];
  const deps: Deps = {
    run: async (argv, opts) => {
      calls.push({ argv: [...argv], opts });
      return { code: 0, stdout: '', stderr: '', ...reply([...argv], opts) };
    },
    webConf: () => parseWebConf(`USERS=${LOGIN}\n`),
    tsName: async () => null,
    audit: (login, action, target) => audits.push(`${login} ${action} ${target}`),
    home: realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-home-'))),
    uiRoot: null,
    novncRoot: null,
    ...over,
  };
  return { deps, calls, audits };
}
```

`web/server/test/run.test.ts`:
```ts
import { expect, it } from 'vitest';
import { execRunner } from '../src/run.js';

it('runs argv without a shell', async () => {
  const r = await execRunner(['/bin/echo', '$(id)', ';', '|'], {});
  expect(r).toEqual({ code: 0, stdout: '$(id) ; |\n', stderr: '' });
  const s = await execRunner(['/bin/cat'], { input: 'secret-on-stdin' });
  expect(s.stdout).toBe('secret-on-stdin');
  const f = await execRunner(['/bin/sh', '-c', 'echo bad >&2; exit 3']);
  expect(f).toEqual({ code: 3, stdout: '', stderr: 'bad\n' });
});

it('survives a command that exits without reading its stdin', async () => {
  expect(await execRunner(['true'], { input: 'x'.repeat(1 << 20) })).toEqual({ code: 0, stdout: '', stderr: '' });
});
```

`web/server/test/auth.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { decide, notConfiguredPage, parseTailnetName, parseWebConf, type RequestFacts } from '../src/auth.js';

const TS = 'box.tail1234.ts.net';
const base: RequestFacts = { method: 'GET', host: TS, login: 'alice@example.com', origin: undefined, xAgentOS: undefined, upgrade: false };
const users = ['alice@example.com', 'bob@example.com'];
const post = { ...base, method: 'POST', origin: `https://${TS}`, xAgentOS: '1' };

describe('identity', () => {
  it('401 without the identity header', () => {
    expect(decide({ ...base, login: undefined }, users, TS)).toMatchObject({ ok: false, status: 401 });
    expect(decide({ ...base, login: '  ' }, users, TS)).toMatchObject({ ok: false, status: 401 });
  });
  it('403 for a login not on the list', () => {
    expect(decide({ ...base, login: 'mallory@example.com' }, users, TS)).toMatchObject({ ok: false, status: 403 });
  });
  it('accepts a listed login, case-insensitively', () => {
    expect(decide({ ...base, login: 'Alice@Example.COM' }, users, TS)).toEqual({ ok: true, login: 'alice@example.com' });
    expect(decide(base, parseWebConf('USERS=Alice@Example.com\n').users, TS)).toEqual({ ok: true, login: 'alice@example.com' });
  });
  it('not-configured mode: every request gets the static page, no API', () => {
    const v = decide({ ...base, login: 'carol@example.com' }, [], TS);
    expect(v).toMatchObject({ ok: false, status: 403, html: true });
    expect(v.ok === false && v.body).toContain('sudo agentos-config set AGENTOS_WEB_USERS carol@example.com');
  });
  it('escapes the login in the not-configured page', () => {
    expect(notConfiguredPage('<script>@x')).not.toContain('<script>');
  });
});

describe('host pinning', () => {
  it('accepts the tailnet name and loopback, rejects anything else', () => {
    expect(decide({ ...base, host: '127.0.0.1:7070' }, users, null).ok).toBe(true);
    expect(decide({ ...base, host: 'localhost:7070' }, users, null).ok).toBe(true);
    expect(decide({ ...base, host: 'evil.example:7070' }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide({ ...base, host: undefined }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide(base, users, null)).toMatchObject({ ok: false, status: 403 });
  });
});

describe('CSRF', () => {
  it('accepts a same-origin mutating request with X-AgentOS: 1', () => {
    for (const method of ['POST', 'PUT', 'DELETE']) expect(decide({ ...post, method }, users, TS).ok).toBe(true);
    expect(decide({ ...post, host: '127.0.0.1:7070', origin: 'http://127.0.0.1:7070' }, users, TS).ok).toBe(true);
  });
  it('rejects a missing X-AgentOS header', () => {
    expect(decide({ ...post, xAgentOS: undefined }, users, TS)).toMatchObject({ ok: false, status: 403, body: 'missing X-AgentOS header' });
    expect(decide({ ...post, xAgentOS: 'true' }, users, TS)).toMatchObject({ ok: false, status: 403 });
  });
  it('rejects a wrong or missing Origin', () => {
    expect(decide({ ...post, origin: 'https://evil.example' }, users, TS)).toMatchObject({ ok: false, body: 'bad origin' });
    expect(decide({ ...post, origin: `http://${TS}` }, users, TS)).toMatchObject({ ok: false, body: 'bad origin' });
    expect(decide({ ...post, origin: undefined }, users, TS)).toMatchObject({ ok: false, body: 'bad origin' });
  });
  it('checks Origin on WebSocket upgrades, without needing X-AgentOS', () => {
    const ws = { ...base, upgrade: true };
    expect(decide({ ...ws, origin: `https://${TS}` }, users, TS).ok).toBe(true);
    expect(decide({ ...ws, origin: 'https://evil.example' }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide({ ...ws, origin: undefined }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide({ ...ws, login: undefined, origin: `https://${TS}` }, users, TS)).toMatchObject({ ok: false, status: 401 });
  });
  it('GET needs no Origin', () => {
    expect(decide(base, users, TS).ok).toBe(true);
  });
});

describe('config parsing', () => {
  it('parses web.conf', () => {
    expect(parseWebConf('USERS=a@x.com, B@y.org\nENABLED=1\nSERVE=ok\n')).toEqual({ users: ['a@x.com', 'b@y.org'], enabled: true, serve: 'ok' });
    expect(parseWebConf('')).toEqual({ users: [], enabled: true, serve: '' });
    expect(parseWebConf('ENABLED=0\n').enabled).toBe(false);
  });
  it('parses the tailnet name', () => {
    expect(parseTailnetName('{"Self":{"DNSName":"box.tail1234.ts.net."}}')).toBe('box.tail1234.ts.net');
    expect(parseTailnetName('{"Self":{"DNSName":""}}')).toBeNull();
    expect(parseTailnetName('not json')).toBeNull();
  });
});
```

`web/server/test/audit.test.ts`:
```ts
import { expect, it } from 'vitest';
import { auditLine } from '../src/audit.js';

it('formats one notice-level line, with fields that cannot break the line', () => {
  expect(auditLine('alice@example.com', 'config-set', 'AGENTOS_LAN_SSH')).toBe('<5>alice@example.com config-set AGENTOS_LAN_SSH');
  expect(auditLine('a@b', 'session-create', 'x\ny z')).toBe('<5>a@b session-create x_y_z');
  expect(auditLine('a@b', 'reboot', '')).toBe('<5>a@b reboot -');
});
```

`web/server/test/app.test.ts`:
```ts
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { parseWebConf } from '../src/auth.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

// /api/nope has no route: an authorized request reaches the 404 handler, a rejected one never does.
describe('HTTP auth through the app', () => {
  it('401 without identity, 403 unlisted, through to routing when listed', async () => {
    const app = await buildApp(fakeDeps().deps);
    expect((await app.inject({ url: '/api/nope', headers: { host: H.host } })).statusCode).toBe(401);
    expect((await app.inject({ url: '/api/nope', headers: { ...H, 'tailscale-user-login': 'eve@example.com' } })).statusCode).toBe(403);
    expect((await app.inject({ url: '/api/nope', headers: H })).statusCode).toBe(404);
  });

  it('not-configured mode serves only the static page', async () => {
    const app = await buildApp(fakeDeps(() => ({}), { webConf: () => parseWebConf('') }).deps);
    for (const url of ['/', '/api/settings', '/api/sessions']) {
      const r = await app.inject({ url, headers: H });
      expect(r.statusCode).toBe(403);
      expect(r.headers['content-type']).toMatch(/text\/html/);
      expect(r.body).toContain(`sudo agentos-config set AGENTOS_WEB_USERS ${LOGIN}`);
    }
  });

  it('mutating requests need X-AgentOS and a matching Origin', async () => {
    const app = await buildApp(fakeDeps().deps);
    const post = (headers: Record<string, string>) => app.inject({ method: 'POST', url: '/api/nope', headers, payload: {} });
    expect((await post({ ...H, origin: HM.origin })).statusCode).toBe(403);
    expect((await post({ ...HM, origin: 'https://evil.example' })).statusCode).toBe(403);
    expect((await post(HM)).statusCode).toBe(404);
  });

  it('serves the UI and noVNC behind auth, with an SPA fallback and JSON 404 under /api', async () => {
    const ui = mkdtempSync(join(tmpdir(), 'ui-'));
    mkdirSync(join(ui, 'assets'));
    writeFileSync(join(ui, 'index.html'), '<div id="root"></div>');
    writeFileSync(join(ui, 'assets', 'a.js'), 'x');
    const novnc = mkdtempSync(join(tmpdir(), 'novnc-'));
    mkdirSync(join(novnc, 'core'));
    writeFileSync(join(novnc, 'core', 'rfb.js'), 'export default class RFB {}');
    const app = await buildApp(fakeDeps(() => ({}), { uiRoot: ui, novncRoot: novnc }).deps);
    const rfb = await app.inject({ url: '/novnc/core/rfb.js', headers: H });
    expect(rfb.body).toContain('class RFB');
    expect(rfb.headers['content-type']).toMatch(/javascript/);
    expect((await app.inject({ url: '/novnc/core/rfb.js', headers: { host: H.host } })).statusCode).toBe(401);
    expect((await app.inject({ url: '/', headers: H })).body).toContain('root');
    expect((await app.inject({ url: '/sessions/ag-x', headers: H })).body).toContain('root');
    expect((await app.inject({ url: '/assets/a.js', headers: H })).body).toBe('x');
    const api404 = await app.inject({ url: '/api/nope', headers: H });
    expect(api404.statusCode).toBe(404);
    expect(api404.json()).toEqual({ error: 'not found' });
    expect((await app.inject({ url: '/', headers: { host: H.host } })).statusCode).toBe(401);
  });
});

describe('WebSocket upgrades', () => {
  it('reject a missing identity, an unlisted login and a missing or bad Origin', async () => {
    const app = await buildApp(fakeDeps().deps);
    await app.ready();
    const url = '/api/nope';
    await expect(app.injectWS(url, { headers: { host: H.host, origin: HM.origin } })).rejects.toThrow(/401/);
    await expect(app.injectWS(url, { headers: { ...H, 'tailscale-user-login': 'eve@example.com', origin: HM.origin } })).rejects.toThrow(/403/);
    await expect(app.injectWS(url, { headers: { ...H, origin: 'https://evil.example' } })).rejects.toThrow(/403/);
    await expect(app.injectWS(url, { headers: H })).rejects.toThrow(/403/);
    await expect(app.injectWS(url, { headers: { ...H, origin: HM.origin } })).rejects.toThrow(/404/);
  });
});
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `cd web/server && npx vitest run`
Expected: `Test Files  4 failed (4)`, each with `Error: Cannot find module '../src/....js'`.

- [ ] **Step 4: Implement**

`web/server/src/run.ts`:
```ts
// Running commands: argv only (execFile, no shell), with an optional stdin. Every exec in the
// server goes through a Runner so tests can substitute a fake one.
import { execFile } from 'node:child_process';

export class HttpError extends Error {
  constructor(public status: number, message: string, public field?: string) { super(message); }
}

export interface RunResult { code: number; stdout: string; stderr: string }
export interface RunOpts { input?: string; timeoutMs?: number; env?: NodeJS.ProcessEnv; cwd?: string }
export type Runner = (argv: readonly string[], opts?: RunOpts) => Promise<RunResult>;

export const execRunner: Runner = (args, opts = {}) =>
  new Promise((resolve) => {
    const child = execFile(args[0], args.slice(1), {
      timeout: opts.timeoutMs ?? 30_000, maxBuffer: 16 * 1024 * 1024,
      env: opts.env ?? process.env, cwd: opts.cwd, encoding: 'utf8',
    }, (err, stdout, stderr) => {
      const code = err ? (typeof err.code === 'number' ? err.code : 1) : 0;
      resolve({ code, stdout, stderr: err && !stderr ? err.message : stderr });
    });
    child.stdin?.on('error', () => {});   // EPIPE when the command exits without reading stdin
    child.stdin?.end(opts.input ?? '');
  });
```

`web/server/src/auth.ts`:
```ts
// Identity (Tailscale-User-Login vs the allowlist), Host pinning, and CSRF/Origin checks.
// One onRequest hook covers every HTTP request and every WebSocket upgrade.
import { readFileSync } from 'node:fs';
import type { FastifyReply, FastifyRequest } from 'fastify';

export const PORT = 7070;
export const LOOPBACK_HOSTS = [`127.0.0.1:${PORT}`, `localhost:${PORT}`];

export interface WebConf { users: string[]; enabled: boolean; serve: string }

export function parseWebConf(text: string): WebConf {
  const get = (k: string) => text.match(new RegExp(`^${k}=(.*)$`, 'm'))?.[1].trim() ?? '';
  return {
    users: get('USERS').split(',').map((u) => u.trim().toLowerCase()).filter(Boolean),
    enabled: get('ENABLED') !== '0',
    serve: get('SERVE'),
  };
}

export function readWebConf(path = '/etc/agentos/web.conf'): WebConf {
  try {
    return parseWebConf(readFileSync(path, 'utf8'));
  } catch {
    return parseWebConf('');
  }
}

// Host must be the tailnet name (via tailscale serve) or loopback; this blocks DNS rebinding.
export function hostAllowed(host: string | undefined, tsName: string | null): boolean {
  return !!host && (host === tsName || LOOPBACK_HOSTS.includes(host));
}

export function expectedOrigin(host: string, tsName: string | null): string {
  return host === tsName ? `https://${host}` : `http://${host}`;
}

export type Verdict =
  | { ok: true; login: string }
  | { ok: false; status: number; body: string; html?: boolean };

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function notConfiguredPage(login: string): string {
  const l = escapeHtml(login);
  return `<!doctype html><meta charset="utf-8"><title>AgentOS</title>
<body style="font-family:sans-serif;background:#111;color:#eee;padding:2em">
<p>You are <code>${l}</code>.</p>
<p>Add yourself: <code>sudo agentos-config set AGENTOS_WEB_USERS ${l} &amp;&amp; sudo agentos-config apply</code></p>
</body>`;
}

export interface RequestFacts {
  method: string;
  host: string | undefined;
  login: string | undefined;
  origin: string | undefined;
  xAgentOS: string | undefined;
  upgrade: boolean;
}

export function decide(f: RequestFacts, users: string[], tsName: string | null): Verdict {
  if (!hostAllowed(f.host, tsName)) return { ok: false, status: 403, body: 'bad host' };
  const login = f.login?.trim().toLowerCase();
  if (!login) return { ok: false, status: 401, body: 'no Tailscale identity' };
  if (users.length === 0) return { ok: false, status: 403, body: notConfiguredPage(login), html: true };
  if (!users.includes(login)) return { ok: false, status: 403, body: `${login} is not allowed` };
  const mutating = ['POST', 'PUT', 'DELETE', 'PATCH'].includes(f.method);
  if (mutating || f.upgrade) {
    if (f.origin !== expectedOrigin(f.host!, tsName)) return { ok: false, status: 403, body: 'bad origin' };
    if (mutating && f.xAgentOS !== '1') return { ok: false, status: 403, body: 'missing X-AgentOS header' };
  }
  return { ok: true, login };
}

const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

declare module 'fastify' {
  interface FastifyRequest { login: string }
}

export function authHook(conf: () => WebConf, tsName: () => Promise<string | null>) {
  return async (req: FastifyRequest, reply: FastifyReply) => {
    const v = decide({
      method: req.method,
      host: one(req.headers.host),
      login: one(req.headers['tailscale-user-login']),
      origin: one(req.headers.origin),
      xAgentOS: one(req.headers['x-agentos']),
      upgrade: one(req.headers.upgrade)?.toLowerCase() === 'websocket',
    }, conf().users, await tsName());
    if (v.ok) {
      req.login = v.login;
      return;
    }
    return reply.code(v.status).type(v.html ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8').send(v.body);
  };
}

// Tailnet DNS name (Self.DNSName, trailing dot stripped) from `tailscale status --json`.
export function parseTailnetName(statusJson: string): string | null {
  try {
    const name: unknown = JSON.parse(statusJson)?.Self?.DNSName;
    return typeof name === 'string' && name ? name.replace(/\.$/, '') : null;
  } catch {
    return null;
  }
}
```

`web/server/src/audit.ts`:
```ts
// Audit trail: one journal line per mutating action, at notice level. The "<5>" prefix is
// journald's syslog-priority marker for stdout; the unit's SyslogIdentifier=agentos-web supplies
// the tag, so the journal shows "agentos-web[pid]: <login> <action> <target>".
const field = (s: string) => s.replace(/[\s\x00-\x1f\x7f]+/g, '_') || '-';

export function auditLine(login: string, action: string, target: string): string {
  return `<5>${field(login)} ${field(action)} ${field(target)}`;
}

export type Audit = (login: string, action: string, target: string) => void;

export const journalAudit: Audit = (login, action, target) => {
  process.stdout.write(auditLine(login, action, target) + '\n');
};
```

`web/server/src/app.ts` (Task 1 state: no route modules yet):
```ts
// Fastify app: the auth hook first, then the API, then the static UI with an SPA fallback.
import { existsSync } from 'node:fs';
import fastifyStatic from '@fastify/static';
import fastifyWebsocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import { type Audit, journalAudit } from './audit.js';
import { authHook, parseTailnetName, readWebConf, type WebConf } from './auth.js';
import { execRunner, HttpError, type Runner } from './run.js';
// Route modules (one import per task):

export interface Deps {
  run: Runner;
  webConf: () => WebConf;
  tsName: () => Promise<string | null>;
  audit: Audit;
  home: string;
  uiRoot: string | null;
  novncRoot: string | null;
}

export function cachedTailnetName(run: Runner, ttlMs = 60_000): () => Promise<string | null> {
  let value: string | null = null;
  let at = 0;
  return async () => {
    if (Date.now() - at > ttlMs) {
      value = parseTailnetName((await run(['tailscale', 'status', '--json'], { timeoutMs: 5000 })).stdout);
      at = Date.now();
    }
    return value;
  };
}

export function defaultDeps(): Deps {
  return {
    run: execRunner,
    webConf: () => readWebConf(),
    tsName: cachedTailnetName(execRunner),
    audit: journalAudit,
    home: '/home/agent',
    uiRoot: '/usr/local/lib/agentos/web/ui',
    novncRoot: '/usr/share/novnc',
  };
}

export async function buildApp(deps: Deps): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: 'warn' }, bodyLimit: 1024 * 1024 });
  app.decorateRequest('login', '');
  app.addHook('onRequest', authHook(deps.webConf, deps.tsName));
  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof HttpError) return reply.code(err.status).send({ error: err.message, field: err.field });
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) app.log.error(err);
    return reply.code(status).send({ error: status >= 500 ? 'internal error' : (err as Error).message });
  });
  await app.register(fastifyWebsocket, { options: { maxPayload: 4 * 1024 * 1024 } });

  // API routes (one line per task):

  if (deps.novncRoot && existsSync(deps.novncRoot)) {
    await app.register(fastifyStatic, { root: deps.novncRoot, prefix: '/novnc/', decorateReply: false });
  }
  if (deps.uiRoot && existsSync(deps.uiRoot)) {
    await app.register(fastifyStatic, { root: deps.uiRoot, prefix: '/' });
    app.setNotFoundHandler((req, reply) =>
      req.url.startsWith('/api/') ? reply.code(404).send({ error: 'not found' }) : reply.sendFile('index.html'));
  }
  return app;
}
```

`web/server/src/main.ts`:
```ts
import { buildApp, defaultDeps } from './app.js';
import { PORT } from './auth.js';

const app = await buildApp(defaultDeps());
await app.listen({ host: '127.0.0.1', port: PORT });
```

- [ ] **Step 5: Run tests, typecheck and build**

Run: `cd web/server && npx vitest run && npm run typecheck && npm run build && ls dist`
Expected: `Test Files  4 passed (4)` and `Tests  21 passed (21)`, then a clean typecheck, then `app.js audit.js auth.js main.js run.js`.

Manual sanity check (any OS): `node dist/main.js &`, then:
- `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7070/` prints `401`;
- `curl -s -H 'Tailscale-User-Login: a@b.c' http://127.0.0.1:7070/` prints the "You are `a@b.c`" page.

Then `kill %1`.

- [ ] **Step 6: Commit**

```bash
git add .gitignore web/server
git commit -m "feat(web): server skeleton with Tailscale identity auth, CSRF/Origin checks and not-configured mode"
```

---

### Task 2: Actions table, settings API, and `agentos-config` / firstboot support

**Files:**
- Create: `web/server/src/actions.ts`, `web/server/src/settings.ts`
- Test: `web/server/test/actions.test.ts`, `web/server/test/settings.test.ts`
- Modify: `web/server/src/app.ts` (register `settingsRoutes`)
- Modify: `mkosi.extra/usr/local/lib/agentos/env.sh` (append `validate_setting`)
- Modify: `mkosi.extra/usr/local/bin/agentos-config`:
  - `set KEY -` reads stdin, validates, and an empty secret clears it;
  - `add-ssh-key -`;
  - `remove-ssh-key FINGERPRINT`;
  - the menu gets `menu_set` and a `webui` item.
- Modify: `mkosi.extra/usr/local/sbin/agentos-firstboot` (new step 5b, `web.conf`)
- Modify: `test/env_test.sh` (append), `test/checks/70-config.sh` (append), `test/checks/91-desktop-lifecycle.sh` (one line)

**Interfaces:**
- Consumes: Task 1's `HttpError`, `Runner`, `RunOpts`, `RunResult` (run.ts); `Deps`, `buildApp` (app.ts); `fakeDeps`, `H`, `HM`, `LOGIN` (test/helpers.ts).
- Produces:
  - `actions.ts`:
    - `type Action` (the table) and `argv(a: Action): string[]`, which throws `HttpError(400, 'invalid …')`;
    - `runAction(run, a, opts?)`;
    - the regexes `KEY_RE`, `UNIT_RE` (`^(agentos-[a-z0-9@-]+|docker|tailscaled)\.service$`), `FINGERPRINT_RE`, `GITHUB_USER_RE`, `DESKTOP_RE` (`^([1-9]|1[0-6])$`).
  - `settings.ts`: `settingsRoutes`; `SECRET_KEYS`, `PLAIN_KEYS`, `WRITE_ONLY_KEYS`; `secretNames()`; `parseFingerprints()`.
  - API:
    - `GET /api/settings` → `{values: Record<key,string>, secrets: Record<key,boolean>}`;
    - `PUT /api/settings {values}` → `{ok:true}`, or 400 `{error, field}`, or 502 on an apply failure;
    - `GET /api/ssh-keys` → `[{bits, fingerprint, comment, type}]`;
    - `POST /api/ssh-keys {key}`, `POST /api/ssh-keys/github {user}`, `POST /api/ssh-keys/remove {fingerprint}`.
  - Shell:
    - `validate_setting KEY VALUE` in env.sh (returns 2 with a reason on stderr);
    - `agentos-config set KEY -`, `add-ssh-key -` and `remove-ssh-key SHA256:…`;
    - `/etc/agentos/web.conf` (`USERS=`, `ENABLED=`; Task 9 adds `SERVE=`).

- [ ] **Step 1: Write the failing server tests**

`web/server/test/actions.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { argv } from '../src/actions.js';

const C = '/usr/local/bin/agentos-config';
const FP = 'SHA256:' + 'A'.repeat(43);

describe('actions table', () => {
  it('builds the exact argv for every action', () => {
    expect(argv({ name: 'config-set', key: 'AGENTOS_LAN_SSH' })).toEqual(['sudo', '-n', C, 'set', 'AGENTOS_LAN_SSH', '-']);
    expect(argv({ name: 'config-get', key: 'AGENTOS_WEB' })).toEqual(['sudo', '-n', C, 'get', 'AGENTOS_WEB']);
    expect(argv({ name: 'config-apply' })).toEqual(['sudo', '-n', C, 'apply']);
    expect(argv({ name: 'add-ssh-key' })).toEqual(['sudo', '-n', C, 'add-ssh-key', '-']);
    expect(argv({ name: 'remove-ssh-key', fingerprint: FP })).toEqual(['sudo', '-n', C, 'remove-ssh-key', FP]);
    expect(argv({ name: 'github-keys', user: 'octo-cat' })).toEqual(['sudo', '-n', C, 'github-keys', 'octo-cat']);
    expect(argv({ name: 'restart', unit: 'agentos-novnc.service' })).toEqual(['sudo', '-n', 'systemctl', 'restart', 'agentos-novnc.service']);
    expect(argv({ name: 'journal', unit: 'docker.service' })).toEqual(['sudo', '-n', 'journalctl', '-u', 'docker.service', '-f', '-n', '200', '-o', 'short-iso']);
    expect(argv({ name: 'update' })).toEqual(['/usr/local/bin/agentos-update']);
    expect(argv({ name: 'reboot' })).toEqual(['sudo', '-n', 'systemctl', 'reboot']);
    expect(argv({ name: 'poweroff' })).toEqual(['sudo', '-n', 'systemctl', 'poweroff']);
    expect(argv({ name: 'desktop-start', n: 3 })).toEqual(['systemctl', '--no-ask-password', 'start', 'agentos-desktop@3.service']);
    expect(argv({ name: 'desktop-stop', n: 16 })).toEqual(['systemctl', '--no-ask-password', 'stop', 'agentos-desktop@16.service']);
  });

  it('restricts units to agentos-*, docker and tailscaled', () => {
    for (const unit of ['agentos-web.service', 'agentos-desktop@2.service', 'docker.service', 'tailscaled.service']) {
      expect(() => argv({ name: 'restart', unit })).not.toThrow();
    }
    for (const unit of ['ssh.service', 'docker', 'agentos-x.timer', '-H.service', 'agentos-a;b.service', '../docker.service', 'Docker.service']) {
      expect(() => argv({ name: 'restart', unit })).toThrow(/invalid unit/);
      expect(() => argv({ name: 'journal', unit })).toThrow(/invalid unit/);
    }
  });

  it('rejects bad keys, fingerprints, users and desktop numbers', () => {
    expect(() => argv({ name: 'config-set', key: 'lower' })).toThrow();
    expect(() => argv({ name: 'config-set', key: '-x' })).toThrow();
    expect(() => argv({ name: 'remove-ssh-key', fingerprint: 'MD5:aa' })).toThrow();
    expect(() => argv({ name: 'github-keys', user: '--help' + 'x'.repeat(40) })).toThrow();
    expect(() => argv({ name: 'github-keys', user: 'a b' })).toThrow();
    expect(() => argv({ name: 'desktop-start', n: 0 })).toThrow();
    expect(() => argv({ name: 'desktop-start', n: 17 })).toThrow();
  });

  it('never puts a value in argv: config-set takes it on stdin', () => {
    expect(argv({ name: 'config-set', key: 'ANTHROPIC_API_KEY' }).join(' ')).not.toMatch(/sk-/);
  });
});
```

`web/server/test/settings.test.ts`:
```ts
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { parseFingerprints, secretNames } from '../src/settings.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const SECRET = 'sk-ant-SUPERSECRET-123==';

function withSecrets() {
  const f = fakeDeps((argv) => (argv[3] === 'get' ? { stdout: argv[4] === 'AGENTOS_MAX_DESKTOPS' ? '4\n' : '' } : {}));
  mkdirSync(join(f.deps.home, '.config/agentos'), { recursive: true });
  writeFileSync(join(f.deps.home, '.config/agentos/secrets.env'), `ANTHROPIC_API_KEY=${SECRET}\nOPENAI_API_KEY=\nPAD_TOKEN=abc==\n`);
  return f;
}

describe('settings', () => {
  it('reads key names only', () => {
    expect([...secretNames(`A_API_KEY=${SECRET}\nB_TOKEN=\nC_TOKEN=x`)]).toEqual(['A_API_KEY', 'C_TOKEN']);
  });

  it('GET returns plain values and set/not-set for secrets, never a secret value', async () => {
    const { deps } = withSecrets();
    const app = await buildApp(deps);
    const r = await app.inject({ url: '/api/settings', headers: H });
    expect(r.statusCode).toBe(200);
    expect(r.body).not.toContain(SECRET);
    expect(r.body).not.toContain('SUPERSECRET');
    expect(r.json().values.AGENTOS_MAX_DESKTOPS).toBe('4');
    expect(r.json().secrets).toEqual({ ANTHROPIC_API_KEY: true, OPENAI_API_KEY: false, GROK_CODE_XAI_API_KEY: false, CLAUDE_CODE_OAUTH_TOKEN: false });
  });

  it('PUT sends values on stdin (never argv), applies, audits key names only, and echoes nothing', async () => {
    const { deps, calls, audits } = withSecrets();
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values: { ANTHROPIC_API_KEY: SECRET, AGENTOS_LAN_SSH: '1' } } });
    expect(r.statusCode).toBe(200);
    expect(r.body).not.toContain(SECRET);
    expect(calls.map((c) => c.argv.join(' ')).join('\n')).not.toContain(SECRET);
    expect(calls.find((c) => c.argv[4] === 'ANTHROPIC_API_KEY')!.opts?.input).toBe(SECRET);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', '/usr/local/bin/agentos-config', 'apply']);
    expect(audits).toEqual([`${LOGIN} config-set ANTHROPIC_API_KEY`, `${LOGIN} config-set AGENTOS_LAN_SSH`, `${LOGIN} config-apply -`]);
    expect(audits.join('\n')).not.toContain(SECRET);
  });

  it('maps an agentos-config validation error to the field, and skips apply', async () => {
    const { deps, calls } = fakeDeps((argv) => (argv[4] === 'AGENTOS_MAX_DESKTOPS' ? { code: 2, stderr: 'AGENTOS_MAX_DESKTOPS must be 1-16\n' } : {}));
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values: { AGENTOS_MAX_DESKTOPS: '99' } } });
    expect(r.statusCode).toBe(400);
    expect(r.json()).toEqual({ error: 'AGENTOS_MAX_DESKTOPS must be 1-16', field: 'AGENTOS_MAX_DESKTOPS' });
    expect(calls.some((c) => c.argv.includes('apply'))).toBe(false);
  });

  it('rejects unknown keys and multi-line values before running anything', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    const put = (values: object) => app.inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values } });
    expect((await put({ PATH: '/x' })).json()).toMatchObject({ field: 'PATH' });
    expect((await put({ AGENTOS_WEB: '1\nX=2' })).statusCode).toBe(400);
    expect(calls).toEqual([]);
  });
});

describe('ssh keys', () => {
  it('parses ssh-keygen -l output', () => {
    const fp = 'SHA256:' + 'b'.repeat(43);
    expect(parseFingerprints(`256 ${fp} me@laptop (ED25519)\n3072 ${fp} no comment (RSA)\n`)).toEqual([
      { bits: '256', fingerprint: fp, comment: 'me@laptop', type: 'ED25519' },
      { bits: '3072', fingerprint: fp, comment: 'no comment', type: 'RSA' },
    ]);
  });
  it('adds a key via stdin and removes by fingerprint', async () => {
    const { deps, calls, audits } = fakeDeps();
    const app = await buildApp(deps);
    const key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake me@x';
    expect((await app.inject({ method: 'POST', url: '/api/ssh-keys', headers: HM, payload: { key } })).statusCode).toBe(200);
    expect(calls.at(-1)).toMatchObject({ argv: ['sudo', '-n', '/usr/local/bin/agentos-config', 'add-ssh-key', '-'], opts: { input: key } });
    const fp = 'SHA256:' + 'c'.repeat(43);
    expect((await app.inject({ method: 'POST', url: '/api/ssh-keys/remove', headers: HM, payload: { fingerprint: fp } })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', '/usr/local/bin/agentos-config', 'remove-ssh-key', fp]);
    expect((await app.inject({ method: 'POST', url: '/api/ssh-keys/remove', headers: HM, payload: { fingerprint: '; rm -rf /' } })).statusCode).toBe(400);
    expect(audits).toEqual([`${LOGIN} ssh-key-add -`, `${LOGIN} ssh-key-remove ${fp}`]);
  });
});
```

- [ ] **Step 2: Write the failing shell tests**

Append to `test/env_test.sh`:
```bash

# validate_setting: the values agentos-config accepts (empty = default, always accepted)
ok()  { validate_setting "$1" "$2" || { echo "should accept $1='$2'" >&2; exit 1; }; }
bad() { if validate_setting "$1" "$2" 2>/dev/null; then echo "should reject $1='$2'" >&2; exit 1; fi; }
ok AGENTOS_LAN_SSH 1; ok AGENTOS_LAN_SSH 0; ok AGENTOS_LAN_SSH ''; bad AGENTOS_LAN_SSH yes; bad AGENTOS_WEB 2
ok AGENTOS_CONSOLE terminal; bad AGENTOS_CONSOLE gui
ok AGENTOS_MAX_DESKTOPS 16; bad AGENTOS_MAX_DESKTOPS 17; bad AGENTOS_MAX_DESKTOPS 0; bad AGENTOS_MAX_DESKTOPS 08
ok AGENTOS_SCREENSHOT_WIDTH 640; ok AGENTOS_SCREENSHOT_WIDTH 1920; bad AGENTOS_SCREENSHOT_WIDTH 639; bad AGENTOS_SCREENSHOT_WIDTH 1921
ok AGENTOS_DESKTOP_IDLE_MINUTES 0; ok AGENTOS_DESKTOP_IDLE_MINUTES 999999; bad AGENTOS_DESKTOP_IDLE_MINUTES 1000000; bad AGENTOS_DESKTOP_IDLE_MINUTES -1
ok AGENTOS_WEB_USERS a@b.com; ok AGENTOS_WEB_USERS 'a@b.com,C@github'; bad AGENTOS_WEB_USERS 'a@b.com, c@d'; bad AGENTOS_WEB_USERS nobody
bad AGENTOS_WEB_USERS 'a@b,'; bad AGENTOS_WEB_USERS $'a@b\nc@d'
ok SOME_OTHER_KEY anything
[ "$(validate_setting AGENTOS_WEB x 2>&1)" = "AGENTOS_WEB must be 0 or 1" ]
echo "validate_setting OK"
```

Append to `test/checks/70-config.sh`:
```bash
check_config_rejects_invalid_values() {
  vm 'b=$(sudo agentos-config get AGENTOS_MAX_DESKTOPS)
      e=$(sudo agentos-config set AGENTOS_MAX_DESKTOPS 99 2>&1); rc=$?
      test "$rc" = 2 && test "$e" = "AGENTOS_MAX_DESKTOPS must be a number from 1 to 16" &&
      test "$(sudo agentos-config get AGENTOS_MAX_DESKTOPS)" = "$b" &&
      ! sudo agentos-config set AGENTOS_WEB_USERS not-a-login 2>/dev/null &&
      ! sudo agentos-config set AGENTOS_WEB 2 2>/dev/null &&
      ! sudo agentos-config set AGENTOS_CONSOLE gui 2>/dev/null'
}
check_config_secret_from_stdin_and_clear() {
  # "-" reads the value from stdin, so it never appears in sudo's journal line; "" clears a secret.
  vm 'printf %s sk-stdin-9 | sudo agentos-config set STDIN_TEST_API_KEY - &&
      grep -qx STDIN_TEST_API_KEY=sk-stdin-9 ~/.config/agentos/secrets.env &&
      ! sudo journalctl -b --no-pager | grep -q sk-stdin-9 &&
      sudo agentos-config set STDIN_TEST_API_KEY "" &&
      ! grep -q "^STDIN_TEST_API_KEY=" ~/.config/agentos/secrets.env'
}
check_remove_ssh_key() {
  vm 'd=$(mktemp -d) && ssh-keygen -q -t ed25519 -N "" -C rm-test -f "$d/k" &&
      fp=$(ssh-keygen -lf "$d/k.pub" | cut -d" " -f2) && n=$(grep -c . ~/.ssh/authorized_keys) &&
      sudo agentos-config add-ssh-key - < "$d/k.pub" && grep -q rm-test ~/.ssh/authorized_keys &&
      sudo agentos-config remove-ssh-key "$fp" && ! grep -q rm-test ~/.ssh/authorized_keys &&
      test "$(grep -c . ~/.ssh/authorized_keys)" = "$n" &&
      test "$(stat -c "%U %a" ~/.ssh/authorized_keys)" = "agent 600" &&
      ! sudo agentos-config remove-ssh-key "$fp" 2>/dev/null &&
      ! sudo agentos-config remove-ssh-key SHA256:bad 2>/dev/null; rc=$?; rm -rf "$d"; exit $rc'
}
check_web_conf_follows_config() {
  local rc=0
  vm 'sudo agentos-config set AGENTOS_WEB_USERS "A@example.com,b@example.org" && sudo agentos-config apply &&
      grep -qx "USERS=A@example.com,b@example.org" /etc/agentos/web.conf && grep -qx ENABLED=1 /etc/agentos/web.conf &&
      test "$(stat -c "%U %a" /etc/agentos/web.conf)" = "root 644" &&
      echo "AGENTOS_WEB_USERS=not a login" | sudo tee -a /etc/agentos/agentos.env >/dev/null &&
      sudo agentos-config apply && grep -qx "USERS=" /etc/agentos/web.conf' || rc=1
  vm 'sudo agentos-config set AGENTOS_WEB_USERS "" && sudo agentos-config apply' || rc=1
  return "$rc"
}
```

In `test/checks/91-desktop-lifecycle.sh`, `check_desktop_conf_follows_config`, replace:
```bash
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 3 && sudo agentos-config set AGENTOS_SCREENSHOT_WIDTH 99999 &&
```
with:
```bash
  # agentos-config now rejects 99999 (check_config_rejects_invalid_values), but a hand-written
  # agentos.env (cloud user-data) can still hold it, and firstboot must fall back to the default.
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 3 && echo AGENTOS_SCREENSHOT_WIDTH=99999 | sudo tee -a /etc/agentos/agentos.env >/dev/null &&
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `cd web/server && npx vitest run test/actions.test.ts test/settings.test.ts`
Expected: both files fail with `Cannot find module '../src/actions.js'` (and `'../src/settings.js'`).

Run: `.superpowers/sdd/devvm.sh sh 'test/env_test.sh'`
Expected: `env.sh OK` and `profile.d OK`, then a failure with `validate_setting: command not found`.

- [ ] **Step 4: Implement the actions table and settings API**

`web/server/src/actions.ts`:
```ts
// The fixed table of every privileged or mutating command the web UI can run. Argv only, never a
// shell string; parameters are validated here before they reach an argv.
import { HttpError, type RunOpts, type Runner, type RunResult } from './run.js';

export const CONFIG = '/usr/local/bin/agentos-config';
export const KEY_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
export const UNIT_RE = /^(agentos-[a-z0-9@-]+|docker|tailscaled)\.service$/;
export const FINGERPRINT_RE = /^SHA256:[A-Za-z0-9+/]{43}$/;
export const GITHUB_USER_RE = /^[A-Za-z0-9-]{1,39}$/;
export const DESKTOP_RE = /^([1-9]|1[0-6])$/;

export type Action =
  | { name: 'config-set'; key: string }            // value goes on stdin, never in argv (sudo logs argv)
  | { name: 'config-get'; key: string }
  | { name: 'config-apply' }
  | { name: 'add-ssh-key' }                          // key on stdin
  | { name: 'remove-ssh-key'; fingerprint: string }
  | { name: 'github-keys'; user: string }
  | { name: 'restart'; unit: string }
  | { name: 'journal'; unit: string }
  | { name: 'update' }
  | { name: 'reboot' }
  | { name: 'poweroff' }
  | { name: 'desktop-start'; n: number }
  | { name: 'desktop-stop'; n: number };

function need(ok: boolean, what: string): void {
  if (!ok) throw new HttpError(400, `invalid ${what}`);
}

export function argv(a: Action): string[] {
  const sudo = ['sudo', '-n'];
  switch (a.name) {
    case 'config-set': need(KEY_RE.test(a.key), 'key'); return [...sudo, CONFIG, 'set', a.key, '-'];
    case 'config-get': need(KEY_RE.test(a.key), 'key'); return [...sudo, CONFIG, 'get', a.key];
    case 'config-apply': return [...sudo, CONFIG, 'apply'];
    case 'add-ssh-key': return [...sudo, CONFIG, 'add-ssh-key', '-'];
    case 'remove-ssh-key': need(FINGERPRINT_RE.test(a.fingerprint), 'fingerprint'); return [...sudo, CONFIG, 'remove-ssh-key', a.fingerprint];
    case 'github-keys': need(GITHUB_USER_RE.test(a.user), 'GitHub user'); return [...sudo, CONFIG, 'github-keys', a.user];
    case 'restart': need(UNIT_RE.test(a.unit), 'unit'); return [...sudo, 'systemctl', 'restart', a.unit];
    case 'journal': need(UNIT_RE.test(a.unit), 'unit'); return [...sudo, 'journalctl', '-u', a.unit, '-f', '-n', '200', '-o', 'short-iso'];
    case 'update': return ['/usr/local/bin/agentos-update'];
    case 'reboot': return [...sudo, 'systemctl', 'reboot'];
    case 'poweroff': return [...sudo, 'systemctl', 'poweroff'];
    case 'desktop-start': need(DESKTOP_RE.test(String(a.n)), 'desktop'); return ['systemctl', '--no-ask-password', 'start', `agentos-desktop@${a.n}.service`];
    case 'desktop-stop': need(DESKTOP_RE.test(String(a.n)), 'desktop'); return ['systemctl', '--no-ask-password', 'stop', `agentos-desktop@${a.n}.service`];
  }
}

export async function runAction(run: Runner, a: Action, opts?: RunOpts): Promise<RunResult> {
  return run(argv(a), opts);
}
```

`web/server/src/settings.ts`:
```ts
// Settings via agentos-config. Secret values are write-only: responses carry only "set / not set",
// derived from the key names in secrets.env; values go to agentos-config on stdin, never in argv.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';

export const SECRET_KEYS = ['ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GROK_CODE_XAI_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'];
// TS_AUTHKEY is write-only too, and its state can't be read (agentos.env is root-only and
// firstboot deletes it once used): the UI shows Tailscale's own status instead.
export const WRITE_ONLY_KEYS = [...SECRET_KEYS, 'TS_AUTHKEY'];
export const PLAIN_KEYS = ['AGENTOS_LAN_SSH', 'AGENTOS_CONSOLE', 'AGENTOS_AUTO_REBOOT', 'AGENTOS_MAX_DESKTOPS',
  'AGENTOS_SCREENSHOT_WIDTH', 'AGENTOS_DESKTOP_IDLE_MINUTES', 'AGENTOS_WEB_USERS', 'AGENTOS_WEB'];

export interface SettingsView { values: Record<string, string>; secrets: Record<string, boolean> }

// Names only: the regex captures the key and never looks past "=".
export function secretNames(secretsEnv: string): Set<string> {
  return new Set([...secretsEnv.matchAll(/^([A-Z0-9_]+)=./gm)].map((m) => m[1]));
}

export async function getSettings(deps: Deps): Promise<SettingsView> {
  const values: Record<string, string> = {};
  for (const key of PLAIN_KEYS) {
    const r = await runAction(deps.run, { name: 'config-get', key });
    values[key] = r.code === 0 ? r.stdout.trim() : '';
  }
  let text = '';
  try { text = await readFile(join(deps.home, '.config/agentos/secrets.env'), 'utf8'); } catch { /* none yet */ }
  const names = secretNames(text);
  return { values, secrets: Object.fromEntries(SECRET_KEYS.map((k) => [k, names.has(k)])) };
}

export async function saveSettings(deps: Deps, values: Record<string, unknown>, login: string): Promise<void> {
  const entries = Object.entries(values ?? {});
  if (entries.length === 0) throw new HttpError(400, 'nothing to save');
  for (const [key, value] of entries) {
    if (![...PLAIN_KEYS, ...WRITE_ONLY_KEYS].includes(key)) throw new HttpError(400, `unknown setting ${key}`, key);
    if (typeof value !== 'string' || /[\r\n]/.test(value)) throw new HttpError(400, 'value must be a single line', key);
  }
  for (const [key, value] of entries) {
    const r = await runAction(deps.run, { name: 'config-set', key }, { input: value as string });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim() || 'rejected', key);
    deps.audit(login, 'config-set', key);
  }
  const r = await runAction(deps.run, { name: 'config-apply' }, { timeoutMs: 300_000 });
  deps.audit(login, 'config-apply', '-');
  if (r.code !== 0) throw new HttpError(502, 'saved, but applying failed: see journalctl -u agentos-firstboot');
}

export interface SshKey { bits: string; fingerprint: string; comment: string; type: string }

export function parseFingerprints(out: string): SshKey[] {
  return out.split('\n').flatMap((line) => {
    const m = line.match(/^(\d+) (SHA256:[A-Za-z0-9+/]{43}) (.*) \(([A-Z0-9-]+)\)$/);
    return m ? [{ bits: m[1], fingerprint: m[2], comment: m[3], type: m[4] }] : [];
  });
}

export function settingsRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/settings', async () => getSettings(deps));
  app.put<{ Body: { values?: Record<string, unknown> } }>('/api/settings', async (req) => {
    await saveSettings(deps, req.body?.values ?? {}, req.login);
    return { ok: true };
  });
  app.get('/api/ssh-keys', async () => {
    const r = await deps.run(['ssh-keygen', '-l', '-f', join(deps.home, '.ssh/authorized_keys')]);
    return r.code === 0 ? parseFingerprints(r.stdout) : [];
  });
  app.post<{ Body: { key?: string } }>('/api/ssh-keys', async (req) => {
    const r = await runAction(deps.run, { name: 'add-ssh-key' }, { input: String(req.body?.key ?? '').trim() });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim());
    deps.audit(req.login, 'ssh-key-add', '-');
    return { ok: true };
  });
  app.post<{ Body: { user?: string } }>('/api/ssh-keys/github', async (req) => {
    const user = String(req.body?.user ?? '');
    const r = await runAction(deps.run, { name: 'github-keys', user });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim());
    deps.audit(req.login, 'ssh-key-github', user);
    return { ok: true };
  });
  app.post<{ Body: { fingerprint?: string } }>('/api/ssh-keys/remove', async (req) => {
    const fingerprint = String(req.body?.fingerprint ?? '');
    const r = await runAction(deps.run, { name: 'remove-ssh-key', fingerprint });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim());
    deps.audit(req.login, 'ssh-key-remove', fingerprint);
    return { ok: true };
  });
}
```

In `web/server/src/app.ts`, add this line under `// Route modules (one import per task):`:
```ts
import { settingsRoutes } from './settings.js';
```
and this line under `// API routes (one line per task):`:
```ts
  settingsRoutes(app, deps);
```

- [ ] **Step 5: Implement the shell side**

Append to `mkosi.extra/usr/local/lib/agentos/env.sh`:
```bash
# validate_setting KEY VALUE: 0 if VALUE is acceptable for KEY, else print why to stderr and
# return 2. Empty means "use the default" and is always accepted; unknown keys are not checked.
# Shared by agentos-config (rejects on set) and agentos-firstboot (falls back to the default).
validate_setting() {
  local re want
  [ -z "$2" ] && return 0
  case $1 in
    AGENTOS_LAN_SSH|AGENTOS_AUTO_REBOOT|AGENTOS_WEB) re='^[01]$'; want='0 or 1' ;;
    AGENTOS_CONSOLE)              re='^(headless|terminal)$'; want='headless or terminal' ;;
    AGENTOS_MAX_DESKTOPS)         re='^([1-9]|1[0-6])$'; want='a number from 1 to 16' ;;
    AGENTOS_SCREENSHOT_WIDTH)     re='^(6[4-9][0-9]|[7-9][0-9]{2}|1[0-8][0-9]{2}|19[01][0-9]|1920)$'; want='a number from 640 to 1920' ;;
    AGENTOS_DESKTOP_IDLE_MINUTES) re='^(0|[1-9][0-9]{0,5})$'; want='a number of minutes from 0 to 999999' ;;
    AGENTOS_WEB_USERS)            re='^[^,[:space:]]+@[^,[:space:]]+(,[^,[:space:]]+@[^,[:space:]]+)*$'; want='a comma-separated list of tailnet logins (you@example.com)' ;;
    *) return 0 ;;
  esac
  [[ $2 =~ $re ]] || { echo "$1 must be $want" >&2; return 2; }
}
```

In `mkosi.extra/usr/local/bin/agentos-config`, make these replacements (exact text, post-small-fixes):

(a) `cmd_set`. Replace:
```bash
cmd_set() {
  if is_secret_key "$1"; then
    install -d -o agent -g agent -m 700 /home/agent/.config/agentos
    env_set "$AGENTOS_SECRETS" "$1" "$2"; chown agent:agent "$AGENTOS_SECRETS"; chmod 600 "$AGENTOS_SECRETS"
  else
    env_set "$AGENTOS_ENV" "$1" "$2"
  fi
}
```

with:
```bash
# VALUE "-" means "read it from stdin": the web UI passes values that way because sudo logs its
# argv to the journal, and a secret must never land there. An empty secret value clears it.
cmd_set() {
  local v=$2
  if [ "$v" = - ]; then IFS= read -r v || true; fi
  validate_setting "$1" "$v" || exit 2
  if is_secret_key "$1"; then
    install -d -o agent -g agent -m 700 /home/agent/.config/agentos
    if [ -n "$v" ]; then env_set "$AGENTOS_SECRETS" "$1" "$v"; else env_unset "$AGENTOS_SECRETS" "$1"; fi
    if [ -f "$AGENTOS_SECRETS" ]; then chown agent:agent "$AGENTOS_SECRETS"; chmod 600 "$AGENTOS_SECRETS"; fi
  else
    env_set "$AGENTOS_ENV" "$1" "$v"
  fi
}
```

(b) Add `cmd_remove_ssh_key` above `cmd_github_keys`. Replace:
```bash
cmd_github_keys() {
```

with:
```bash
# Remove every authorized_keys line whose key has this fingerprint (as `ssh-keygen -l` prints it).
cmd_remove_ssh_key() {
  [[ $1 =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || { echo "not a SHA256 key fingerprint: $1" >&2; exit 2; }
  local tmp line fp found=0
  tmp=$(mktemp "$AK.XXXXXX")
  while IFS= read -r line || [ -n "$line" ]; do
    fp=$(ssh-keygen -l -f - <<< "$line" 2>/dev/null | awk '{print $2}') || true
    if [ "$fp" = "$1" ]; then found=1; else printf '%s\n' "$line" >> "$tmp"; fi
  done < <(cat "$AK" 2>/dev/null)
  if [ "$found" = 0 ]; then rm -f "$tmp"; echo "no SSH key with fingerprint $1" >&2; exit 1; fi
  chown agent:agent "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$AK"
}
cmd_github_keys() {
```

(c) Add `menu_set` above `menu()`. Replace:
```bash
menu() {
  while true; do
```

with:
```bash
# cmd_set exits on an invalid value: run it in a subshell so the menu survives and says why.
menu_set() { local err; err=$( (cmd_set "$1" "$2") 2>&1) || whiptail --msgbox "$1 not saved: $err" 10 72; }

menu() {
  while true; do
```

(d) Add the web UI menu entry. Replace:
```bash
      reboot    "Auto-reboot for kernel security updates" \
```

with:
```bash
      reboot    "Auto-reboot for kernel security updates" \
      webui     "Web UI: tailnet logins allowed to use it" \
```

(e) The desktops entry uses `menu_set`, because `cmd_set` can now exit on a bad value. Replace:
```bash
      desktops)  m=$(whiptail --inputbox "Max concurrent desktops (1-16)" 10 60 "$(cmd_get AGENTOS_MAX_DESKTOPS || true)" 3>&1 1>&2 2>&3) && [ -n "$m" ] && cmd_set AGENTOS_MAX_DESKTOPS "$m" || true
                 w=$(whiptail --inputbox "Screenshot width in px (640-1920, default 1366)" 10 60 "$(cmd_get AGENTOS_SCREENSHOT_WIDTH || true)" 3>&1 1>&2 2>&3) && [ -n "$w" ] && cmd_set AGENTOS_SCREENSHOT_WIDTH "$w" || true
                 i=$(whiptail --inputbox "Stop an idle, unwatched desktop after this many minutes (0 = never, default 120)" 10 60 "$(cmd_get AGENTOS_DESKTOP_IDLE_MINUTES || true)" 3>&1 1>&2 2>&3) && [ -n "$i" ] && cmd_set AGENTOS_DESKTOP_IDLE_MINUTES "$i" || true ;;
```

with:
```bash
      desktops)  m=$(whiptail --inputbox "Max concurrent desktops (1-16)" 10 60 "$(cmd_get AGENTOS_MAX_DESKTOPS || true)" 3>&1 1>&2 2>&3) && [ -n "$m" ] && menu_set AGENTOS_MAX_DESKTOPS "$m" || true
                 w=$(whiptail --inputbox "Screenshot width in px (640-1920, default 1366)" 10 60 "$(cmd_get AGENTOS_SCREENSHOT_WIDTH || true)" 3>&1 1>&2 2>&3) && [ -n "$w" ] && menu_set AGENTOS_SCREENSHOT_WIDTH "$w" || true
                 i=$(whiptail --inputbox "Stop an idle, unwatched desktop after this many minutes (0 = never, default 120)" 10 60 "$(cmd_get AGENTOS_DESKTOP_IDLE_MINUTES || true)" 3>&1 1>&2 2>&3) && [ -n "$i" ] && menu_set AGENTOS_DESKTOP_IDLE_MINUTES "$i" || true ;;
```

(f) The `webui` handler, inserted above `mcptoken)`. Replace:
```bash
      mcptoken)  whiptail
```

with:
```bash
      webui)     u=$(whiptail --inputbox "Tailnet logins allowed to use the web UI, comma-separated (you@example.com). Empty = nobody." 10 72 "$(cmd_get AGENTOS_WEB_USERS || true)" 3>&1 1>&2 2>&3) && menu_set AGENTOS_WEB_USERS "$u" || true ;;
      mcptoken)  whiptail
```

(g) Dispatch. Replace:
```bash
  add-ssh-key)     cmd_add_ssh_key "${2:?usage: agentos-config add-ssh-key '<pubkey>'}" ;;
```

with:
```bash
  add-ssh-key)     k=${2:?usage: agentos-config add-ssh-key KEY (or - to read it from stdin)}
                   if [ "$k" = - ]; then IFS= read -r k || true; fi
                   cmd_add_ssh_key "$k" ;;
  remove-ssh-key)  cmd_remove_ssh_key "${2:?usage: agentos-config remove-ssh-key SHA256:...}" ;;
```

(h) Usage line. Replace:
```bash
  *)               echo "usage: agentos-config [set KEY VALUE|get KEY|add-ssh-key KEY|github-keys USER|password|apply|show-mcp-token]" >&2; exit 2 ;;
```

with:
```bash
  *)               echo "usage: agentos-config [set KEY VALUE|-|get KEY|add-ssh-key KEY|-|remove-ssh-key FINGERPRINT|github-keys USER|password|apply|show-mcp-token]" >&2; exit 2 ;;
```

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, add step 5b above step 6. Replace:
```bash
# 6. Console lockout prevention last
```

with:
```bash
# 5b. Web UI settings for agentos-web (runs as agent; agentos.env is root-only). Invalid -> default.
wu=$(env_get "$AGENTOS_ENV" AGENTOS_WEB_USERS)
validate_setting AGENTOS_WEB_USERS "$wu" 2>/dev/null || wu=
we=$(env_get "$AGENTOS_ENV" AGENTOS_WEB | grep -x 0 || echo 1)
printf 'USERS=%s\nENABLED=%s\n' "$wu" "$we" > /etc/agentos/web.conf.tmp
chmod 644 /etc/agentos/web.conf.tmp
mv /etc/agentos/web.conf.tmp /etc/agentos/web.conf

# 6. Console lockout prevention last
```

- [ ] **Step 6: Run the unit tests**

Run: `cd web/server && npx vitest run && npm run typecheck`
Expected: `Test Files  6 passed (6)` and `Tests  32 passed (32)`, then a clean typecheck.

Run: `.superpowers/sdd/devvm.sh sh 'test/env_test.sh && shellcheck -S warning test/env_test.sh test/checks/70-config.sh test/checks/91-desktop-lifecycle.sh mkosi.extra/usr/local/bin/agentos-config mkosi.extra/usr/local/sbin/agentos-firstboot mkosi.extra/usr/local/lib/agentos/env.sh'`
Expected: `env.sh OK`, `profile.d OK`, `validate_setting OK`, and no shellcheck output.

- [ ] **Step 7: Run the in-VM checks**

```bash
.superpowers/sdd/devvm.sh run 'mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi'
.superpowers/sdd/devvm.sh wait <JOB>   # repeat until the exit code is not 124
```
Expected: these PASS: `check_config_rejects_invalid_values`, `check_config_secret_from_stdin_and_clear`, `check_remove_ssh_key`, `check_web_conf_follows_config`, `check_desktop_conf_follows_config`. Every older check still passes, and the run ends with `ALL CHECKS PASSED`.

- [ ] **Step 8: Commit**

```bash
git add web/server mkosi.extra/usr/local/lib/agentos/env.sh mkosi.extra/usr/local/bin/agentos-config \
  mkosi.extra/usr/local/sbin/agentos-firstboot test/env_test.sh test/checks/70-config.sh test/checks/91-desktop-lifecycle.sh
git commit -m "feat(web): actions table and settings API; agentos-config validates values, reads them from stdin, removes SSH keys; firstboot publishes web.conf"
```

---

### Task 3: Sessions API and the terminal WebSocket

**Files:**
- Create: `web/server/src/sessions.ts`, `web/server/src/terminal.ts`
- Test: `web/server/test/sessions.test.ts`, `web/server/test/terminal.test.ts`
- Modify: `web/server/src/app.ts` (register `sessionRoutes`, `terminalRoutes`)

**Interfaces:**
- Consumes: `HttpError` (run.ts), `Deps` (app.ts), `fakeDeps`/`H`/`HM`/`LOGIN` (helpers), `execRunner` (in the live test).
- Produces:
  - `sessions.ts`:
    - `NAME_RE`, `CLIS`, `REPO_RE`, `TMUX_FORMAT` (`'#{session_name}:#{session_created}:#{session_attached}'`);
    - `parseTmuxList()`, `resolveDir(dir, home)`, `tmuxNewArgv(name, dir, cli)`, `defaultName()`;
    - `tmuxSessions(deps): Promise<{id, created, attached}[]>`, also used by `terminal.ts`;
    - `listSessions`, `createSession`, `stopSession`, `removeSession`, `listDirs`, `sessionRoutes`.
  - Session JSON: `{id, name, cli, dir, created, attached, state: 'running'|'ended', external}`.
  - Sidecar `~/.config/agentos/sessions/<name>.json`: `{cli, dir, created, createdBy, ended?}`.
  - API:
    - `GET /api/sessions`;
    - `POST /api/sessions {cli, dir?, repo?, name?}` → 201 with the session;
    - `POST /api/sessions/:id/stop`;
    - `DELETE /api/sessions/:id` (ended sessions only, else 409);
    - `GET /api/dirs?path=` → `{path, parent, dirs}`.
  - `terminal.ts`: `parseClientMsg()`, `attachArgv(id)`, `terminalRoutes`.
  - WebSocket `/api/sessions/:id/terminal?cols=&rows=`:
    - client frames are JSON, `{"t":"i","d":keys}` or `{"t":"r","c":cols,"r":rows}`;
    - server frames are raw terminal output (text);
    - closing the socket kills only the tmux client.

Two traps this code handles, both found while writing the plan:
- tmux escapes a tab in `-F` output (tmux 3.3 prints `_`), so the fields are `:`-separated: tmux never allows `:` in a session name.
- node-pty passes an `env` value of `undefined` on as the string `"undefined"`. A `TMUX=undefined` makes `tmux attach` talk to a socket that doesn't exist, so the code deletes `TMUX` instead.

- [ ] **Step 1: Write the failing tests**

`web/server/test/sessions.test.ts`:
```ts
import { mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { defaultName, NAME_RE, parseTmuxList, resolveDir, tmuxNewArgv } from '../src/sessions.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

describe('session names', () => {
  it('accepts [a-z0-9-]{1,32} only', () => {
    for (const ok of ['a', 'claude-1', 'x'.repeat(32), '0-0']) expect(NAME_RE.test(ok)).toBe(true);
    for (const bad of ['', 'x'.repeat(33), 'A', 'a_b', 'a.b', 'a b', '../x', 'a;b', '-'.repeat(33)]) expect(NAME_RE.test(bad)).toBe(false);
  });
  it('picks the lowest free default name', () => {
    expect(defaultName('codex', new Set())).toBe('codex-1');
    expect(defaultName('codex', new Set(['codex-1', 'codex-3']))).toBe('codex-2');
  });
  it('builds tmux argv with a login shell and no shell string', () => {
    expect(tmuxNewArgv('w', '/home/agent/p', 'claude')).toEqual(['tmux', 'new-session', '-d', '-s', 'ag-w', '-c', '/home/agent/p', 'bash', '-lc', 'claude']);
    expect(tmuxNewArgv('s', '/home/agent', 'shell')).toEqual(['tmux', 'new-session', '-d', '-s', 'ag-s', '-c', '/home/agent', 'bash', '-l']);
    expect(() => tmuxNewArgv('Bad', '/home/agent', 'shell')).toThrow();
  });
  it('parses tmux list-sessions output', () => {
    expect(parseTmuxList('main:1761480000:1\nag-x:1761480060:0\ngarbage\n')).toEqual([
      { id: 'main', created: '2025-10-26T12:00:00.000Z', attached: 1 },
      { id: 'ag-x', created: '2025-10-26T12:01:00.000Z', attached: 0 },
    ]);
  });
});

describe('directory validation', () => {
  it('allows home and folders inside it', async () => {
    const { deps } = fakeDeps();
    mkdirSync(join(deps.home, 'proj'));
    expect(await resolveDir(deps.home, deps.home)).toBe(deps.home);
    expect(await resolveDir(join(deps.home, 'proj'), deps.home)).toBe(join(deps.home, 'proj'));
  });
  it('rejects traversal, symlinks out of home, siblings with a common prefix, files and missing paths', async () => {
    const { deps } = fakeDeps();
    symlinkSync('/etc', join(deps.home, 'etc-link'));
    mkdirSync(deps.home + '-evil', { recursive: true });
    writeFileSync(join(deps.home, 'file'), '');
    await expect(resolveDir(join(deps.home, '..'), deps.home)).rejects.toThrow(/inside/);
    await expect(resolveDir(join(deps.home, 'etc-link'), deps.home)).rejects.toThrow(/inside/);
    await expect(resolveDir(deps.home + '-evil', deps.home)).rejects.toThrow(/inside/);
    await expect(resolveDir(join(deps.home, 'file'), deps.home)).rejects.toThrow(/not a directory/);
    await expect(resolveDir(join(deps.home, 'nope'), deps.home)).rejects.toThrow(/no such/);
  });
});

describe('sessions API', () => {
  it('creates a session: tmux argv, sidecar, audit', async () => {
    const { deps, calls, audits } = fakeDeps();
    mkdirSync(join(deps.home, 'p'));
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'POST', url: '/api/sessions', headers: HM, payload: { cli: 'codex', dir: join(deps.home, 'p') } });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toMatchObject({ id: 'ag-codex-1', name: 'codex-1', state: 'running' });
    expect(calls.at(-1)!.argv).toEqual(['tmux', 'new-session', '-d', '-s', 'ag-codex-1', '-c', join(deps.home, 'p'), 'bash', '-lc', 'codex']);
    const sidecar = JSON.parse(readFileSync(join(deps.home, '.config/agentos/sessions/codex-1.json'), 'utf8'));
    expect(sidecar).toMatchObject({ cli: 'codex', dir: join(deps.home, 'p'), createdBy: LOGIN });
    expect(audits).toEqual([`${LOGIN} session-create ag-codex-1`]);
  });

  it('rejects a bad cli, a bad name, a directory outside home and a bad repo URL', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    const post = (payload: object) => app.inject({ method: 'POST', url: '/api/sessions', headers: HM, payload });
    expect((await post({ cli: 'rm -rf /' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', name: 'Bad Name' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', dir: '/etc' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', repo: '--upload-pack=touch /tmp/x' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', repo: 'file:///etc' })).statusCode).toBe(400);
    expect(calls.filter((c) => c.argv[0] !== 'tmux' || c.argv[1] !== 'list-sessions')).toEqual([]);
  });

  it('clones a repo into ~/work/<name> with prompts disabled', async () => {
    const { deps, calls } = fakeDeps((argv) => {
      if (argv[0] === 'git') mkdirSync(argv[4], { recursive: true });
      return {};
    });
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'POST', url: '/api/sessions', headers: HM, payload: { cli: 'claude', name: 'demo', repo: 'https://github.com/o/r.git' } });
    expect(r.statusCode).toBe(201);
    const git = calls.find((c) => c.argv[0] === 'git')!;
    expect(git.argv).toEqual(['git', 'clone', '--', 'https://github.com/o/r.git', join(deps.home, 'work/demo')]);
    expect(git.opts?.env?.GIT_TERMINAL_PROMPT).toBe('0');
  });

  it('lists running, external and ended sessions', async () => {
    const { deps } = fakeDeps((argv) => (argv[1] === 'list-sessions' ? { stdout: 'main:1761480000:1\nag-a:1761480000:0\n' } : {}));
    mkdirSync(join(deps.home, '.config/agentos/sessions'), { recursive: true });
    for (const n of ['a', 'b']) {
      writeFileSync(join(deps.home, `.config/agentos/sessions/${n}.json`), JSON.stringify({ cli: 'shell', dir: deps.home, created: 'c', createdBy: LOGIN }));
    }
    const app = await buildApp(deps);
    const list = (await app.inject({ url: '/api/sessions', headers: H })).json();
    expect(list.map((s: { id: string; state: string; external: boolean }) => [s.id, s.state, s.external])).toEqual([
      ['ag-a', 'running', false], ['ag-b', 'ended', false], ['main', 'running', true],
    ]);
  });

  it('stops only a live session, by exact name, and removes only ended ones', async () => {
    const { deps, calls } = fakeDeps((argv) => (argv[1] === 'list-sessions' ? { stdout: 'ag-a:1761480000:0\n' } : {}));
    mkdirSync(join(deps.home, '.config/agentos/sessions'), { recursive: true });
    writeFileSync(join(deps.home, '.config/agentos/sessions/a.json'), JSON.stringify({ cli: 'shell', dir: deps.home, created: 'c', createdBy: LOGIN }));
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/sessions/ag-zzz/stop', headers: HM })).statusCode).toBe(404);
    expect((await app.inject({ method: 'DELETE', url: '/api/sessions/ag-a', headers: HM })).statusCode).toBe(409);
    expect((await app.inject({ method: 'POST', url: '/api/sessions/ag-a/stop', headers: HM })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['tmux', 'kill-session', '-t', '=ag-a']);
    expect(JSON.parse(readFileSync(join(deps.home, '.config/agentos/sessions/a.json'), 'utf8')).ended).toBeTruthy();
  });

  it('lists directories inside home only', async () => {
    const { deps } = fakeDeps();
    mkdirSync(join(deps.home, 'b'));
    mkdirSync(join(deps.home, 'a'));
    mkdirSync(join(deps.home, '.hidden'));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/dirs', headers: H })).json()).toEqual({ path: deps.home, parent: null, dirs: ['a', 'b'] });
    expect((await app.inject({ url: '/api/dirs?path=/etc', headers: H })).statusCode).toBe(400);
  });
});
```

`web/server/test/terminal.test.ts`:
```ts
import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { execRunner } from '../src/run.js';
import { attachArgv, parseClientMsg } from '../src/terminal.js';
import { fakeDeps, H } from './helpers.js';

describe('terminal protocol', () => {
  it('parses client frames', () => {
    expect(parseClientMsg('{"t":"i","d":"ls\\r"}')).toEqual({ input: 'ls\r' });
    expect(parseClientMsg('{"t":"r","c":120,"r":40}')).toEqual({ cols: 120, rows: 40 });
    expect(parseClientMsg('{"t":"r","c":0,"r":40}')).toBeNull();
    expect(parseClientMsg('{"t":"r","c":1.5,"r":40}')).toBeNull();
    expect(parseClientMsg('ls')).toBeNull();
  });
  it('attaches by exact name', () => {
    expect(attachArgv('ag-x')).toEqual(['attach-session', '-t', '=ag-x']);
  });
});

// Needs Linux and a real tmux (CI installs it); the in-VM smoke check covers it end to end too.
const hasTmux = process.platform === 'linux' && (() => { try { execFileSync('tmux', ['-V']); return true; } catch { return false; } })();

it.skipIf(!hasTmux)('terminal WebSocket attaches to tmux, echoes typed input, and detaches on close', async () => {
  const { deps } = fakeDeps(() => ({}), { run: execRunner });
  const id = `ag-vitest-${process.pid}`;
  execFileSync('tmux', ['new-session', '-d', '-s', id, '-x', '80', '-y', '24', 'sh']);
  try {
    const app = await buildApp(deps);
    await app.ready();
    const ws = await app.injectWS(`/api/sessions/${id}/terminal?cols=80&rows=24`, { headers: { ...H, origin: 'http://127.0.0.1:7070' } });
    let out = '';
    const seen = new Promise<void>((resolve) => ws.on('message', (d: Buffer) => { out += d.toString(); if (out.includes('hi-42')) resolve(); }));
    ws.send(JSON.stringify({ t: 'i', d: 'echo hi-$((40+2))\r' }));
    await seen;
    ws.terminate();
    await new Promise((r) => setTimeout(r, 300));
    execFileSync('tmux', ['has-session', '-t', `=${id}`]);   // throws if the session was killed
    await app.close();
  } finally {
    execFileSync('tmux', ['kill-session', '-t', `=${id}`]);
  }
}, 15_000);
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd web/server && npx vitest run test/sessions.test.ts test/terminal.test.ts`
Expected: both files fail with `Cannot find module '../src/sessions.js'` / `'../src/terminal.js'`.

- [ ] **Step 3: Implement**

`web/server/src/sessions.ts`:
```ts
// Agent sessions: interactive tmux sessions of user agent, plus a JSON sidecar per UI-created
// session in ~/.config/agentos/sessions/<name>.json.
import { mkdir, readdir, readFile, realpath, stat, unlink, writeFile } from 'node:fs/promises';
import { dirname, join, sep } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { HttpError } from './run.js';
import type { Deps } from './app.js';

export const NAME_RE = /^[a-z0-9-]{1,32}$/;
export const CLIS = ['claude', 'codex', 'grok', 'opencode', 'shell'] as const;
export type Cli = (typeof CLIS)[number];
export const REPO_RE = /^(https:\/\/[^\s]+|git@[^\s:]+:[^\s]+|ssh:\/\/[^\s]+)$/;
// ':' separates fields: tmux never allows it in a session name, and it escapes control
// characters such as a tab in format output.
export const TMUX_FORMAT = '#{session_name}:#{session_created}:#{session_attached}';

export interface Sidecar { cli: Cli; dir: string; created: string; createdBy: string; ended?: string }
export interface Session {
  id: string; name: string; cli: string | null; dir: string | null; created: string | null;
  attached: number; state: 'running' | 'ended'; external: boolean;
}
interface TmuxSession { id: string; created: string; attached: number }

export function parseTmuxList(out: string): TmuxSession[] {
  return out.split('\n').filter(Boolean).flatMap((line) => {
    const m = line.match(/^(.+):(\d+):(\d+)$/);
    return m ? [{ id: m[1], created: new Date(Number(m[2]) * 1000).toISOString(), attached: Number(m[3]) }] : [];
  });
}

// realpath, then require the result to be home itself or inside it: catches "..", and symlinks out.
export async function resolveDir(dir: string, home: string): Promise<string> {
  let real: string;
  try {
    real = await realpath(dir);
  } catch {
    throw new HttpError(400, `no such directory: ${dir}`);
  }
  if (real !== home && !real.startsWith(home + sep)) throw new HttpError(400, `directory must be inside ${home}`);
  if (!(await stat(real)).isDirectory()) throw new HttpError(400, `not a directory: ${dir}`);
  return real;
}

export function tmuxNewArgv(name: string, dir: string, cli: Cli): string[] {
  if (!NAME_RE.test(name)) throw new HttpError(400, 'name must match [a-z0-9-]{1,32}');
  const cmd = cli === 'shell' ? ['bash', '-l'] : ['bash', '-lc', cli];
  return ['tmux', 'new-session', '-d', '-s', `ag-${name}`, '-c', dir, ...cmd];
}

export function defaultName(cli: Cli, taken: Set<string>): string {
  for (let n = 1; ; n++) if (!taken.has(`${cli}-${n}`)) return `${cli}-${n}`;
}

export const sidecarDir = (home: string) => join(home, '.config/agentos/sessions');

async function readSidecars(home: string): Promise<Map<string, Sidecar>> {
  const out = new Map<string, Sidecar>();
  let files: string[] = [];
  try { files = await readdir(sidecarDir(home)); } catch { return out; }
  for (const f of files) {
    const name = f.replace(/\.json$/, '');
    if (!f.endsWith('.json') || !NAME_RE.test(name)) continue;
    try { out.set(name, JSON.parse(await readFile(join(sidecarDir(home), f), 'utf8'))); } catch { /* skip a corrupt sidecar */ }
  }
  return out;
}

export async function tmuxSessions(deps: Deps): Promise<TmuxSession[]> {
  const r = await deps.run(['tmux', 'list-sessions', '-F', TMUX_FORMAT]);
  return r.code === 0 ? parseTmuxList(r.stdout) : [];   // no tmux server = no sessions
}

export async function listSessions(deps: Deps): Promise<Session[]> {
  const live = await tmuxSessions(deps);
  const sidecars = await readSidecars(deps.home);
  const out: Session[] = live.map((t) => {
    const s = t.id.startsWith('ag-') ? sidecars.get(t.id.slice(3)) : undefined;
    return { id: t.id, name: s ? t.id.slice(3) : t.id, cli: s?.cli ?? null, dir: s?.dir ?? null, created: s?.created ?? t.created,
             attached: t.attached, state: 'running', external: !s };
  });
  for (const [name, s] of sidecars) {
    if (live.some((t) => t.id === `ag-${name}`)) continue;
    out.push({ id: `ag-${name}`, name, cli: s.cli, dir: s.dir, created: s.created, attached: 0, state: 'ended', external: false });
  }
  return out.sort((a, b) => a.id.localeCompare(b.id));
}

export interface CreateBody { cli?: string; dir?: string; repo?: string; name?: string }

export async function createSession(deps: Deps, body: CreateBody, login: string): Promise<Session> {
  const cli = body.cli as Cli;
  if (!CLIS.includes(cli)) throw new HttpError(400, `cli must be one of ${CLIS.join(', ')}`);
  const sidecars = await readSidecars(deps.home);
  const live = await tmuxSessions(deps);
  const taken = new Set([...sidecars.keys(), ...live.filter((t) => t.id.startsWith('ag-')).map((t) => t.id.slice(3))]);
  const name = body.name || defaultName(cli, taken);
  if (!NAME_RE.test(name)) throw new HttpError(400, 'name must match [a-z0-9-]{1,32}');
  if (taken.has(name)) throw new HttpError(409, `session ${name} already exists`);

  let dir: string;
  if (body.repo) {
    if (!REPO_RE.test(body.repo)) throw new HttpError(400, 'repo must be an https://, ssh:// or git@ URL');
    const dest = join(deps.home, 'work', name);
    await mkdir(dirname(dest), { recursive: true });
    const r = await deps.run(['git', 'clone', '--', body.repo, dest], {
      timeoutMs: 300_000, env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: 'ssh -o BatchMode=yes' },
    });
    if (r.code !== 0) throw new HttpError(400, `git clone failed: ${r.stderr.trim()}`);
    deps.audit(login, 'repo-clone', dest);
    dir = await resolveDir(dest, deps.home);
  } else {
    dir = await resolveDir(body.dir || deps.home, deps.home);
  }

  const r = await deps.run(tmuxNewArgv(name, dir, cli), { cwd: dir });
  if (r.code !== 0) throw new HttpError(500, `tmux failed: ${r.stderr.trim()}`);
  const sidecar: Sidecar = { cli, dir, created: new Date().toISOString(), createdBy: login };
  await mkdir(sidecarDir(deps.home), { recursive: true });
  await writeFile(join(sidecarDir(deps.home), `${name}.json`), JSON.stringify(sidecar, null, 2) + '\n');
  deps.audit(login, 'session-create', `ag-${name}`);
  return { id: `ag-${name}`, name, cli, dir, created: sidecar.created, attached: 0, state: 'running', external: false };
}

export async function stopSession(deps: Deps, id: string, login: string): Promise<void> {
  if (!(await tmuxSessions(deps)).some((t) => t.id === id)) throw new HttpError(404, `no running session ${id}`);
  const r = await deps.run(['tmux', 'kill-session', '-t', `=${id}`]);
  if (r.code !== 0) throw new HttpError(500, `tmux failed: ${r.stderr.trim()}`);
  const name = id.slice(3);
  if (id.startsWith('ag-') && NAME_RE.test(name)) {
    const f = join(sidecarDir(deps.home), `${name}.json`);
    try {
      const s: Sidecar = JSON.parse(await readFile(f, 'utf8'));
      await writeFile(f, JSON.stringify({ ...s, ended: new Date().toISOString() }, null, 2) + '\n');
    } catch { /* external session: no sidecar */ }
  }
  deps.audit(login, 'session-stop', id);
}

export async function removeSession(deps: Deps, id: string, login: string): Promise<void> {
  const name = id.slice(3);
  if (!id.startsWith('ag-') || !NAME_RE.test(name)) throw new HttpError(404, `no session ${id}`);
  if ((await tmuxSessions(deps)).some((t) => t.id === id)) throw new HttpError(409, `session ${id} is running; stop it first`);
  try { await unlink(join(sidecarDir(deps.home), `${name}.json`)); } catch { throw new HttpError(404, `no session ${id}`); }
  deps.audit(login, 'session-remove', id);
}

export async function listDirs(path: string, home: string): Promise<{ path: string; parent: string | null; dirs: string[] }> {
  const real = await resolveDir(path || home, home);
  const entries = await readdir(real, { withFileTypes: true });
  const dirs = entries.filter((e) => e.isDirectory() && !e.name.startsWith('.')).map((e) => e.name).sort().slice(0, 500);
  return { path: real, parent: real === home ? null : dirname(real), dirs };
}

export function sessionRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/sessions', async () => listSessions(deps));
  app.post<{ Body: CreateBody }>('/api/sessions', async (req, reply) => reply.code(201).send(await createSession(deps, req.body ?? {}, req.login)));
  app.post<{ Params: { id: string } }>('/api/sessions/:id/stop', async (req) => { await stopSession(deps, req.params.id, req.login); return { ok: true }; });
  app.delete<{ Params: { id: string } }>('/api/sessions/:id', async (req) => { await removeSession(deps, req.params.id, req.login); return { ok: true }; });
  app.get<{ Querystring: { path?: string } }>('/api/dirs', async (req) => listDirs(req.query.path ?? '', deps.home));
}
```

`web/server/src/terminal.ts`:
```ts
// Browser terminal: WebSocket <-> node-pty running `tmux attach`. Closing the socket kills only the
// tmux client (a detach); the session keeps running.
import type { FastifyInstance } from 'fastify';
import * as pty from 'node-pty';
import type { Deps } from './app.js';
import { tmuxSessions } from './sessions.js';

export type ClientMsg = { input: string } | { cols: number; rows: number } | null;

// Client frames are JSON: {"t":"i","d":"<keys>"} or {"t":"r","c":<cols>,"r":<rows>}.
export function parseClientMsg(raw: string): ClientMsg {
  try {
    const m = JSON.parse(raw);
    if (m?.t === 'i' && typeof m.d === 'string') return { input: m.d };
    if (m?.t === 'r' && Number.isInteger(m.c) && Number.isInteger(m.r) && m.c > 0 && m.r > 0 && m.c <= 1000 && m.r <= 1000) {
      return { cols: m.c, rows: m.r };
    }
  } catch { /* not JSON */ }
  return null;
}

export function attachArgv(id: string): string[] {
  return ['attach-session', '-t', `=${id}`];   // "=": exact session name, no prefix matching
}

export function terminalRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Params: { id: string }; Querystring: { cols?: string; rows?: string } }>(
    '/api/sessions/:id/terminal', { websocket: true }, (socket, req) => {
      const id = req.params.id;
      let term: pty.IPty | null = null;
      const early: string[] = [];   // keys typed before the pty exists
      socket.on('message', (raw: Buffer) => {
        const m = parseClientMsg(raw.toString('utf8'));
        if (!m) return;
        if (!term) { if ('input' in m) early.push(m.input); }
        else if ('input' in m) term.write(m.input);
        else term.resize(m.cols, m.rows);
      });
      socket.on('close', () => term?.kill());
      tmuxSessions(deps).then((live) => {
        if (socket.readyState !== socket.OPEN) return;
        if (!live.some((t) => t.id === id)) return socket.close(1008, `no running session ${id}`);
        const env: NodeJS.ProcessEnv = { ...process.env, TERM: 'xterm-256color', LANG: 'C.UTF-8' };
        delete env.TMUX;   // node-pty would pass an undefined value as the string "undefined"
        try {
          term = pty.spawn('tmux', attachArgv(id), {
            name: 'xterm-256color',
            cols: Math.min(Number(req.query.cols) || 80, 1000),
            rows: Math.min(Number(req.query.rows) || 24, 1000),
            cwd: deps.home,
            env,
          });
        } catch (e) {
          return socket.close(1011, (e as Error).message.slice(0, 120));
        }
        term.onData((d) => socket.readyState === socket.OPEN && socket.send(d));
        term.onExit(() => socket.close());
        for (const d of early.splice(0)) term.write(d);
      }, (e: Error) => socket.close(1011, e.message.slice(0, 120)));
    });
}
```

In `web/server/src/app.ts`, add these lines under `// Route modules (one import per task):`:
```ts
import { sessionRoutes } from './sessions.js';
import { terminalRoutes } from './terminal.js';
```
and these lines under `// API routes (one line per task):`:
```ts
  sessionRoutes(app, deps);
  terminalRoutes(app, deps);
```

- [ ] **Step 4: Run the tests**

Run: `cd web/server && npx vitest run && npm run typecheck`
Expected: `Test Files  8 passed (8)`, `Tests  46 passed | 1 skipped (47)` on macOS (the live tmux test is skipped there; Linux with tmux: `47 passed`), then a clean typecheck.

If you have Docker on a Linux host, the live test can run there: `docker run --rm -v "$PWD/web:/src:ro" node:24 bash -c 'apt-get update -qq && apt-get install -y -qq tmux >/dev/null && cp -a /src /w && cd /w/server && rm -rf node_modules && HOME=/w npm ci && npx vitest run'`. Expected: `47 passed`. CI runs it in Task 10 in any case.

- [ ] **Step 5: Commit**

```bash
git add web/server
git commit -m "feat(web): sessions API (tmux + sidecars, realpath-confined directories, repo clone) and terminal WebSocket via node-pty"
```

---

### Task 4: Desktops API, thumbnails and the VNC WebSocket proxy

**Files:**
- Create: `web/server/src/desktops.ts`, `web/server/src/vnc.ts`
- Test: `web/server/test/desktops.test.ts`, `web/server/test/vnc.test.ts`
- Modify: `web/server/src/app.ts` (register `desktopRoutes`, `vncRoutes`)

**Interfaces:**
- Consumes:
  - `runAction`, `DESKTOP_RE` (actions.ts; the `desktop-start` and `desktop-stop` actions run `systemctl --no-ask-password start|stop agentos-desktop@N.service`, which agent may do through the existing polkit rule);
  - `HttpError` (run.ts), `Deps`;
  - `/etc/agentos/desktop.conf` (`MAX_DESKTOPS`, `IDLE_MINUTES` from small-fixes);
  - `/run/agentos/desktops/N.last` (small-fixes);
  - `/run/agentos/vnc/N` (`<token>: localhost:59NN`, mode 640 root:agent);
  - websockify on `127.0.0.1:6080` (`agentos-novnc`).
- Produces:
  - `desktops.ts`: `parseDesktopConf()`, `parseActive()`, `lowestFree()`, `desktopNumber(s)`, `activeDesktops(deps)`, `listDesktops`, `createDesktop`, `destroyDesktop`, `thumbnail`, `desktopRoutes`.
  - `vnc.ts`: `parseToken()`, `pipeSockets(client, connect)`, `vncRoutes(app, deps, upstreamBase?, tokenDir?)`.
  - API:
    - `GET /api/desktops` → `{max, desktops: [{id, idleSeconds, idleLimitMinutes, viewers}]}`;
    - `POST /api/desktops` → 201 `{id}`, or 409 when they're all in use;
    - `DELETE /api/desktops/:n`;
    - `GET /api/desktops/:n/thumbnail` → `image/png`, 480×270;
    - WebSocket `/api/desktops/:n/vnc` (binary RFB).
  - Viewers are counted as established TCP connections to `590N`, the same signal the idle reaper uses. Web viewers count too, because websockify connects to Xvnc.

- [ ] **Step 1: Write the failing tests**

`web/server/test/desktops.test.ts`:
```ts
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { lowestFree, parseActive, parseDesktopConf } from '../src/desktops.js';
import { fakeDeps, HM } from './helpers.js';

describe('desktop helpers', () => {
  it('parses desktop.conf with defaults and clamps', () => {
    expect(parseDesktopConf('MAX_DESKTOPS=4\nSCREENSHOT_WIDTH=1366\nIDLE_MINUTES=30\n')).toEqual({ max: 4, idleMinutes: 30 });
    expect(parseDesktopConf('MAX_DESKTOPS=99\n')).toEqual({ max: 8, idleMinutes: 120 });
  });
  it('parses active units and picks the lowest free number', () => {
    expect(parseActive('agentos-desktop@3.service loaded active running x\nagentos-desktop@1.service loaded active running x\n')).toEqual([1, 3]);
    expect(lowestFree([1, 3], 8)).toBe(2);
    expect(lowestFree([1, 2], 2)).toBeNull();
  });
  it('validates desktop numbers in routes', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'DELETE', url: '/api/desktops/0', headers: HM })).statusCode).toBe(400);
    expect((await app.inject({ method: 'DELETE', url: '/api/desktops/1;reboot', headers: HM })).statusCode).toBe(400);
    expect((await app.inject({ method: 'DELETE', url: '/api/desktops/2', headers: HM })).statusCode).toBe(404);
    expect(calls.every((c) => c.argv[1] === 'list-units')).toBe(true);
  });
});
```

`web/server/test/vnc.test.ts`:
```ts
import { mkdtempSync, writeFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import fastifyWebsocket from '@fastify/websocket';
import Fastify from 'fastify';
import { expect, it } from 'vitest';
import { WebSocketServer } from 'ws';
import { parseToken, vncRoutes } from '../src/vnc.js';
import { fakeDeps } from './helpers.js';

it('parses vnc-token files', () => {
  expect(parseToken('0123456789abcdef0123456789abcdef: localhost:5901\n')).toBe('0123456789abcdef0123456789abcdef');
  expect(() => parseToken('garbage')).toThrow();
});

it('proxies to websockify with the token added server-side', async () => {
  const token = 'ab'.repeat(16);
  const upstream = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  const seen: string[] = [];
  upstream.on('connection', (ws, req) => {
    seen.push(req.url ?? '');
    ws.on('message', (d: Buffer) => ws.send(Buffer.concat([Buffer.from('echo:'), d])));
  });
  await new Promise((r) => upstream.once('listening', r));
  const tokens = mkdtempSync(join(tmpdir(), 'vnc-'));
  writeFileSync(join(tokens, '1'), `${token}: localhost:5901\n`);

  const { deps } = fakeDeps((argv) => (argv[1] === 'list-units' ? { stdout: 'agentos-desktop@1.service loaded active running x\n' } : {}));
  const app = Fastify();
  app.decorateRequest('login', '');
  await app.register(fastifyWebsocket);
  vncRoutes(app, deps, `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}/websockify`, tokens);
  await app.ready();

  const ws = await app.injectWS('/api/desktops/1/vnc');
  const reply = new Promise<string>((r) => ws.once('message', (d: Buffer) => r(d.toString())));
  ws.send(Buffer.from('RFB 003.008\n'));
  expect(await reply).toBe('echo:RFB 003.008\n');
  expect(seen).toEqual([`/websockify?token=${token}`]);
  ws.terminate();

  const closed = await app.injectWS('/api/desktops/2/vnc');
  const code = await new Promise<number>((r) => closed.once('close', (c: number) => r(c)));
  expect(code).toBe(1011);
  upstream.close();
  await app.close();
});
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd web/server && npx vitest run test/desktops.test.ts test/vnc.test.ts`
Expected: both files fail with `Cannot find module '../src/desktops.js'` / `'../src/vnc.js'`.

- [ ] **Step 3: Implement**

`web/server/src/desktops.ts`:
```ts
// Desktops: systemd agentos-desktop@N (agent may start/stop them via polkit), thumbnails via scrot.
import { mkdtemp, readdir, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { DESKTOP_RE, runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';

export const DESKTOP_CONF = '/etc/agentos/desktop.conf';
export const LAST_DIR = '/run/agentos/desktops';

export interface DesktopConf { max: number; idleMinutes: number }
export interface Desktop { id: number; idleSeconds: number | null; idleLimitMinutes: number; viewers: number }

export function parseDesktopConf(text: string): DesktopConf {
  const num = (k: string, def: number, lo: number, hi: number) => {
    const v = Number(text.match(new RegExp(`^${k}=(\\d+)$`, 'm'))?.[1]);
    return Number.isInteger(v) && v >= lo && v <= hi ? v : def;
  };
  return { max: num('MAX_DESKTOPS', 8, 1, 16), idleMinutes: num('IDLE_MINUTES', 120, 0, 999999) };
}

export function parseActive(out: string): number[] {
  return [...new Set([...out.matchAll(/^agentos-desktop@(\d+)\.service\b/gm)].map((m) => Number(m[1])))].sort((a, b) => a - b);
}

export function lowestFree(active: number[], max: number): number | null {
  for (let n = 1; n <= max; n++) if (!active.includes(n)) return n;
  return null;
}

export function desktopNumber(s: string): number {
  if (!DESKTOP_RE.test(s)) throw new HttpError(400, 'invalid desktop');
  return Number(s);
}

async function conf(): Promise<DesktopConf> {
  try { return parseDesktopConf(await readFile(DESKTOP_CONF, 'utf8')); } catch { return parseDesktopConf(''); }
}

export async function activeDesktops(deps: Deps): Promise<number[]> {
  const r = await deps.run(['systemctl', 'list-units', 'agentos-desktop@*', '--state=active', '--plain', '--no-legend']);
  return parseActive(r.stdout);
}

async function needActive(deps: Deps, n: number): Promise<void> {
  if (!(await activeDesktops(deps)).includes(n)) throw new HttpError(404, `desktop ${n} is not running`);
}

export async function listDesktops(deps: Deps): Promise<Desktop[]> {
  const c = await conf();
  return Promise.all((await activeDesktops(deps)).map(async (id) => {
    let idleSeconds: number | null = null;
    try { idleSeconds = Math.max(0, Math.round((Date.now() - (await stat(join(LAST_DIR, `${id}.last`))).mtimeMs) / 1000)); } catch { /* no .last yet */ }
    const ss = await deps.run(['ss', '-Htn', 'state', 'established', `( sport = :${5900 + id} )`]);
    return { id, idleSeconds, idleLimitMinutes: c.idleMinutes, viewers: ss.stdout.split('\n').filter(Boolean).length };
  }));
}

// ponytail: no lock shared with agentos-computer's create_desktop; a simultaneous MCP create can
// pick the same N. Wrap pick+start in flock(1) on /tmp/agentos-desktop.lock if that ever bites.
export async function createDesktop(deps: Deps, login: string): Promise<{ id: number }> {
  const { max } = await conf();
  const n = lowestFree(await activeDesktops(deps), max);
  if (n === null) throw new HttpError(409, `all ${max} desktops are in use; destroy one first`);
  const r = await runAction(deps.run, { name: 'desktop-start', n });
  if (r.code !== 0) throw new HttpError(500, `could not start desktop ${n}: ${r.stderr.trim()}`);
  deps.audit(login, 'desktop-create', String(n));
  for (let i = 0; i < 150; i++) {
    const x = await deps.run(['xdotool', 'getdisplaygeometry'], { env: { ...process.env, DISPLAY: `:${n}` } });
    if (x.code === 0) return { id: n };
    await new Promise((res) => setTimeout(res, 200));
  }
  throw new HttpError(500, `desktop ${n} did not come up`);
}

export async function destroyDesktop(deps: Deps, n: number, login: string): Promise<void> {
  await needActive(deps, n);
  const r = await runAction(deps.run, { name: 'desktop-stop', n });
  if (r.code !== 0) throw new HttpError(500, `could not stop desktop ${n}: ${r.stderr.trim()}`);
  deps.audit(login, 'desktop-destroy', String(n));
}

// scrot --thumb 25 also writes a 25 % copy (1920 px -> 480 px wide) named <file>-thumb.png.
export async function thumbnail(deps: Deps, n: number): Promise<Buffer> {
  await needActive(deps, n);
  const d = await mkdtemp(join(tmpdir(), 'agentos-web-thumb-'));
  try {
    const r = await deps.run(['scrot', '--overwrite', '--thumb', '25', join(d, 's.png')], { env: { ...process.env, DISPLAY: `:${n}` } });
    if (r.code !== 0) throw new HttpError(500, `scrot failed: ${r.stderr.trim()}`);
    const thumb = (await readdir(d)).find((f) => f.includes('-thumb'));
    if (!thumb) throw new HttpError(500, 'scrot wrote no thumbnail');
    return await readFile(join(d, thumb));
  } finally {
    await rm(d, { recursive: true, force: true });
  }
}

export function desktopRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/desktops', async () => ({ max: (await conf()).max, desktops: await listDesktops(deps) }));
  app.post('/api/desktops', async (req, reply) => reply.code(201).send(await createDesktop(deps, req.login)));
  app.delete<{ Params: { n: string } }>('/api/desktops/:n', async (req) => {
    await destroyDesktop(deps, desktopNumber(req.params.n), req.login);
    return { ok: true };
  });
  app.get<{ Params: { n: string } }>('/api/desktops/:n/thumbnail', async (req, reply) =>
    reply.type('image/png').header('cache-control', 'no-store').send(await thumbnail(deps, desktopNumber(req.params.n))));
}
```

`web/server/src/vnc.ts`:
```ts
// Same-origin VNC: the browser connects to /api/desktops/N/vnc; we open websockify with the
// desktop's token, so the token never reaches the browser.
import { readFile } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import WebSocket from 'ws';
import type { Deps } from './app.js';
import { activeDesktops, desktopNumber } from './desktops.js';

export const TOKEN_DIR = '/run/agentos/vnc';
export const WEBSOCKIFY = 'ws://127.0.0.1:6080/websockify';

// Token file format (vnc-token): "<token>: localhost:<port>".
export function parseToken(text: string): string {
  const t = text.split(':', 1)[0].trim();
  if (!/^[0-9a-f]{32}$/.test(t)) throw new Error('bad token file');
  return t;
}

// Client listeners are attached synchronously: frames that arrive while we're still looking up
// the token are queued, not lost.
export function pipeSockets(client: WebSocket, connect: () => Promise<WebSocket>): void {
  const pending: Buffer[] = [];
  let upstream: WebSocket | null = null;
  client.on('message', (d: Buffer) => (upstream?.readyState === WebSocket.OPEN ? upstream.send(d) : pending.push(d)));
  client.on('close', () => upstream?.close());
  connect().then((up) => {
    upstream = up;
    if (client.readyState !== WebSocket.OPEN) return up.close();
    up.on('open', () => { for (const d of pending.splice(0)) up.send(d); });
    up.on('message', (d: Buffer) => client.readyState === WebSocket.OPEN && client.send(d));
    up.on('close', () => client.close());
    up.on('error', () => client.close(1011, 'upstream error'));
  }, (e: Error) => client.close(1011, e.message.slice(0, 120)));
}

export function vncRoutes(app: FastifyInstance, deps: Deps, upstreamBase = WEBSOCKIFY, tokenDir = TOKEN_DIR): void {
  app.get<{ Params: { n: string } }>('/api/desktops/:n/vnc', { websocket: true }, (socket, req) => {
    pipeSockets(socket, async () => {
      const n = desktopNumber(req.params.n);
      if (!(await activeDesktops(deps)).includes(n)) throw new Error(`desktop ${n} is not running`);
      const token = parseToken(await readFile(`${tokenDir}/${n}`, 'utf8'));
      return new WebSocket(`${upstreamBase}?token=${token}`, ['binary']);
    });
  });
}
```

In `web/server/src/app.ts`, add these lines under `// Route modules (one import per task):`:
```ts
import { desktopRoutes } from './desktops.js';
import { vncRoutes } from './vnc.js';
```
and these lines under `// API routes (one line per task):`:
```ts
  desktopRoutes(app, deps);
  vncRoutes(app, deps);
```

- [ ] **Step 4: Run the tests**

Run: `cd web/server && npx vitest run && npm run typecheck`
Expected: `Test Files  10 passed (10)`, `Tests  51 passed | 1 skipped (52)` (macOS), then a clean typecheck.

- [ ] **Step 5: Commit**

```bash
git add web/server
git commit -m "feat(web): desktops API with scrot thumbnails, and a same-origin VNC proxy that adds the websockify token server-side"
```

---

### Task 5: System API: health, services, journal and update streams, power, `/api/me`

**Files:**
- Create: `web/server/src/system.ts`
- Test: `web/server/test/system.test.ts`
- Modify: `web/server/src/app.ts` (register `systemRoutes`)

**Interfaces:**
- Consumes:
  - `argv`, `runAction`, `UNIT_RE` (actions.ts): `restart`, `journal`, `update`, `reboot` and `poweroff` are table entries;
  - `parseTailnetName` (auth.ts), `HttpError`, `Deps`.
- Produces:
  - `system.ts`: `parseCpu`, `cpuPercent`, `parseMeminfo`, `parseUnits`, `parseTailscale`, `health()`, `tailscale(deps)`, `streamToSocket(socket, argv, killOnClose?)`, `systemRoutes`.
  - API:
    - `GET /api/me` → `{login, hostname, tailnetIp, tailnetName}`;
    - `GET /api/system/health` → `{cpuPercent, load, memory: {totalBytes, usedBytes}, disk: {...}}`;
    - `GET /api/system/tailscale` → `{state, dnsName, ip, serve}` (`serve` comes from web.conf `SERVE=`);
    - `GET /api/system/services` → `[{unit, load, active, sub, description}]`;
    - `POST /api/system/services/:unit/restart`;
    - `GET /api/system/updates` → `{lastUnattended}`, the mtime of `/var/lib/apt/periodic/unattended-upgrades-stamp`;
    - `POST /api/system/power {action: 'reboot'|'poweroff', confirm: <hostname>}`;
    - WebSocket `/api/system/journal?unit=` (killed on close);
    - WebSocket `/api/system/update` (not killed on close).

- [ ] **Step 1: Write the failing test**

`web/server/test/system.test.ts`:
```ts
import { hostname } from 'node:os';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { cpuPercent, parseCpu, parseMeminfo, parseTailscale, parseUnits } from '../src/system.js';
import { fakeDeps, HM, LOGIN } from './helpers.js';

describe('system parsers', () => {
  it('cpu, memory', () => {
    const a = parseCpu('cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 1');
    const b = parseCpu('cpu  150 0 150 900 0 0 0 0 0 0\n');
    expect(cpuPercent(a, b)).toBe(50);
    expect(parseMeminfo('MemTotal:       4000 kB\nMemFree: 1 kB\nMemAvailable:   1000 kB\n')).toEqual({ totalBytes: 4096000, usedBytes: 3072000 });
  });
  it('units: keeps only allowlisted services', () => {
    const out = 'agentos-web.service loaded active running AgentOS web UI\nssh.service loaded active running OpenBSD\ndocker.service loaded active running Docker\n';
    expect(parseUnits(out)).toEqual([
      { unit: 'agentos-web.service', load: 'loaded', active: 'active', sub: 'running', description: 'AgentOS web UI' },
      { unit: 'docker.service', load: 'loaded', active: 'active', sub: 'running', description: 'Docker' },
    ]);
  });
  it('tailscale', () => {
    expect(parseTailscale('{"BackendState":"Running","Self":{"DNSName":"b.t.ts.net.","TailscaleIPs":["100.1.2.3"]}}'))
      .toEqual({ state: 'Running', dnsName: 'b.t.ts.net', ip: '100.1.2.3' });
    expect(parseTailscale('')).toEqual({ state: 'unavailable', dnsName: null, ip: null });
  });
  it('power needs the hostname typed', async () => {
    const { deps, calls, audits } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/system/power', headers: HM, payload: { action: 'reboot', confirm: 'wrong' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: '/api/system/power', headers: HM, payload: { action: 'halt', confirm: 'x' } })).statusCode).toBe(400);
    expect(calls).toEqual([]);
    expect((await app.inject({ method: 'POST', url: '/api/system/power', headers: HM, payload: { action: 'poweroff', confirm: hostname() } })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', 'systemctl', 'poweroff']);
    expect(audits).toEqual([`${LOGIN} poweroff ${hostname()}`]);
  });
  it('restart only allowlisted units', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/system/services/ssh.service/restart', headers: HM })).statusCode).toBe(400);
    expect(calls).toEqual([]);
    expect((await app.inject({ method: 'POST', url: '/api/system/services/docker.service/restart', headers: HM })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', 'systemctl', 'restart', 'docker.service']);
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd web/server && npx vitest run test/system.test.ts`
Expected: FAIL with `Cannot find module '../src/system.js'`.

- [ ] **Step 3: Implement**

`web/server/src/system.ts`:
```ts
// System: health, services, journal tail and updates (streamed over WebSocket), power.
import { spawn } from 'node:child_process';
import { readFile, stat, statfs } from 'node:fs/promises';
import { hostname, loadavg } from 'node:os';
import type { FastifyInstance } from 'fastify';
import type { WebSocket } from 'ws';
import { argv, runAction, UNIT_RE } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { parseTailnetName } from './auth.js';

export interface CpuSample { idle: number; total: number }
export interface Unit { unit: string; load: string; active: string; sub: string; description: string }

export function parseCpu(procStat: string): CpuSample {
  const f = procStat.split('\n')[0].trim().split(/\s+/).slice(1).map(Number);
  return { idle: f[3] + (f[4] || 0), total: f.reduce((a, b) => a + b, 0) };
}

export function cpuPercent(a: CpuSample, b: CpuSample): number {
  const dt = b.total - a.total;
  return dt > 0 ? Math.round((100 * (dt - (b.idle - a.idle))) / dt) : 0;
}

export function parseMeminfo(text: string): { totalBytes: number; usedBytes: number } {
  const kb = (k: string) => Number(text.match(new RegExp(`^${k}:\\s+(\\d+) kB`, 'm'))?.[1] ?? 0) * 1024;
  return { totalBytes: kb('MemTotal'), usedBytes: kb('MemTotal') - kb('MemAvailable') };
}

export function parseUnits(out: string): Unit[] {
  return out.split('\n').filter(Boolean).flatMap((line) => {
    const [unit, load, active, sub, ...desc] = line.trim().split(/\s+/);
    return UNIT_RE.test(unit) ? [{ unit, load, active, sub, description: desc.join(' ') }] : [];
  });
}

export interface TailscaleState { state: string; dnsName: string | null; ip: string | null }

export function parseTailscale(json: string): TailscaleState {
  try {
    const s = JSON.parse(json);
    return { state: String(s.BackendState ?? 'unknown'), dnsName: parseTailnetName(json), ip: s.Self?.TailscaleIPs?.[0] ?? s.TailscaleIPs?.[0] ?? null };
  } catch {
    return { state: 'unavailable', dnsName: null, ip: null };
  }
}

let prevCpu: CpuSample | null = null;

export async function health() {
  const cpu = parseCpu(await readFile('/proc/stat', 'utf8'));
  const percent = prevCpu ? cpuPercent(prevCpu, cpu) : 0;
  prevCpu = cpu;
  const fs = await statfs('/');
  return {
    cpuPercent: percent,
    load: loadavg(),
    memory: parseMeminfo(await readFile('/proc/meminfo', 'utf8')),
    disk: { totalBytes: fs.blocks * fs.bsize, usedBytes: (fs.blocks - fs.bfree) * fs.bsize },
  };
}

export async function tailscale(deps: Deps): Promise<TailscaleState> {
  const r = await deps.run(['tailscale', 'status', '--json']);
  return parseTailscale(r.stdout);
}

async function lastUnattended(): Promise<string | null> {
  try {
    return (await stat('/var/lib/apt/periodic/unattended-upgrades-stamp')).mtime.toISOString();
  } catch {
    return null;
  }
}

// Stream a command's output to a WebSocket. killOnClose=false for agentos-update: closing the
// tab must not kill apt mid-upgrade.
export function streamToSocket(socket: WebSocket, args: string[], killOnClose = true): void {
  const child = spawn(args[0], args.slice(1), { stdio: ['ignore', 'pipe', 'pipe'] });
  const send = (b: Buffer) => socket.readyState === socket.OPEN && socket.send(b.toString('utf8'));
  child.stdout.on('data', send);
  child.stderr.on('data', send);
  child.on('error', (e) => { send(Buffer.from(`\n[${e.message}]\n`)); socket.close(); });
  child.on('close', (code) => { send(Buffer.from(`\n[exit ${code}]\n`)); socket.close(); });
  if (killOnClose) socket.on('close', () => child.kill());
}

export function systemRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/me', async (req) => {
    const ts = await tailscale(deps);
    return { login: req.login, hostname: hostname(), tailnetIp: ts.ip, tailnetName: ts.dnsName };
  });
  app.get('/api/system/health', async () => health());
  app.get('/api/system/tailscale', async () => ({ ...(await tailscale(deps)), serve: deps.webConf().serve || 'unknown' }));
  app.get('/api/system/services', async () => {
    const r = await deps.run(['systemctl', 'list-units', '--all', '--plain', '--no-legend', '--type=service',
      'agentos-*', 'docker.service', 'tailscaled.service']);
    return parseUnits(r.stdout);
  });
  app.post<{ Params: { unit: string } }>('/api/system/services/:unit/restart', async (req) => {
    const r = await runAction(deps.run, { name: 'restart', unit: req.params.unit });
    deps.audit(req.login, 'service-restart', req.params.unit);
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim());
    return { ok: true };
  });
  app.get('/api/system/updates', async () => ({ lastUnattended: await lastUnattended() }));
  app.post<{ Body: { action?: string; confirm?: string } }>('/api/system/power', async (req) => {
    const action = req.body?.action;
    if (action !== 'reboot' && action !== 'poweroff') throw new HttpError(400, 'action must be reboot or poweroff');
    if (req.body?.confirm !== hostname()) throw new HttpError(400, 'type the hostname to confirm');
    deps.audit(req.login, action, hostname());
    const r = await runAction(deps.run, { name: action });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim());
    return { ok: true };
  });
  app.get<{ Querystring: { unit?: string } }>('/api/system/journal', { websocket: true }, (socket, req) => {
    try {
      streamToSocket(socket, argv({ name: 'journal', unit: req.query.unit ?? '' }));
    } catch (e) {
      socket.close(1008, (e as Error).message);
    }
  });
  app.get('/api/system/update', { websocket: true }, (socket, req) => {
    deps.audit(req.login, 'update', '-');
    streamToSocket(socket, argv({ name: 'update' }), false);
  });
}
```

In `web/server/src/app.ts`, add this line under `// Route modules (one import per task):`:
```ts
import { systemRoutes } from './system.js';
```
and this line under `// API routes (one line per task):`:
```ts
  systemRoutes(app, deps);
```

`app.ts` should now match this final form exactly:
```ts
// Fastify app: the auth hook first, then the API, then the static UI with an SPA fallback.
import { existsSync } from 'node:fs';
import fastifyStatic from '@fastify/static';
import fastifyWebsocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import { type Audit, journalAudit } from './audit.js';
import { authHook, parseTailnetName, readWebConf, type WebConf } from './auth.js';
import { execRunner, HttpError, type Runner } from './run.js';
// Route modules (one import per task):
import { settingsRoutes } from './settings.js';
import { sessionRoutes } from './sessions.js';
import { terminalRoutes } from './terminal.js';
import { desktopRoutes } from './desktops.js';
import { vncRoutes } from './vnc.js';
import { systemRoutes } from './system.js';

export interface Deps {
  run: Runner;
  webConf: () => WebConf;
  tsName: () => Promise<string | null>;
  audit: Audit;
  home: string;
  uiRoot: string | null;
  novncRoot: string | null;
}

export function cachedTailnetName(run: Runner, ttlMs = 60_000): () => Promise<string | null> {
  let value: string | null = null;
  let at = 0;
  return async () => {
    if (Date.now() - at > ttlMs) {
      value = parseTailnetName((await run(['tailscale', 'status', '--json'], { timeoutMs: 5000 })).stdout);
      at = Date.now();
    }
    return value;
  };
}

export function defaultDeps(): Deps {
  return {
    run: execRunner,
    webConf: () => readWebConf(),
    tsName: cachedTailnetName(execRunner),
    audit: journalAudit,
    home: '/home/agent',
    uiRoot: '/usr/local/lib/agentos/web/ui',
    novncRoot: '/usr/share/novnc',
  };
}

export async function buildApp(deps: Deps): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: 'warn' }, bodyLimit: 1024 * 1024 });
  app.decorateRequest('login', '');
  app.addHook('onRequest', authHook(deps.webConf, deps.tsName));
  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof HttpError) return reply.code(err.status).send({ error: err.message, field: err.field });
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) app.log.error(err);
    return reply.code(status).send({ error: status >= 500 ? 'internal error' : (err as Error).message });
  });
  await app.register(fastifyWebsocket, { options: { maxPayload: 4 * 1024 * 1024 } });

  // API routes (one line per task):
  settingsRoutes(app, deps);
  sessionRoutes(app, deps);
  terminalRoutes(app, deps);
  desktopRoutes(app, deps);
  vncRoutes(app, deps);
  systemRoutes(app, deps);

  if (deps.novncRoot && existsSync(deps.novncRoot)) {
    await app.register(fastifyStatic, { root: deps.novncRoot, prefix: '/novnc/', decorateReply: false });
  }
  if (deps.uiRoot && existsSync(deps.uiRoot)) {
    await app.register(fastifyStatic, { root: deps.uiRoot, prefix: '/' });
    app.setNotFoundHandler((req, reply) =>
      req.url.startsWith('/api/') ? reply.code(404).send({ error: 'not found' }) : reply.sendFile('index.html'));
  }
  return app;
}
```

- [ ] **Step 4: Run the whole server suite and build**

Run: `cd web/server && npx vitest run && npm run typecheck && npm run build`
Expected: `Test Files  11 passed (11)`, `Tests  56 passed | 1 skipped (57)` (macOS), then a clean typecheck and build.

- [ ] **Step 5: Commit**

```bash
git add web/server
git commit -m "feat(web): system API: health, services with restart, journal and agentos-update streams, power with hostname confirmation"
```

---

### Task 6: UI shell, Overview and Settings

**Files:**
- Create: `web/ui/package.json`, `web/ui/package-lock.json` (generated), `web/ui/tsconfig.json`, `web/ui/vite.config.ts`, `web/ui/index.html`
- Create: `web/ui/src/{main.tsx,App.tsx,api.ts,router.tsx,usePoll.ts,types.ts,format.ts,quick.ts,style.css}`
- Create: `web/ui/src/components/{Confirm.ts,ErrorText.tsx,SecretField.tsx,SettingsForm.tsx,SshKeys.tsx}`
- Create: `web/ui/src/pages/{Overview.tsx,Settings.tsx}`
- Test: `web/ui/test/api.test.ts`, `web/ui/test/SecretField.test.tsx`, `web/ui/test/SettingsForm.test.tsx`

**Interfaces:**
- Consumes: the server API from Tasks 1–5 (only over HTTP: the UI has no compile-time link to the server).
- Produces (used by Tasks 7–8):
  - `api<T>(path, method = 'GET', body?)`: it adds `X-AgentOS: 1` on non-GET requests, and throws `ApiError(status, message, field?)`.
  - `wsUrl(path)`.
  - `usePath()`, `navigate(to)`, `<Link to>`.
  - `usePoll(fn, ms = 0, deps = []) → {data, error, reload}`.
  - Types in `types.ts`: `Me`, `Session`, `Desktop`, `Health`, `Tailscale`, `Settings`, `SshKey`, `Unit`.
  - `openTerminal()` and `newDesktop()` in `quick.ts`.
  - `confirmAction(msg)`; `<ErrorText error>`, which renders `role="alert"`.
  - `App.tsx` has a `page()` switch on the first path segment, and the marker comment `// Pages (one import per task):`. Tasks 7 and 8 add their imports and `case` lines.
  - CSS classes (`style.css`): `.layout .cards .card .grid .panel .field .row .actions .toolbar .error .badge .log .dirpicker .terminal-page .desktop-page .term-host .vnc`.

- [ ] **Step 1: Scaffold the package and install pinned dependencies**

`web/ui/package.json`:
```json
{
  "name": "agentos-web-ui",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json && vite build",
    "typecheck": "tsc -p tsconfig.json",
    "test": "vitest run"
  },
  "devDependencies": {
    "@testing-library/dom": "10.4.2",
    "@testing-library/react": "16.3.3",
    "@types/react": "19.3.0",
    "@types/react-dom": "19.3.0",
    "@xterm/addon-fit": "0.11.0",
    "@xterm/xterm": "6.0.0",
    "jsdom": "30.1.3",
    "react": "19.3.1",
    "react-dom": "19.3.1",
    "typescript": "7.0.2",
    "vite": "8.3.5",
    "vitest": "5.0.5"
  }
}
```

`web/ui/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "es2023",
    "lib": ["es2023", "dom", "dom.iterable"],
    "module": "esnext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["vite/client"]
  },
  "include": ["src", "test", "vite.config.ts"]
}
```

`web/ui/vite.config.ts`:
```ts
/// <reference types="vitest/config" />
import { defineConfig } from 'vite';

export default defineConfig({
  build: { outDir: 'dist', target: 'es2023', chunkSizeWarningLimit: 1000 },
  server: { proxy: { '/api': { target: 'http://127.0.0.1:7070', ws: true }, '/novnc': 'http://127.0.0.1:7070' } },
  test: { environment: 'jsdom' },
});
```

Run: `cd web/ui && npm install`
Expected: it creates `package-lock.json` and ends with `found 0 vulnerabilities`.

- [ ] **Step 2: Write the failing tests**

`web/ui/test/api.test.ts`:
```ts
import { afterEach, expect, it, vi } from 'vitest';
import { api, ApiError } from '../src/api';

afterEach(() => vi.unstubAllGlobals());

function stubFetch(status: number, body: unknown) {
  const fetch = vi.fn(async () => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } }));
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

it('sends X-AgentOS: 1 and JSON on mutating requests, nothing extra on GET', async () => {
  const fetch = stubFetch(200, { ok: true });
  await api('/api/x', 'POST', { a: 1 });
  expect(fetch).toHaveBeenLastCalledWith('/api/x', { method: 'POST', headers: { 'X-AgentOS': '1', 'Content-Type': 'application/json' }, body: '{"a":1}' });
  await api('/api/x', 'DELETE');
  expect(fetch).toHaveBeenLastCalledWith('/api/x', { method: 'DELETE', headers: { 'X-AgentOS': '1' }, body: undefined });
  await api('/api/x');
  expect(fetch).toHaveBeenLastCalledWith('/api/x', { method: 'GET', headers: {}, body: undefined });
});

it('turns an error body into an ApiError with the field', async () => {
  stubFetch(400, { error: 'must be 1-16', field: 'AGENTOS_MAX_DESKTOPS' });
  await expect(api('/api/settings', 'PUT', {})).rejects.toEqual(new ApiError(400, 'must be 1-16', 'AGENTOS_MAX_DESKTOPS'));
});
```

`web/ui/test/SecretField.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { SecretField } from '../src/components/SecretField';

afterEach(cleanup);

it('shows set / not set, never a value, and starts empty', () => {
  const { container, rerender } = render(<SecretField name="K" label="Key" isSet onSave={vi.fn()} />);
  expect(screen.getByText('set')).toBeTruthy();
  const input = container.querySelector('input')!;
  expect(input.type).toBe('password');
  expect(input.value).toBe('');
  rerender(<SecretField name="K" label="Key" isSet={false} onSave={vi.fn()} />);
  expect(screen.getByText('not set')).toBeTruthy();
  expect(screen.queryByText('Clear')).toBeNull();
});

it('saves the typed value, then clears the input', async () => {
  const onSave = vi.fn(async () => {});
  const { container } = render(<SecretField name="K" label="Key" isSet={false} onSave={onSave} />);
  const input = container.querySelector('input')!;
  fireEvent.change(input, { target: { value: 'sk-new' } });
  fireEvent.click(screen.getByText('Save'));
  await vi.waitFor(() => expect(input.value).toBe(''));
  expect(onSave).toHaveBeenCalledWith('K', 'sk-new');
});

it('Clear sends an empty value', async () => {
  const onSave = vi.fn(async () => {});
  render(<SecretField name="K" label="Key" isSet onSave={onSave} />);
  fireEvent.click(screen.getByText('Clear'));
  await vi.waitFor(() => expect(onSave).toHaveBeenCalledWith('K', ''));
});

it('shows a save error', async () => {
  const onSave = vi.fn(async () => { throw new Error('rejected'); });
  const { container } = render(<SecretField name="K" label="Key" onSave={onSave} />);
  fireEvent.change(container.querySelector('input')!, { target: { value: 'x' } });
  fireEvent.click(screen.getByText('Save'));
  expect((await screen.findByRole('alert')).textContent).toBe('rejected');
});
```

`web/ui/test/SettingsForm.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ApiError } from '../src/api';
import { SettingsForm, type FieldSpec } from '../src/components/SettingsForm';

afterEach(cleanup);

const FIELDS: FieldSpec[] = [
  { key: 'AGENTOS_MAX_DESKTOPS', label: 'Max', type: 'number' },
  { key: 'AGENTOS_LAN_SSH', label: 'LAN SSH', type: 'bool' },
];

it('saves only changed fields', async () => {
  const onSave = vi.fn(async () => {});
  render(<SettingsForm title="T" fields={FIELDS} values={{ AGENTOS_MAX_DESKTOPS: '8', AGENTOS_LAN_SSH: '0' }} onSave={onSave} />);
  fireEvent.click(screen.getByLabelText('LAN SSH'));
  fireEvent.click(screen.getByText('Save'));
  await vi.waitFor(() => expect(onSave).toHaveBeenCalledWith({ AGENTOS_LAN_SSH: '1' }));
});

it('shows a validation error next to its field', async () => {
  const onSave = vi.fn(async () => { throw new ApiError(400, 'must be 1-16', 'AGENTOS_MAX_DESKTOPS'); });
  render(<SettingsForm title="T" fields={FIELDS} values={{ AGENTOS_MAX_DESKTOPS: '8' }} onSave={onSave} />);
  fireEvent.change(screen.getByLabelText('Max'), { target: { value: '99' } });
  fireEvent.click(screen.getByText('Save'));
  const alert = await screen.findByRole('alert');
  expect(alert.textContent).toBe('must be 1-16');
  expect(alert.closest('.field')!.textContent).toContain('Max');
});

it('beforeSave can cancel the save', async () => {
  const onSave = vi.fn(async () => {});
  render(<SettingsForm title="T" fields={FIELDS} values={{ AGENTOS_MAX_DESKTOPS: '8' }} onSave={onSave} beforeSave={() => false} />);
  fireEvent.change(screen.getByLabelText('Max'), { target: { value: '4' } });
  fireEvent.click(screen.getByText('Save'));
  await new Promise((r) => setTimeout(r, 20));
  expect(onSave).not.toHaveBeenCalled();
});
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `cd web/ui && npx vitest run`
Expected: `Test Files  3 failed (3)` with `Failed to resolve import "../src/api"` (and `../src/components/SecretField` / `SettingsForm`).

- [ ] **Step 4: Implement**

`web/ui/index.html`:
```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>AgentOS</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

`web/ui/src/main.tsx`:
```tsx
import { createRoot } from 'react-dom/client';
import { App } from './App';
import './style.css';

createRoot(document.getElementById('root')!).render(<App />);
```

`web/ui/src/api.ts`:
```ts
// fetch wrapper: JSON in/out, X-AgentOS: 1 on every mutating request (the server's CSRF check).
export class ApiError extends Error {
  constructor(public status: number, message: string, public field?: string) { super(message); }
}

export async function api<T = unknown>(path: string, method = 'GET', body?: unknown): Promise<T> {
  const headers: Record<string, string> = {};
  if (method !== 'GET') headers['X-AgentOS'] = '1';
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const data = r.headers.get('content-type')?.includes('application/json') ? await r.json() : await r.text();
  if (!r.ok) throw new ApiError(r.status, typeof data === 'string' ? data : data.error, typeof data === 'string' ? undefined : data.field);
  return data as T;
}

export const wsUrl = (path: string) => `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}${path}`;
```

`web/ui/src/router.tsx`:
```tsx
// A ten-line router: the server serves index.html for every non-/api path.
import { type ReactNode, useEffect, useState } from 'react';

export function usePath(): string {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => {
    const onPop = () => setPath(location.pathname);
    addEventListener('popstate', onPop);
    return () => removeEventListener('popstate', onPop);
  }, []);
  return path;
}

export function navigate(to: string): void {
  history.pushState(null, '', to);
  dispatchEvent(new PopStateEvent('popstate'));
}

export function Link({ to, children, className }: { to: string; children: ReactNode; className?: string }) {
  return (
    <a href={to} className={className} onClick={(e) => { if (!e.metaKey && !e.ctrlKey) { e.preventDefault(); navigate(to); } }}>
      {children}
    </a>
  );
}
```

`web/ui/src/usePoll.ts`:
```ts
import { useCallback, useEffect, useState } from 'react';

// Calls fn now, then every ms milliseconds (0 = once). Refetches when deps change or on reload().
export function usePoll<T>(fn: () => Promise<T>, ms = 0, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    let live = true;
    const load = () => fn().then((d) => { if (live) { setData(d); setError(null); } }, (e: Error) => { if (live) setError(e.message); });
    load();
    const id = ms ? setInterval(load, ms) : undefined;
    return () => { live = false; clearInterval(id); };
  }, [ms, tick, ...deps]);
  return { data, error, reload };
}
```

`web/ui/src/types.ts`:
```ts
export interface Me { login: string; hostname: string; tailnetIp: string | null; tailnetName: string | null }
export interface Session { id: string; name: string; cli: string | null; dir: string | null; created: string | null; attached: number; state: 'running' | 'ended'; external: boolean }
export interface Desktop { id: number; idleSeconds: number | null; idleLimitMinutes: number; viewers: number }
export interface Health { cpuPercent: number; load: number[]; memory: { totalBytes: number; usedBytes: number }; disk: { totalBytes: number; usedBytes: number } }
export interface Tailscale { state: string; dnsName: string | null; ip: string | null; serve: string }
export interface Settings { values: Record<string, string>; secrets: Record<string, boolean> }
export interface SshKey { bits: string; fingerprint: string; comment: string; type: string }
export interface Unit { unit: string; load: string; active: string; sub: string; description: string }
```

`web/ui/src/format.ts`:
```ts
export const gib = (b: number) => `${(b / 2 ** 30).toFixed(1)} GiB`;
export const pct = (used: number, total: number) => (total ? Math.round((100 * used) / total) : 0);
export const minutes = (s: number | null) => (s === null ? '?' : `${Math.floor(s / 60)} min`);
```

`web/ui/src/quick.ts`:
```ts
// Quick actions shared by Overview, Sessions, Desktops and System.
import { api } from './api';
import { navigate } from './router';

export async function openTerminal(): Promise<void> {
  try {
    const s = await api<{ id: string }>('/api/sessions', 'POST', { cli: 'shell' });
    navigate(`/sessions/${encodeURIComponent(s.id)}`);
  } catch (e) {
    alert((e as Error).message);
  }
}

export async function newDesktop(): Promise<void> {
  try {
    const d = await api<{ id: number }>('/api/desktops', 'POST');
    navigate(`/desktops/${d.id}`);
  } catch (e) {
    alert((e as Error).message);
  }
}
```

`web/ui/src/style.css`:
```css
:root { color-scheme: dark; --bg: #0d1117; --panel: #161b22; --line: #30363d; --text: #e6edf3; --muted: #8b949e; --accent: #58a6ff; --bad: #f85149; --ok: #3fb950; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.5 system-ui, sans-serif; }
a { color: var(--accent); }
code, pre { font-family: ui-monospace, monospace; }
button, input, select { font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 6px 10px; }
button { cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
.layout { display: grid; grid-template: "head head" auto "nav main" 1fr / 180px 1fr; min-height: 100vh; }
header { grid-area: head; display: flex; gap: 16px; align-items: center; padding: 10px 16px; border-bottom: 1px solid var(--line); }
header .login { margin-left: auto; color: var(--muted); }
nav { grid-area: nav; display: flex; flex-direction: column; padding: 12px; gap: 4px; border-right: 1px solid var(--line); }
nav a { padding: 8px 10px; border-radius: 6px; text-decoration: none; color: var(--text); }
nav a.active { background: var(--panel); }
main { grid-area: main; padding: 16px 24px; min-width: 0; }
@media (max-width: 800px) { .layout { grid-template: "head" auto "nav" auto "main" 1fr / 1fr; } nav { flex-direction: row; overflow-x: auto; border-right: 0; } }
.cards, .grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); }
.grid { grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); }
.card, .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 12px 16px; margin-bottom: 12px; }
.card p { font-size: 24px; margin: 4px 0; }
.card small, .hint { color: var(--muted); }
.desktop img { width: 100%; height: auto; display: block; background: #000; }
.row, .actions, .toolbar, .field { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin: 6px 0; }
.toolbar { margin: 0 0 8px; }
.field label { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
table { width: 100%; border-collapse: collapse; }
td, th { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); }
.error { color: var(--bad); margin: 4px 0; }
.ok { color: var(--ok); }
.bad { color: var(--bad); }
.badge { font-size: 12px; padding: 1px 6px; border-radius: 10px; background: var(--line); }
.badge.ok { background: #1f6f3b; color: #fff; }
.log { background: #000; height: 360px; overflow: auto; padding: 8px; white-space: pre-wrap; }
.dirpicker ul { list-style: none; padding: 0; max-height: 220px; overflow: auto; }
.dirpicker button { border: 0; background: none; color: var(--accent); padding: 2px 0; }
.terminal-page, .desktop-page { display: flex; flex-direction: column; height: calc(100vh - 90px); }
.term-host, .vnc { flex: 1; min-height: 0; background: #000; }
fieldset { border: 0; padding: 0; display: flex; gap: 16px; }
.keys { padding-left: 16px; }
```

`web/ui/src/components/Confirm.ts`:
```ts
// ponytail: native confirm() is the confirmation dialog; swap for a modal if it ever needs styling.
export const confirmAction = (message: string): boolean => window.confirm(message);
```

`web/ui/src/components/ErrorText.tsx`:
```tsx
export function ErrorText({ error }: { error: string | null | undefined }) {
  return error ? <p className="error" role="alert">{error}</p> : null;
}
```

`web/ui/src/components/SecretField.tsx`:
```tsx
import { useState } from 'react';
import { ErrorText } from './ErrorText';

// Write-only: the current value is never shown (the server never sends it). Shows set / not set,
// sends a new value on Save, and "" on Clear.
export function SecretField({ name, label, isSet, onSave }: {
  name: string; label: string; isSet?: boolean; onSave: (key: string, value: string) => Promise<void>;
}) {
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const save = async (v: string) => {
    setBusy(true);
    setError(null);
    try {
      await onSave(name, v);
      setValue('');
    } catch (e) {
      setError((e as Error).message);
    }
    setBusy(false);
  };
  return (
    <div className="field">
      <label>
        {label}{' '}
        {isSet !== undefined && <span className={isSet ? 'badge ok' : 'badge'}>{isSet ? 'set' : 'not set'}</span>}
        <input type="password" autoComplete="off" value={value} placeholder={isSet ? '•••••• (enter to replace)' : ''} onChange={(e) => setValue(e.target.value)} />
      </label>
      <button disabled={busy || !value} onClick={() => save(value)}>Save</button>
      {isSet && <button disabled={busy} onClick={() => save('')}>Clear</button>}
      <ErrorText error={error} />
    </div>
  );
}
```

`web/ui/src/components/SettingsForm.tsx`:
```tsx
import { type FormEvent, useState } from 'react';
import { ApiError } from '../api';
import { ErrorText } from './ErrorText';

export interface FieldSpec { key: string; label: string; type: 'text' | 'number' | 'bool' | 'select'; options?: string[] }

// A form for plain (non-secret) settings. Saves only changed fields; agentos-config's validation
// error is shown next to the field it names.
export function SettingsForm({ title, fields, values, onSave, beforeSave }: {
  title: string; fields: FieldSpec[]; values: Record<string, string>;
  onSave: (changed: Record<string, string>) => Promise<void>;
  beforeSave?: (changed: Record<string, string>) => boolean;
}) {
  const [draft, setDraft] = useState<Record<string, string>>(values);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: string) => setDraft((d) => ({ ...d, [k]: v }));

  async function submit(e: FormEvent) {
    e.preventDefault();
    const changed = Object.fromEntries(fields.filter((f) => (draft[f.key] ?? '') !== (values[f.key] ?? '')).map((f) => [f.key, draft[f.key] ?? '']));
    if (Object.keys(changed).length === 0 || (beforeSave && !beforeSave(changed))) return;
    setBusy(true);
    setErrors({});
    setError(null);
    try {
      await onSave(changed);
    } catch (err) {
      if (err instanceof ApiError && err.field) setErrors({ [err.field]: err.message });
      else setError((err as Error).message);
    }
    setBusy(false);
  }

  return (
    <form className="panel" onSubmit={submit}>
      <h2>{title}</h2>
      {fields.map((f) => (
        <div className="field" key={f.key}>
          <label>
            {f.label}{' '}
            {f.type === 'bool' ? <input type="checkbox" checked={draft[f.key] === '1'} onChange={(e) => set(f.key, e.target.checked ? '1' : '0')} />
              : f.type === 'select' ? <select value={draft[f.key] ?? ''} onChange={(e) => set(f.key, e.target.value)}>{f.options!.map((o) => <option key={o} value={o}>{o || '(default)'}</option>)}</select>
              : <input type={f.type} value={draft[f.key] ?? ''} placeholder="(default)" onChange={(e) => set(f.key, e.target.value)} />}
          </label>
          <ErrorText error={errors[f.key]} />
        </div>
      ))}
      <ErrorText error={error} />
      <button disabled={busy}>{busy ? 'Saving and applying…' : 'Save'}</button>
    </form>
  );
}
```

`web/ui/src/components/SshKeys.tsx`:
```tsx
import { useState } from 'react';
import { api } from '../api';
import type { SshKey } from '../types';
import { usePoll } from '../usePoll';
import { confirmAction } from './Confirm';
import { ErrorText } from './ErrorText';

export function SshKeys() {
  const { data, error, reload } = usePoll(() => api<SshKey[]>('/api/ssh-keys'));
  const [key, setKey] = useState('');
  const [user, setUser] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const run = (p: Promise<unknown>, clear: () => void) => p.then(() => { clear(); setErr(null); reload(); }, (e: Error) => setErr(e.message));
  return (
    <div className="panel">
      <h2>SSH keys</h2>
      <ErrorText error={error} />
      <ul className="keys">
        {data?.map((k) => (
          <li key={k.fingerprint}>
            <code>{k.fingerprint}</code> {k.type} {k.comment}{' '}
            <button onClick={() => confirmAction(`Remove ${k.comment || k.fingerprint}?`) && run(api('/api/ssh-keys/remove', 'POST', { fingerprint: k.fingerprint }), () => {})}>Remove</button>
          </li>
        ))}
      </ul>
      <div className="field"><input value={key} onChange={(e) => setKey(e.target.value)} placeholder="ssh-ed25519 AAAA… you@laptop" />
        <button disabled={!key} onClick={() => run(api('/api/ssh-keys', 'POST', { key }), () => setKey(''))}>Add</button></div>
      <div className="field"><input value={user} onChange={(e) => setUser(e.target.value)} placeholder="GitHub username" />
        <button disabled={!user} onClick={() => run(api('/api/ssh-keys/github', 'POST', { user }), () => setUser(''))}>Import from GitHub</button></div>
      <ErrorText error={err} />
    </div>
  );
}
```

`web/ui/src/pages/Overview.tsx`:
```tsx
import { api } from '../api';
import { ErrorText } from '../components/ErrorText';
import { gib, pct } from '../format';
import { newDesktop, openTerminal } from '../quick';
import { navigate } from '../router';
import type { Desktop, Health, Session, Tailscale } from '../types';
import { usePoll } from '../usePoll';

export function Overview() {
  const health = usePoll(() => api<Health>('/api/system/health'), 5000);
  const sessions = usePoll(() => api<Session[]>('/api/sessions'), 5000);
  const desktops = usePoll(() => api<{ desktops: Desktop[] }>('/api/desktops'), 5000);
  const ts = usePoll(() => api<Tailscale>('/api/system/tailscale'), 30000);
  const h = health.data;
  return (
    <section>
      <h1>Overview</h1>
      <ErrorText error={health.error} />
      {h && (
        <div className="cards">
          <div className="card"><h3>CPU</h3><p>{h.cpuPercent} %</p><small>load {h.load.map((l) => l.toFixed(2)).join(' ')}</small></div>
          <div className="card"><h3>Memory</h3><p>{pct(h.memory.usedBytes, h.memory.totalBytes)} %</p><small>{gib(h.memory.usedBytes)} of {gib(h.memory.totalBytes)}</small></div>
          <div className="card"><h3>Disk</h3><p>{pct(h.disk.usedBytes, h.disk.totalBytes)} %</p><small>{gib(h.disk.usedBytes)} of {gib(h.disk.totalBytes)}</small></div>
          <div className="card"><h3>Sessions</h3><p>{sessions.data?.filter((s) => s.state === 'running').length ?? '…'}</p></div>
          <div className="card"><h3>Desktops</h3><p>{desktops.data?.desktops.length ?? '…'}</p></div>
          <div className="card"><h3>Tailscale</h3><p>{ts.data?.state ?? '…'}</p><small>serve: {ts.data?.serve ?? '…'}</small></div>
        </div>
      )}
      <div className="actions">
        <button onClick={() => navigate('/sessions')}>New session</button>
        <button onClick={newDesktop}>New desktop</button>
        <button onClick={openTerminal}>Open terminal</button>
      </div>
    </section>
  );
}
```

`web/ui/src/pages/Settings.tsx`:
```tsx
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { SecretField } from '../components/SecretField';
import { type FieldSpec, SettingsForm } from '../components/SettingsForm';
import { SshKeys } from '../components/SshKeys';
import type { Me, Settings as SettingsData, Tailscale } from '../types';
import { usePoll } from '../usePoll';

const SECRETS: [string, string][] = [
  ['ANTHROPIC_API_KEY', 'Anthropic API key'], ['OPENAI_API_KEY', 'OpenAI API key'],
  ['GROK_CODE_XAI_API_KEY', 'xAI API key (Grok)'], ['CLAUDE_CODE_OAUTH_TOKEN', 'Claude Code OAuth token'],
];
const ACCESS: FieldSpec[] = [
  { key: 'AGENTOS_LAN_SSH', label: 'Allow SSH from the LAN (key-only)', type: 'bool' },
  { key: 'AGENTOS_CONSOLE', label: 'Local console', type: 'select', options: ['', 'headless', 'terminal'] },
  { key: 'AGENTOS_AUTO_REBOOT', label: 'Auto-reboot at 04:00 for kernel updates', type: 'bool' },
];
const DESKTOPS: FieldSpec[] = [
  { key: 'AGENTOS_MAX_DESKTOPS', label: 'Max desktops (1-16)', type: 'number' },
  { key: 'AGENTOS_SCREENSHOT_WIDTH', label: 'Screenshot width (640-1920)', type: 'number' },
  { key: 'AGENTOS_DESKTOP_IDLE_MINUTES', label: 'Stop idle desktops after (minutes, 0 = never)', type: 'number' },
];
const WEB: FieldSpec[] = [
  { key: 'AGENTOS_WEB_USERS', label: 'Allowed tailnet logins (comma-separated)', type: 'text' },
  { key: 'AGENTOS_WEB', label: 'Web UI enabled', type: 'bool' },
];

// AGENTOS_AUTO_REBOOT and AGENTOS_WEB default to on when unset: show unset as '1'.
const withDefaults = (v: Record<string, string>) => ({ ...v, AGENTOS_AUTO_REBOOT: v.AGENTOS_AUTO_REBOOT || '1', AGENTOS_WEB: v.AGENTOS_WEB || '1' });

export function Settings({ me }: { me: Me | null }) {
  const settings = usePoll(() => api<SettingsData>('/api/settings'));
  const ts = usePoll(() => api<Tailscale>('/api/system/tailscale'));
  const save = async (values: Record<string, string>) => {
    if (values.AGENTOS_WEB_USERS !== undefined) values = { ...values, AGENTOS_WEB_USERS: values.AGENTOS_WEB_USERS.replace(/\s+/g, '') };
    await api('/api/settings', 'PUT', { values });
    settings.reload();
  };
  const saveOne = (key: string, value: string) => save({ [key]: value });
  const webGuard = (changed: Record<string, string>) => {
    const users = changed.AGENTOS_WEB_USERS;
    if (users !== undefined && me && !users.toLowerCase().split(',').map((u) => u.trim()).includes(me.login)) {
      if (!confirmAction(`${me.login} is not in the new list: you will lose access to this page. Continue?`)) return false;
    }
    return changed.AGENTOS_WEB !== '0' || confirmAction('Disable the web UI? You will need SSH or the console to turn it back on.');
  };
  const s = settings.data;
  return (
    <section>
      <h1>Settings</h1>
      <ErrorText error={settings.error} />
      {s && (
        <>
          <div className="panel">
            <h2>API keys and tokens</h2>
            <p className="hint">Use a dedicated, spend-capped key per AgentOS machine: a hijacked agent can read any key stored here.</p>
            {SECRETS.map(([k, label]) => <SecretField key={k} name={k} label={label} isSet={s.secrets[k]} onSave={saveOne} />)}
          </div>
          <div className="panel">
            <h2>Tailscale</h2>
            <p>State: {ts.data?.state ?? '…'} {ts.data?.dnsName && <code>{ts.data.dnsName}</code>} · serve: {ts.data?.serve ?? '…'}</p>
            <p className="hint">Use a single-use, pre-approved auth key tagged <code>tag:agentos</code>. See docs/tailscale-acl.md in the AgentOS repository, and <a href="https://tailscale.com/kb/1068/tags" target="_blank" rel="noreferrer">Tailscale tags</a>.</p>
            <SecretField name="TS_AUTHKEY" label="Auth key (tskey-auth-…)" onSave={saveOne} />
          </div>
          <SshKeys />
          <SettingsForm title="Access and console" fields={ACCESS} values={withDefaults(s.values)} onSave={save} />
          <SettingsForm title="Desktops" fields={DESKTOPS} values={s.values} onSave={save} />
          <SettingsForm title="Web UI" fields={WEB} values={withDefaults(s.values)} onSave={save} beforeSave={webGuard} />
        </>
      )}
    </section>
  );
}
```

`web/ui/src/App.tsx` (Task 6 state: Overview and Settings; other paths fall back to Overview):
```tsx
import { api } from './api';
import { Link, usePath } from './router';
import type { Me } from './types';
import { usePoll } from './usePoll';
// Pages (one import per task):
import { Overview } from './pages/Overview';
import { Settings } from './pages/Settings';

const NAV = [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/settings', 'Settings'], ['/system', 'System']];

function page(path: string, me: Me | null) {
  const [, section, arg] = path.split('/');
  switch (section) {
    case 'settings': return <Settings me={me} />;
    default: return <Overview />;
  }
}

export function App() {
  const path = usePath();
  const { data: me } = usePoll(() => api<Me>('/api/me'));
  const section = '/' + (path.split('/')[1] ?? '');
  return (
    <div className="layout">
      <header>
        <strong>AgentOS</strong>
        <span>{me?.hostname}</span>
        <span>{me?.tailnetIp ?? 'tailnet down'}</span>
        <span className="login">{me?.login}</span>
      </header>
      <nav>
        {NAV.map(([to, label]) => <Link key={to} to={to} className={section === to ? 'active' : ''}>{label}</Link>)}
      </nav>
      <main>{page(path, me)}</main>
    </div>
  );
}
```

- [ ] **Step 5: Run tests, typecheck and build**

Run: `cd web/ui && npx vitest run && npm run build`
Expected: `Test Files  3 passed (3)` and `Tests  9 passed (9)`. Then `npm run build` (tsc, then vite) ends with `✓ built in …`, and `dist/index.html` plus `dist/assets/index-*.js` and `*.css` exist.

- [ ] **Step 6: Commit**

```bash
git add web/ui
git commit -m "feat(web): UI shell with Overview and Settings (write-only secret fields, inline agentos-config validation errors)"
```

---

### Task 7: Sessions page and terminal, Desktops page and noVNC view

**Files:**
- Create: `web/ui/src/components/{DirPicker,NewSessionForm}.tsx`, `web/ui/src/pages/{Sessions,Terminal,Desktops,DesktopView}.tsx`
- Test: `web/ui/test/NewSessionForm.test.tsx`
- Modify: `web/ui/src/App.tsx` (the imports and two `case` lines)

**Interfaces:**
- Consumes:
  - from Task 6: `api`, `wsUrl`, `navigate`, `Link`, `usePoll`, `confirmAction`, `ErrorText`, `newDesktop`, the `Session` and `Desktop` types;
  - the server's `/api/sessions*`, `/api/dirs`, `/api/sessions/:id/terminal` (WebSocket), `/api/desktops*`, `/api/desktops/:n/vnc` (WebSocket);
  - `/novnc/core/rfb.js` (the Debian package, served by the server).
- Produces:
  - routes `/sessions`, `/sessions/<id>` (terminal), `/desktops`, `/desktops/<n>` (VNC view);
  - the terminal page has a `.xterm` element and shows `attached` once the WebSocket opens. The e2e test (Task 10) relies on the Name textbox (role textbox, name "Name"), the CLI select (label "CLI"), the `Start` button, the `attached` status text and `.xterm`.

- [ ] **Step 1: Write the failing test**

`web/ui/test/NewSessionForm.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { NewSessionForm } from '../src/components/NewSessionForm';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function stubApi(created: unknown, status = 201) {
  const fetch = vi.fn(async (url: string, init?: RequestInit) =>
    url.startsWith('/api/dirs') ? json({ path: '/home/agent', parent: null, dirs: ['proj'] })
      : init?.method === 'POST' ? json(created, status) : json({}));
  vi.stubGlobal('fetch', fetch);
  return fetch;
}
const posted = (fetch: ReturnType<typeof stubApi>) => JSON.parse(fetch.mock.calls.find(([, i]) => i?.method === 'POST')![1]!.body as string);

it('starts a session in a folder picked from the tree, then opens its terminal', async () => {
  const fetch = stubApi({ id: 'ag-x' });
  render(<NewSessionForm />);
  fireEvent.change(screen.getByLabelText('CLI'), { target: { value: 'codex' } });
  fireEvent.change(screen.getByRole('textbox', { name: 'Name' }), { target: { value: 'x' } });
  fireEvent.click(await screen.findByText('proj/'));
  fireEvent.click(screen.getByText('Start'));
  await vi.waitFor(() => expect(location.pathname).toBe('/sessions/ag-x'));
  expect(posted(fetch)).toEqual({ cli: 'codex', name: 'x', dir: '/home/agent/proj' });
});

it('clones a repo instead of picking a folder, and shows server errors', async () => {
  const fetch = stubApi({ error: 'git clone failed: not found' }, 400);
  render(<NewSessionForm />);
  fireEvent.click(screen.getByLabelText(/Clone repo/));
  fireEvent.change(screen.getByLabelText('Git URL'), { target: { value: 'https://github.com/o/r.git' } });
  fireEvent.click(screen.getByText('Start'));
  expect((await screen.findByRole('alert')).textContent).toBe('git clone failed: not found');
  expect(posted(fetch)).toEqual({ cli: 'claude', repo: 'https://github.com/o/r.git' });
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd web/ui && npx vitest run test/NewSessionForm.test.tsx`
Expected: FAIL with `Failed to resolve import "../src/components/NewSessionForm"`.

- [ ] **Step 3: Implement**

`web/ui/src/components/DirPicker.tsx`:
```tsx
import { api } from '../api';
import { usePoll } from '../usePoll';
import { ErrorText } from './ErrorText';

interface Listing { path: string; parent: string | null; dirs: string[] }

// Browses folders under /home/agent (the server refuses anything outside it).
export function DirPicker({ value, onChange }: { value: string; onChange: (path: string) => void }) {
  const { data, error } = usePoll(() => api<Listing>(`/api/dirs?path=${encodeURIComponent(value)}`), 0, [value]);
  return (
    <div className="dirpicker">
      <code>{data?.path ?? value}</code>
      <ErrorText error={error} />
      <ul>
        {data?.parent && <li><button type="button" onClick={() => onChange(data.parent!)}>..</button></li>}
        {data?.dirs.map((d) => <li key={d}><button type="button" onClick={() => onChange(`${data.path}/${d}`)}>{d}/</button></li>)}
      </ul>
    </div>
  );
}
```

`web/ui/src/components/NewSessionForm.tsx`:
```tsx
import { type FormEvent, useState } from 'react';
import { api } from '../api';
import { navigate } from '../router';
import type { Session } from '../types';
import { DirPicker } from './DirPicker';
import { ErrorText } from './ErrorText';

const CLIS = ['claude', 'codex', 'grok', 'opencode', 'shell'];

export function NewSessionForm() {
  const [cli, setCli] = useState('claude');
  const [mode, setMode] = useState<'dir' | 'repo'>('dir');
  const [dir, setDir] = useState('');   // '' = the agent's home
  const [repo, setRepo] = useState('');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const body = { cli, name: name || undefined, ...(mode === 'dir' ? { dir: dir || undefined } : { repo }) };
      const s = await api<Session>('/api/sessions', 'POST', body);
      navigate(`/sessions/${encodeURIComponent(s.id)}`);
    } catch (err) {
      setError((err as Error).message);
      setBusy(false);
    }
  }

  return (
    <form className="panel" onSubmit={submit}>
      <h2>New session</h2>
      <label>CLI <select value={cli} onChange={(e) => setCli(e.target.value)}>{CLIS.map((c) => <option key={c}>{c}</option>)}</select></label>
      <label>Name <input value={name} onChange={(e) => setName(e.target.value)} placeholder={`${cli}-n`} pattern="[a-z0-9-]{1,32}" /></label>
      <fieldset>
        <label><input type="radio" checked={mode === 'dir'} onChange={() => setMode('dir')} /> Folder</label>
        <label><input type="radio" checked={mode === 'repo'} onChange={() => setMode('repo')} /> Clone repo into ~/work/&lt;name&gt;</label>
      </fieldset>
      {mode === 'dir' ? <DirPicker value={dir} onChange={setDir} />
        : <label>Git URL <input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="https://github.com/org/repo.git" required /></label>}
      <ErrorText error={error} />
      <button disabled={busy}>{busy ? 'Starting…' : 'Start'}</button>
    </form>
  );
}
```

`web/ui/src/pages/Sessions.tsx`:
```tsx
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { NewSessionForm } from '../components/NewSessionForm';
import { Link } from '../router';
import type { Session } from '../types';
import { usePoll } from '../usePoll';

export function Sessions() {
  const { data, error, reload } = usePoll(() => api<Session[]>('/api/sessions'), 5000);
  const act = (path: string, method: string) => api(path, method).then(reload, (e: Error) => alert(e.message));
  return (
    <section>
      <h1>Sessions</h1>
      <NewSessionForm />
      <ErrorText error={error} />
      <table>
        <thead><tr><th>Name</th><th>CLI</th><th>Directory</th><th>Created</th><th>Viewers</th><th>State</th><th /></tr></thead>
        <tbody>
          {data?.map((s) => (
            <tr key={s.id}>
              <td>{s.state === 'running' ? <Link to={`/sessions/${encodeURIComponent(s.id)}`}>{s.name}</Link> : s.name}</td>
              <td>{s.cli ?? '-'}</td>
              <td><code>{s.dir ?? '-'}</code></td>
              <td>{s.created ? new Date(s.created).toLocaleString() : '-'}</td>
              <td>{s.attached}</td>
              <td>{s.external ? 'external' : s.state}</td>
              <td>
                {s.state === 'running'
                  ? <button onClick={() => confirmAction(`Stop ${s.name}? Its processes are killed.`) && act(`/api/sessions/${encodeURIComponent(s.id)}/stop`, 'POST')}>Stop</button>
                  : <button onClick={() => act(`/api/sessions/${encodeURIComponent(s.id)}`, 'DELETE')}>Remove</button>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
```

`web/ui/src/pages/Terminal.tsx`:
```tsx
import { FitAddon } from '@xterm/addon-fit';
import { Terminal as Xterm } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';
import { Link } from '../router';

// Full-page terminal attached to a tmux session. Leaving the page detaches; it never kills.
export function Terminal({ id }: { id: string }) {
  const el = useRef<HTMLDivElement>(null);
  const [status, setStatus] = useState('connecting…');
  useEffect(() => {
    const term = new Xterm({ cursorBlink: true, fontSize: 14, theme: { background: '#0d1117' } });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(el.current!);
    fit.fit();
    const ws = new WebSocket(wsUrl(`/api/sessions/${encodeURIComponent(id)}/terminal?cols=${term.cols}&rows=${term.rows}`));
    ws.onopen = () => setStatus('attached');
    ws.onclose = (e) => setStatus(`closed${e.reason ? `: ${e.reason}` : ''}`);
    ws.onmessage = (e) => term.write(e.data as string);
    const input = term.onData((d) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ t: 'i', d })));
    const resize = term.onResize(({ cols, rows }) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ t: 'r', c: cols, r: rows })));
    const onWindowResize = () => fit.fit();
    addEventListener('resize', onWindowResize);
    term.focus();
    return () => {
      removeEventListener('resize', onWindowResize);
      input.dispose();
      resize.dispose();
      ws.close();
      term.dispose();
    };
  }, [id]);
  return (
    <section className="terminal-page">
      <div className="toolbar"><Link to="/sessions">← Sessions</Link><strong>{id}</strong><span>{status}</span></div>
      <div className="term-host" ref={el} />
    </section>
  );
}
```

`web/ui/src/pages/Desktops.tsx`:
```tsx
import { useEffect, useState } from 'react';
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { minutes } from '../format';
import { newDesktop } from '../quick';
import { Link } from '../router';
import type { Desktop } from '../types';
import { usePoll } from '../usePoll';

function idleText(d: Desktop): string {
  return d.idleLimitMinutes === 0 ? `idle ${minutes(d.idleSeconds)} (reaper off)` : `idle ${minutes(d.idleSeconds)} of ${d.idleLimitMinutes} min`;
}

export function Desktops() {
  const { data, error, reload } = usePoll(() => api<{ max: number; desktops: Desktop[] }>('/api/desktops'), 5000);
  const [tick, setTick] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setTick(Date.now()), 5000); return () => clearInterval(t); }, []);
  const destroy = (n: number) =>
    confirmAction(`Destroy desktop ${n}? Everything running on it is killed.`) &&
    api(`/api/desktops/${n}`, 'DELETE').then(reload, (e: Error) => alert(e.message));
  return (
    <section>
      <h1>Desktops <small>{data ? `${data.desktops.length} of ${data.max}` : ''}</small></h1>
      <div className="actions"><button onClick={newDesktop}>New desktop</button></div>
      <ErrorText error={error} />
      <div className="grid">
        {data?.desktops.map((d) => (
          <div className="card desktop" key={d.id}>
            <Link to={`/desktops/${d.id}`}><img src={`/api/desktops/${d.id}/thumbnail?t=${tick}`} alt={`desktop ${d.id}`} width={480} height={270} /></Link>
            <div className="row"><strong>Desktop {d.id}</strong><span>{idleText(d)}</span><span>{d.viewers ? `${d.viewers} viewer(s)` : 'no viewer'}</span></div>
            <div className="row"><Link to={`/desktops/${d.id}`}>Open</Link><button onClick={() => destroy(d.id)}>Destroy</button></div>
          </div>
        ))}
      </div>
    </section>
  );
}
```

`web/ui/src/pages/DesktopView.tsx`:
```tsx
import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';
import { Link } from '../router';

// The subset of noVNC's RFB class we use. The module is loaded at runtime from the Debian novnc
// package (served at /novnc/), so it is not bundled and gets Debian's security updates.
interface Rfb {
  viewOnly: boolean;
  scaleViewport: boolean;
  disconnect(): void;
  addEventListener(type: 'connect' | 'disconnect', fn: (e: Event) => void): void;
}
type RfbClass = new (target: HTMLElement, url: string, options?: { wsProtocols?: string[] }) => Rfb;
const RFB_URL = '/novnc/core/rfb.js';

export function DesktopView({ n }: { n: number }) {
  const el = useRef<HTMLDivElement>(null);
  const rfb = useRef<Rfb | null>(null);
  const [control, setControl] = useState(false);
  const [status, setStatus] = useState('connecting…');
  useEffect(() => {
    let alive = true;
    import(/* @vite-ignore */ RFB_URL).then((m: { default: RfbClass }) => {
      if (!alive) return;
      const r = new m.default(el.current!, wsUrl(`/api/desktops/${n}/vnc`), { wsProtocols: ['binary'] });
      r.viewOnly = true;
      r.scaleViewport = true;
      r.addEventListener('connect', () => setStatus('connected'));
      r.addEventListener('disconnect', () => setStatus('disconnected'));
      rfb.current = r;
    }, (e: Error) => setStatus(`noVNC failed to load: ${e.message}`));
    return () => { alive = false; rfb.current?.disconnect(); rfb.current = null; };
  }, [n]);
  useEffect(() => { if (rfb.current) rfb.current.viewOnly = !control; }, [control, status]);
  return (
    <section className="desktop-page">
      <div className="toolbar">
        <Link to="/desktops">← Desktops</Link><strong>Desktop {n}</strong><span>{status}</span>
        <label><input type="checkbox" checked={control} onChange={(e) => setControl(e.target.checked)} /> Take control</label>
        <button onClick={() => el.current?.requestFullscreen()}>Full screen</button>
      </div>
      <div className="vnc" ref={el} />
    </section>
  );
}
```

In `web/ui/src/App.tsx`, add these lines under `// Pages (one import per task):`:
```tsx
import { Sessions } from './pages/Sessions';
import { Terminal } from './pages/Terminal';
import { Desktops } from './pages/Desktops';
import { DesktopView } from './pages/DesktopView';
```
and these lines in `page()`, after `case 'settings': …`:
```tsx
    case 'sessions': return arg ? <Terminal id={decodeURIComponent(arg)} /> : <Sessions />;
    case 'desktops': return arg ? <DesktopView n={Number(arg)} /> : <Desktops />;
```

- [ ] **Step 4: Run tests and build**

Run: `cd web/ui && npx vitest run && npm run build`
Expected: `Test Files  4 passed (4)` and `Tests  11 passed (11)`, and the build succeeds. Also run `grep -c "novnc/core/rfb.js" dist/assets/*.js`: it should print `1`. The noVNC module is loaded at runtime, not bundled.

- [ ] **Step 5: Commit**

```bash
git add web/ui
git commit -m "feat(web): Sessions page with folder picker and repo clone, xterm.js terminal, Desktops grid and noVNC view"
```

---

### Task 8: System page

**Files:**
- Create: `web/ui/src/components/{LogStream,Services,Power}.tsx`, `web/ui/src/pages/System.tsx`
- Test: `web/ui/test/Power.test.tsx`
- Modify: `web/ui/src/App.tsx` (the import and the `case` line)

**Interfaces:**
- Consumes: from Task 6, `api`, `wsUrl`, `usePoll`, `confirmAction`, `ErrorText`, `openTerminal`, the `Me` and `Unit` types. From the server: `/api/system/services`, `/api/system/services/:unit/restart`, the `/api/system/journal?unit=` and `/api/system/update` WebSockets, `/api/system/updates`, and `/api/system/power`.
- Produces: the route `/system`; `<LogStream path>`, a reusable WebSocket text viewer.

- [ ] **Step 1: Write the failing test**

`web/ui/test/Power.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Power } from '../src/components/Power';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

it('enables Reboot and Power off only once the hostname is typed, and sends it as confirmation', async () => {
  const fetch = vi.fn(async () => new Response('{"ok":true}', { headers: { 'content-type': 'application/json' } }));
  vi.stubGlobal('fetch', fetch);
  render(<Power hostname="box1" />);
  const reboot = screen.getByText('Reboot') as HTMLButtonElement;
  expect(reboot.disabled).toBe(true);
  expect((screen.getByText('Power off') as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'box' } });
  expect(reboot.disabled).toBe(true);
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'box1' } });
  fireEvent.click(reboot);
  await vi.waitFor(() => expect(fetch).toHaveBeenCalled());
  expect(fetch.mock.calls[0]).toEqual(['/api/system/power', expect.objectContaining({ method: 'POST', body: '{"action":"reboot","confirm":"box1"}' })]);
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd web/ui && npx vitest run test/Power.test.tsx`
Expected: FAIL with `Failed to resolve import "../src/components/Power"`.

- [ ] **Step 3: Implement**

`web/ui/src/components/LogStream.tsx`:
```tsx
import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';

// Streams a WebSocket's text frames into a scrolling <pre>; closes the socket on unmount.
export function LogStream({ path }: { path: string }) {
  const [text, setText] = useState('');
  const pre = useRef<HTMLPreElement>(null);
  useEffect(() => {
    setText('');
    const ws = new WebSocket(wsUrl(path));
    ws.onmessage = (e) => setText((t) => (t + (e.data as string)).slice(-200_000));
    ws.onclose = (e) => { if (e.reason) setText((t) => `${t}\n[${e.reason}]`); };
    return () => ws.close();
  }, [path]);
  useEffect(() => { pre.current?.scrollTo(0, pre.current.scrollHeight); }, [text]);
  return <pre className="log" ref={pre}>{text}</pre>;
}
```

`web/ui/src/components/Services.tsx`:
```tsx
import { api } from '../api';
import type { Unit } from '../types';
import { usePoll } from '../usePoll';
import { confirmAction } from './Confirm';
import { ErrorText } from './ErrorText';

export function Services({ onLogs }: { onLogs: (unit: string) => void }) {
  const { data, error, reload } = usePoll(() => api<Unit[]>('/api/system/services'), 10000);
  const restart = (u: string) =>
    confirmAction(`Restart ${u}?`) && api(`/api/system/services/${encodeURIComponent(u)}/restart`, 'POST').then(reload, (e: Error) => alert(e.message));
  return (
    <div className="panel">
      <h2>Services</h2>
      <ErrorText error={error} />
      <table>
        <tbody>
          {data?.map((u) => (
            <tr key={u.unit}>
              <td><code>{u.unit}</code></td>
              <td className={u.active === 'active' ? 'ok' : u.active === 'failed' ? 'bad' : ''}>{u.active} ({u.sub})</td>
              <td>{u.description}</td>
              <td><button onClick={() => onLogs(u.unit)}>Logs</button> <button onClick={() => restart(u.unit)}>Restart</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
```

`web/ui/src/components/Power.tsx`:
```tsx
import { useState } from 'react';
import { api } from '../api';
import { ErrorText } from './ErrorText';

// Reboot / power off: enabled only once the hostname is typed (the server checks it again).
export function Power({ hostname }: { hostname: string }) {
  const [typed, setTyped] = useState('');
  const [error, setError] = useState<string | null>(null);
  const go = (action: string) => api('/api/system/power', 'POST', { action, confirm: typed }).then(
    () => setError(`${action} requested`), (e: Error) => setError(e.message));
  const ok = typed === hostname;
  return (
    <div className="panel">
      <h2>Power</h2>
      <label>Type <code>{hostname}</code> to confirm <input value={typed} onChange={(e) => setTyped(e.target.value)} /></label>
      <button disabled={!ok} onClick={() => go('reboot')}>Reboot</button>
      <button disabled={!ok} onClick={() => go('poweroff')}>Power off</button>
      <ErrorText error={error} />
    </div>
  );
}
```

`web/ui/src/pages/System.tsx`:
```tsx
import { useState } from 'react';
import { api } from '../api';
import { LogStream } from '../components/LogStream';
import { Power } from '../components/Power';
import { Services } from '../components/Services';
import { openTerminal } from '../quick';
import type { Me } from '../types';
import { usePoll } from '../usePoll';

export function System({ me }: { me: Me | null }) {
  const [unit, setUnit] = useState<string | null>(null);
  const [updating, setUpdating] = useState(0);
  const updates = usePoll(() => api<{ lastUnattended: string | null }>('/api/system/updates'));
  return (
    <section>
      <h1>System</h1>
      <div className="actions"><button onClick={openTerminal}>Open terminal</button></div>
      <Services onLogs={setUnit} />
      {unit && (
        <div className="panel">
          <h2>Journal: <code>{unit}</code> <button onClick={() => setUnit(null)}>Close</button></h2>
          <LogStream path={`/api/system/journal?unit=${encodeURIComponent(unit)}`} />
        </div>
      )}
      <div className="panel">
        <h2>Updates</h2>
        <p>Last unattended-upgrades run: {updates.data?.lastUnattended ? new Date(updates.data.lastUnattended).toLocaleString() : 'never'}</p>
        <button onClick={() => setUpdating((n) => n + 1)}>Run agentos-update</button>
        {updating > 0 && <LogStream key={updating} path="/api/system/update" />}
      </div>
      {me && <Power hostname={me.hostname} />}
    </section>
  );
}
```

In `web/ui/src/App.tsx`, add `import { System } from './pages/System';` under `// Pages (one import per task):`, and `    case 'system': return <System me={me} />;` in `page()` before `default:`. `App.tsx` should now match this final form exactly:
```tsx
import { api } from './api';
import { Link, usePath } from './router';
import type { Me } from './types';
import { usePoll } from './usePoll';
// Pages (one import per task):
import { Overview } from './pages/Overview';
import { Settings } from './pages/Settings';
import { Sessions } from './pages/Sessions';
import { Terminal } from './pages/Terminal';
import { Desktops } from './pages/Desktops';
import { DesktopView } from './pages/DesktopView';
import { System } from './pages/System';

const NAV = [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/settings', 'Settings'], ['/system', 'System']];

function page(path: string, me: Me | null) {
  const [, section, arg] = path.split('/');
  switch (section) {
    case 'settings': return <Settings me={me} />;
    case 'sessions': return arg ? <Terminal id={decodeURIComponent(arg)} /> : <Sessions />;
    case 'desktops': return arg ? <DesktopView n={Number(arg)} /> : <Desktops />;
    case 'system': return <System me={me} />;
    default: return <Overview />;
  }
}

export function App() {
  const path = usePath();
  const { data: me } = usePoll(() => api<Me>('/api/me'));
  const section = '/' + (path.split('/')[1] ?? '');
  return (
    <div className="layout">
      <header>
        <strong>AgentOS</strong>
        <span>{me?.hostname}</span>
        <span>{me?.tailnetIp ?? 'tailnet down'}</span>
        <span className="login">{me?.login}</span>
      </header>
      <nav>
        {NAV.map(([to, label]) => <Link key={to} to={to} className={section === to ? 'active' : ''}>{label}</Link>)}
      </nav>
      <main>{page(path, me)}</main>
    </div>
  );
}
```

- [ ] **Step 4: Run tests and build**

Run: `cd web/ui && npx vitest run && npm run build`
Expected: `Test Files  5 passed (5)` and `Tests  12 passed (12)`, and the build succeeds.

- [ ] **Step 5: Commit**

```bash
git add web/ui
git commit -m "feat(web): System page: services with restart and live journal, agentos-update with live output, power with hostname confirmation"
```

---

### Task 9: Image integration: build step, `agentos-web.service`, `tailscale serve`, size

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/web-serve` (mode 755), `mkosi.extra/etc/systemd/system/agentos-web.service`
- Test: `test/web_serve_test.sh` (mode 755), `test/checks/96-web.sh` (new; Task 10 appends to it)
- Modify: `mkosi.prepare.chroot` (append the web build), `mkosi.finalize.chroot` (manifest + invariants)
- Modify: `mkosi.extra/usr/local/sbin/agentos-firstboot` (step 5b gains serve, enable/disable and the console note)
- Modify: `docs/tailscale-acl.md` (port 443, HTTPS certificates)

**Interfaces:**
- Consumes:
  - the `web/server` and `web/ui` packages (their `npm ci` / `npm run build` scripts and `dist/` outputs);
  - Task 2's step 5b variables `wu` and `we` in firstboot;
  - the existing preset `enable agentos-*.service`, which enables the new unit at build time.
- Produces:
  - `/usr/local/lib/agentos/web/{server/{dist,node_modules,package.json},ui/}`;
  - `agentos-web.service` (`User=agent`, `SyslogIdentifier=agentos-web`, `KillMode=process`);
  - `web-serve 1|0`, which prints `ok|off|tailscale-down|failed: …` and always exits 0;
  - `web.conf` gains `SERVE=`;
  - `/run/issue.d/50-agentos-web.issue` on a serve failure;
  - manifest lines `# agentos-web npm` / `name@version`.

- [ ] **Step 1: Write the failing tests**

`test/web_serve_test.sh`:
```bash
#!/bin/bash
# Unit test for web-serve (the firstboot `tailscale serve` step) against a fake tailscale.
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)/mkosi.extra/usr/local/lib/agentos/web-serve
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/tailscale" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$FAKE_MODE:$1" in
  down:status) exit 1 ;;
  nohttps:serve) [ "$2" = --bg ] && { echo "Serve is not enabled on your tailnet."; echo "To enable, visit: https://login.tailscale.com/f/serve?node=x"; exit 1; } ;;
  hang:serve) [ "$2" = --bg ] && { echo "To enable, visit: https://login.tailscale.com/f/serve?node=y"; sleep 30; } ;;
esac
exit 0
FAKE
chmod +x "$d/tailscale"
export TAILSCALE=$d/tailscale FAKE_LOG=$d/log WEB_SERVE_TIMEOUT=2
run() { : > "$d/log"; FAKE_MODE=$1 "$S" "$2"; }

[ "$(run up 1)" = ok ]
grep -qx 'serve --bg --https=443 http://127.0.0.1:7070' "$d/log"
[ "$(run up 0)" = off ]
grep -qx 'serve --https=443 off' "$d/log"
[ "$(run down 1)" = tailscale-down ]
if grep -q '^serve' "$d/log"; then echo 'serve ran while tailscale was down' >&2; exit 1; fi
out=$(run nohttps 1); [[ $out == 'failed: Serve is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/serve?node=x' ]] || { echo "got: $out" >&2; exit 1; }
out=$(run hang 1); [[ $out == 'failed: To enable, visit: https://login.tailscale.com/f/serve?node=y'* ]] || { echo "got: $out" >&2; exit 1; }
echo "web-serve OK"
```

`test/checks/96-web.sh`:
```bash
# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.
check_web_service_loopback_only() {
  vm 'systemctl is-active --quiet agentos-web.service &&
      test "$(ss -Htln "sport = :7070" | awk "{print \$4}")" = 127.0.0.1:7070'
}
check_web_unit_shape() {
  vm 'for p in User=agent KillMode=process NoNewPrivileges=no PrivateTmp=no ProtectHome=no Restart=on-failure SyslogIdentifier=agentos-web; do
        test "$(systemctl show agentos-web.service -p "${p%%=*}" --value)" = "${p#*=}" || { echo "want $p"; exit 1; }
      done'
}
check_web_conf_published() {
  # No tailnet in the smoke VM: serve is skipped, and no console warning is shown.
  vm 'test "$(stat -c %a /etc/agentos/web.conf)" = 644 && grep -qx ENABLED=1 /etc/agentos/web.conf &&
      grep -qx SERVE=tailscale-down /etc/agentos/web.conf && test ! -e /run/issue.d/50-agentos-web.issue'
}
check_web_disable_and_enable() {
  local rc=0
  vm 'sudo agentos-config set AGENTOS_WEB 0 && sudo agentos-config apply &&
      for _ in $(seq 1 30); do systemctl is-active --quiet agentos-web.service || break; sleep 1; done &&
      ! systemctl is-active --quiet agentos-web.service && ! systemctl is-enabled --quiet agentos-web.service &&
      grep -qx ENABLED=0 /etc/agentos/web.conf && grep -qx SERVE=off /etc/agentos/web.conf' || rc=1
  vm 'sudo agentos-config set AGENTOS_WEB 1 && sudo agentos-config apply &&
      for _ in $(seq 1 30); do systemctl is-active --quiet agentos-web.service && exit 0; sleep 1; done; exit 1' || rc=1
  return "$rc"
}
check_web_size() {
  local mb; mb=$(vm 'du -sm /usr/local/lib/agentos/web | cut -f1')
  echo "web UI: ${mb} MiB (spec budget: +60-100 MB)"; [ "$mb" -le 100 ]
}
check_manifest_lists_web() {
  vm 'grep -qx "# agentos-web npm" /var/lib/agentos-manifest.txt && grep -qx "fastify@5.12.7" /var/lib/agentos-manifest.txt'
}
noseed_web_active() { qga 'systemctl is-active agentos-web.service'; }
```

- [ ] **Step 2: Run the unit test to confirm it fails**

Run: `chmod +x test/web_serve_test.sh && .superpowers/sdd/devvm.sh sh 'test/web_serve_test.sh'`
Expected: FAIL. `web-serve` doesn't exist yet, so the first `[ "$(run up 1)" = ok ]` fails (`No such file or directory`).

- [ ] **Step 3: Implement `web-serve` and the unit**

`mkosi.extra/usr/local/lib/agentos/web-serve`:
```bash
#!/bin/bash
# web-serve 1|0: publish the web UI on the tailnet with `tailscale serve` (1), or withdraw it (0).
# Prints one status line for web.conf's SERVE=: ok | off | tailscale-down | failed: <why>.
# Always exits 0: a tailnet without HTTPS certificates must not fail agentos-firstboot.
set -euo pipefail
TS=${TAILSCALE:-tailscale}
T=${WEB_SERVE_TIMEOUT:-30}

if [ "${1:-1}" = 0 ]; then
  timeout "$T" "$TS" serve --https=443 off >/dev/null 2>&1 || true
  echo off
  exit 0
fi
if ! timeout "$T" "$TS" status >/dev/null 2>&1; then
  echo tailscale-down
  exit 0
fi
# Without HTTPS enabled on the tailnet, `tailscale serve` prints an enable-link and waits: the
# timeout turns that into a failure whose message carries the link.
if out=$(timeout "$T" "$TS" serve --bg --https=443 http://127.0.0.1:7070 2>&1 </dev/null); then
  echo ok
else
  echo "failed: $(printf '%s' "$out" | tr -s '\n\t' '  ' | cut -c1-200)"
fi
```

`mkosi.extra/etc/systemd/system/agentos-web.service`:
```ini
[Unit]
Description=AgentOS web UI (127.0.0.1:7070, published on the tailnet by tailscale serve)
After=network.target agentos-firstboot.service

[Service]
User=agent
WorkingDirectory=/home/agent
Environment=LANG=C.UTF-8
ExecStart=/usr/bin/node /usr/local/lib/agentos/web/server/dist/main.js
SyslogIdentifier=agentos-web
Restart=on-failure
RestartSec=2
# ponytail: sessions are tmux servers this service may have started, inside its cgroup; a restart
# must not kill them. systemd warns that KillMode=process is unsafe; move tmux into its own scope
# (systemd-run --user --scope with lingering) if leftover processes ever become a problem.
KillMode=process
# Deliberately light hardening: sudo needs NoNewPrivileges off, sessions live in /home/agent, and
# the tmux socket is /tmp/tmux-1000.
NoNewPrivileges=no
ProtectHome=no
PrivateTmp=no

[Install]
WantedBy=multi-user.target
```

Run: `chmod +x mkosi.extra/usr/local/lib/agentos/web-serve && .superpowers/sdd/devvm.sh sh 'test/web_serve_test.sh && shellcheck -S warning test/web_serve_test.sh mkosi.extra/usr/local/lib/agentos/web-serve test/checks/96-web.sh'`
Expected: `web-serve OK` (in about 2 s; the hang case times out after `WEB_SERVE_TIMEOUT=2`), and no shellcheck output.

- [ ] **Step 4: Firstboot: serve, enable or disable, console note**

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, step 5b (added in Task 2). Replace:
```bash
printf 'USERS=%s\nENABLED=%s\n' "$wu" "$we" > /etc/agentos/web.conf.tmp
chmod 644 /etc/agentos/web.conf.tmp
mv /etc/agentos/web.conf.tmp /etc/agentos/web.conf
```

with:
```bash
# Publish it on the tailnet (web-serve prints ok | off | tailscale-down | failed: <why>), then
# start or stop the unit. --no-block: agentos-web is ordered after this unit, so waiting would deadlock.
ws=$(/usr/local/lib/agentos/web-serve "$we")
printf 'USERS=%s\nENABLED=%s\nSERVE=%s\n' "$wu" "$we" "$ws" > /etc/agentos/web.conf.tmp
chmod 644 /etc/agentos/web.conf.tmp
mv /etc/agentos/web.conf.tmp /etc/agentos/web.conf
if [ "$we" = 1 ]; then
  systemctl enable --quiet agentos-web.service
  systemctl start --no-block agentos-web.service
else
  systemctl disable --quiet --now --no-block agentos-web.service
fi
# Say why on the console too: agetty prints /run/issue.d/*.issue after /etc/issue.
if [[ $ws == failed* ]]; then
  install -d /run/issue.d
  printf 'Web UI: tailscale serve %s\n\n' "$ws" > /run/issue.d/50-agentos-web.issue
else
  rm -f /run/issue.d/50-agentos-web.issue
fi
```

- [ ] **Step 5: Build the web UI into the image**

Append to `mkosi.prepare.chroot`:
```bash

# AgentOS web UI (web/): built here because prepare scripts have network access. Only the build
# output and production node_modules land in /usr/local/lib/agentos/web; node-pty compiles against
# this image's Node with node-gyp (build-essential, python3). HOME points into the scratch dir so the
# npm and node-gyp caches never land in /root. Host node_modules/dist are excluded: a macOS checkout
# must not leak darwin binaries into the image.
W=/usr/local/lib/agentos/web
wb=$(mktemp -d)
tar -C "$SRCDIR/web" --exclude=node_modules --exclude=dist -cf - . | tar -C "$wb" -xf -
# shellcheck disable=SC2016 # $HOME expands in the inner shell, which runs with HOME=$wb
HOME=$wb bash -euo pipefail -c '
  cd "$HOME/ui" && npm ci --no-audit --no-fund && npm run build
  cd "$HOME/server" && npm ci --no-audit --no-fund && npm run build && npm prune --omit=dev --no-audit --no-fund
  # node-pty also ships Windows/macOS prebuilds and its C++ sources; Linux loads build/Release only.
  rm -rf node_modules/node-pty/prebuilds node_modules/node-pty/third_party node_modules/node-pty/deps node_modules/node-pty/src'
rm -rf "$W"
install -d "$W/server"
cp -a "$wb/server/dist" "$wb/server/node_modules" "$wb/server/package.json" "$W/server/"
cp -a "$wb/ui/dist" "$W/ui"
rm -rf "$wb"
```

In `mkosi.finalize.chroot`, add the web packages to the manifest right after the `# agentos-computer python` line:
```bash
{ echo "# agentos-web npm"; node -e '
    const d = "/usr/local/lib/agentos/web/server";
    for (const n of Object.keys(require(d + "/package.json").dependencies))
      console.log(n + "@" + require(d + "/node_modules/" + n + "/package.json").version);'; } >> /var/lib/agentos-manifest.txt
```
and add these invariants directly above `echo "image invariants OK"`:
```bash
W=/usr/local/lib/agentos/web
for f in "$W/server/dist/main.js" "$W/ui/index.html" "$W/server/node_modules/node-pty/build/Release/pty.node"; do
  if [ ! -f "$f" ]; then fail "web UI build output missing: $f"; fi
done
if [ -e "$W/server/node_modules/typescript" ] || [ -e "$W/server/node_modules/vitest" ]; then fail "web UI dev dependencies shipped"; fi
```

In `docs/tailscale-acl.md`, replace `"dst": ["tag:agentos:22,6080,8765"]` with `"dst": ["tag:agentos:22,443,6080,8765"]`, and add this paragraph after the policy block:

```markdown
Port 443 is the web UI (`tailscale serve`, see below). It needs HTTPS certificates enabled for the tailnet (admin console → DNS → HTTPS Certificates). If they're off, `agentos-firstboot` logs a warning, `/etc/agentos/web.conf` says `SERVE=failed: …`, and the login banner shows the reason. Allow users into the web UI with `sudo agentos-config set AGENTOS_WEB_USERS you@example.com && sudo agentos-config apply`. Requests from tagged devices carry no identity, so they are always refused.
```

- [ ] **Step 6: Build and run the in-VM checks, including the size budget**

```bash
.superpowers/sdd/devvm.sh run 'shellcheck -S warning mkosi.prepare.chroot mkosi.finalize.chroot mkosi.extra/usr/local/sbin/agentos-firstboot && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi uefi-noseed'
.superpowers/sdd/devvm.sh wait <JOB>   # repeat until the exit code is not 124
```
Expected:
- the build log contains `image invariants OK`;
- these PASS: `check_web_service_loopback_only`, `check_web_unit_shape`, `check_web_conf_published`, `check_web_disable_and_enable`, `check_web_size` (the output line reads `web UI: <n> MiB`, with n about 26), `check_manifest_lists_web`, `noseed_web_active`;
- `check_root_size_budget` still PASSes. Report its `root used: … MiB` line next to the last value known before this plan;
- the run ends with `ALL CHECKS PASSED`.

If `npm ci` fails inside the build because node-gyp can't download Node headers, check the build log. Then set `npm_config_nodedir=/usr` in the `HOME=$wb bash -c` environment (NodeSource ships headers in `/usr/include/node`), and report the deviation.

- [ ] **Step 7: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/web-serve mkosi.extra/etc/systemd/system/agentos-web.service \
  mkosi.extra/usr/local/sbin/agentos-firstboot mkosi.prepare.chroot mkosi.finalize.chroot docs/tailscale-acl.md \
  test/web_serve_test.sh test/checks/96-web.sh
git commit -m "feat(web): build the web UI into the image, agentos-web.service, tailscale serve at first boot"
```

---

### Task 10: In-VM API, terminal, desktop and e2e checks, plus CI

**Files:**
- Create: `test/web_ws.mjs`, `test/web_e2e.mjs`
- Modify: `test/checks/96-web.sh` (append), `.github/workflows/build.yml`

**Interfaces:**
- Consumes:
  - the image from Task 9;
  - `ws` from `/usr/local/lib/agentos/web/server/node_modules`;
  - the global Playwright at `~/.local/lib/node_modules/playwright` (installed by `mkosi.prepare.chroot`);
  - the UI hooks named in Task 7 (Name textbox, CLI select, `Start`, `attached`, `.xterm`);
  - `HERE`, `vm`, `qga` from `test/smoke.sh`.
- Produces: smoke checks for every in-VM item in spec section 5, and CI running the web unit tests and the `web-serve` test.

- [ ] **Step 1: Write the checks**

Append to `test/checks/96-web.sh`:
```bash

# API checks. $WEB is prepended to remote commands: U = base URL, w = authenticated curl, wm = w plus
# the CSRF headers a browser sends on a mutating request, code = HTTP status only, up = wait for 200.
WEB='U=http://127.0.0.1:7070
w()    { curl -sS -m 120 -H "Tailscale-User-Login: smoke@example.com" "$@"; }
wm()   { w -H "Origin: http://127.0.0.1:7070" -H "X-AgentOS: 1" -H "Content-Type: application/json" "$@"; }
code() { curl -s -o /dev/null -m 30 -w "%{http_code}" "$@"; }
up()   { for _ in $(seq 1 30); do test "$(code -H "Tailscale-User-Login: smoke@example.com" $U/api/sessions)" = 200 && return 0; sleep 1; done; return 1; }
'
web_users() {  # allowlist smoke@example.com; idempotent, because apply is slow
  vm 'grep -qx "USERS=smoke@example.com" /etc/agentos/web.conf ||
      { sudo agentos-config set AGENTOS_WEB_USERS smoke@example.com && sudo agentos-config apply; }' &&
  vm "$WEB"'up'
}
check_web_identity_codes() {
  web_users && vm "$WEB"'
    test "$(code $U/api/sessions)" = 401 &&
    test "$(code -H "Tailscale-User-Login: eve@example.com" $U/api/sessions)" = 403 &&
    test "$(code -H "Tailscale-User-Login: Smoke@Example.COM" $U/api/sessions)" = 200 &&
    test "$(code -H "Tailscale-User-Login: smoke@example.com" -H "Host: evil.example:7070" $U/api/sessions)" = 403'
}
check_web_csrf() {
  web_users && vm "$WEB"'
    L="Tailscale-User-Login: smoke@example.com"
    test "$(code -X POST -H "$L" -H "Origin: $U" $U/api/desktops)" = 403 &&
    test "$(code -X POST -H "$L" -H "X-AgentOS: 1" -H "Origin: https://evil.example" $U/api/desktops)" = 403 &&
    test "$(code -X POST -H "$L" -H "X-AgentOS: 1" $U/api/desktops)" = 403'
}
check_web_not_configured_page() {
  local rc=0
  vm "$WEB"'sudo agentos-config set AGENTOS_WEB_USERS "" && sudo agentos-config apply &&
    test "$(code -H "Tailscale-User-Login: smoke@example.com" $U/api/sessions)" = 403 &&
    w $U/ | grep -q "sudo agentos-config set AGENTOS_WEB_USERS smoke@example.com"' || rc=1
  web_users || rc=1
  return "$rc"
}
check_web_session_terminal() {
  # Create via the API, type through the terminal WebSocket, survive a service restart
  # (KillMode=process), stop (sidecar stays, marked ended), remove.
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" && vm "$WEB"'
    wm -X POST -d "{\"cli\":\"shell\",\"name\":\"smoke\"}" $U/api/sessions | grep -q "\"id\":\"ag-smoke\"" &&
    tmux has-session -t =ag-smoke &&
    node /tmp/web_ws.mjs term ag-smoke "echo smoke-\$((40+2))" smoke-42 &&
    tmux has-session -t =ag-smoke &&
    sudo systemctl restart agentos-web.service && up && tmux has-session -t =ag-smoke &&
    wm -X POST $U/api/sessions/ag-smoke/stop | grep -q "\"ok\":true" &&
    ! tmux has-session -t =ag-smoke 2>/dev/null &&
    w $U/api/sessions | grep -q "\"id\":\"ag-smoke\"[^}]*\"state\":\"ended\"" &&
    wm -X DELETE $U/api/sessions/ag-smoke | grep -q "\"ok\":true"'
}
check_web_desktop_thumbnail_vnc_destroy() {
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" && vm "$WEB"'
    n=$(wm -X POST $U/api/desktops | sed -n "s/.*\"id\":\([0-9]*\).*/\1/p") && test -n "$n" &&
    systemctl is-active --quiet "agentos-desktop@$n.service" &&
    w -o /tmp/thumb.png "$U/api/desktops/$n/thumbnail" &&
    python3 -c "import struct; d=open(\"/tmp/thumb.png\",\"rb\").read(); assert d[:8]==b\"\x89PNG\r\n\x1a\n\"; assert struct.unpack(\">II\", d[16:24])==(480,270), d[16:24]" &&
    node /tmp/web_ws.mjs vnc "$n" &&
    wm -X DELETE "$U/api/desktops/$n" | grep -q "\"ok\":true" &&
    ! systemctl is-active --quiet "agentos-desktop@$n.service"'
}
check_web_settings_roundtrip_and_secrets() {
  local rc=0
  web_users && vm "$WEB"'
    wm -X PUT -d "{\"values\":{\"AGENTOS_MAX_DESKTOPS\":\"6\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    w $U/api/settings | grep -q "\"AGENTOS_MAX_DESKTOPS\":\"6\"" &&
    wm -X PUT -d "{\"values\":{\"AGENTOS_MAX_DESKTOPS\":\"99\"}}" $U/api/settings | grep -q "\"field\":\"AGENTOS_MAX_DESKTOPS\"" &&
    wm -X PUT -d "{\"values\":{\"GROK_CODE_XAI_API_KEY\":\"sk-smoke-SECRET-7\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    grep -qx GROK_CODE_XAI_API_KEY=sk-smoke-SECRET-7 ~/.config/agentos/secrets.env &&
    s=$(w $U/api/settings) && echo "$s" | grep -q "\"GROK_CODE_XAI_API_KEY\":true" && ! echo "$s" | grep -q sk-smoke &&
    ! sudo journalctl -b --no-pager | grep -q sk-smoke-SECRET-7 &&
    wm -X PUT -d "{\"values\":{\"GROK_CODE_XAI_API_KEY\":\"\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    w $U/api/settings | grep -q "\"GROK_CODE_XAI_API_KEY\":false"' || rc=1
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 8 && sudo agentos-config apply' || rc=1
  return "$rc"
}
check_web_audit_line() {
  web_users && vm "$WEB"'
    wm -X PUT -d "{\"values\":{\"AGENTOS_DESKTOP_IDLE_MINUTES\":\"120\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    for _ in 1 2 3 4 5; do
      sudo journalctl -b -t agentos-web -p notice --no-pager -o cat |
        grep -qx "smoke@example.com config-set AGENTOS_DESKTOP_IDLE_MINUTES" && exit 0
      sleep 1
    done; exit 1'
}
check_web_e2e() {
  web_users && vm 'cat > /tmp/web_e2e.mjs' < "$HERE/web_e2e.mjs" &&
  vm 'LOGIN=smoke@example.com PLAYWRIGHT=$HOME/.local/lib/node_modules/playwright node /tmp/web_e2e.mjs'
}
```

- [ ] **Step 2: Run them before the probes exist, to see them fail**

Check files are read from the host, so the Task 9 image is reused without a rebuild:
```bash
.superpowers/sdd/devvm.sh run 'shellcheck -S warning test/checks/96-web.sh && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi'
.superpowers/sdd/devvm.sh wait <JOB>   # repeat until the exit code is not 124
```
Expected:
- FAIL: `check_web_session_terminal`, `check_web_desktop_thumbnail_vnc_destroy` and `check_web_e2e`, each with `…/test/web_ws.mjs: No such file or directory` (or `web_e2e.mjs`).
- PASS: `check_web_identity_codes`, `check_web_csrf`, `check_web_not_configured_page`, `check_web_settings_roundtrip_and_secrets` and `check_web_audit_line`. Their logic is unit-tested in Tasks 1–2; here they prove the deployed service behaves the same.

- [ ] **Step 3: Write the probes**

`test/web_ws.mjs`:
```js
// In-VM WebSocket probe for the web UI, using the ws package shipped with the server.
//   node web_ws.mjs term <session-id> <text-to-type> <expected-output>
//   node web_ws.mjs vnc <desktop-number>        (expects the VNC server's "RFB 003.008" banner)
// Prints "WS OK" and exits 0 once the expected text arrives; exits 1 on close, HTTP error or timeout.
import { createRequire } from 'node:module';
const require = createRequire('/usr/local/lib/agentos/web/server/');
const WebSocket = require('ws');
const [mode, target, typed, expected] = process.argv.slice(2);
const path = mode === 'term' ? `/api/sessions/${target}/terminal?cols=80&rows=24` : `/api/desktops/${target}/vnc`;
const want = mode === 'term' ? expected : 'RFB 003.008';
const ws = new WebSocket(`ws://127.0.0.1:7070${path}`, {
  headers: { 'Tailscale-User-Login': process.env.LOGIN ?? 'smoke@example.com', Origin: 'http://127.0.0.1:7070' },
});
let got = '';
const bail = (why) => { console.error(`WS FAIL: ${why}; got ${JSON.stringify(got.slice(-300))}`); process.exit(1); };
setTimeout(() => bail('timeout'), 20000);
ws.on('unexpected-response', (_req, res) => bail(`HTTP ${res.statusCode}`));
ws.on('close', (code, reason) => bail(`closed ${code} ${reason}`));
ws.on('open', () => { if (mode === 'term') setTimeout(() => ws.send(JSON.stringify({ t: 'i', d: `${typed}\r` })), 1000); });
ws.on('message', (d) => {
  got += d.toString('latin1');
  if (got.includes(want)) { console.log('WS OK'); process.exit(0); }
});
```

`test/web_e2e.mjs`:
```js
// E2E: headless Chromium against the web UI, identity header injected like tailscale serve would.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT ?? 'playwright');
const BASE = process.env.BASE ?? 'http://127.0.0.1:7070';
const LOGIN = process.env.LOGIN ?? 'e2e@example.com';
const NAME = `e2e-${process.pid}`;
const fail = (m) => { console.error(`E2E FAIL: ${m}`); process.exit(1); };

const browser = await chromium.launch();
const ctx = await browser.newContext({ extraHTTPHeaders: { 'Tailscale-User-Login': LOGIN } });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
for (const [path, heading] of [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/settings', 'Settings'], ['/system', 'System']]) {
  await page.goto(BASE + path);
  await page.getByRole('heading', { level: 1, name: heading }).waitFor({ timeout: 15000 }).catch(() => fail(`${path}: no "${heading}" heading`));
}
await page.goto(BASE + '/sessions');
await page.getByLabel('CLI').selectOption('shell');
await page.getByRole('textbox', { name: 'Name' }).fill(NAME);
await page.getByRole('button', { name: 'Start' }).click();
await page.waitForURL(`**/sessions/ag-${NAME}`, { timeout: 15000 }).catch(async () => fail('no terminal page: ' + await page.locator('.error').allTextContents()));
await page.getByText('attached').waitFor({ timeout: 15000 }).catch(() => fail('terminal never attached'));
await page.locator('.xterm').click();
await page.keyboard.type('echo e2e-$((6*7))');
await page.keyboard.press('Enter');
await page.locator('.xterm-rows', { hasText: 'e2e-42' }).waitFor({ timeout: 15000 }).catch(() => fail('typed command output not seen'));
if (errors.length) fail(`page errors: ${errors.join('; ')}`);
for (const [method, path] of [['post', `/api/sessions/ag-${NAME}/stop`], ['delete', `/api/sessions/ag-${NAME}`]]) {
  const r = await page.request[method](BASE + path, { headers: { 'X-AgentOS': '1', Origin: BASE } });
  if (!r.ok()) fail(`cleanup ${method} ${path}: ${r.status()}`);
}
await browser.close();
console.log('E2E OK');
```

- [ ] **Step 4: Run the full suite**

```bash
.superpowers/sdd/devvm.sh run 'TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed'
.superpowers/sdd/devvm.sh wait <JOB>   # repeat until the exit code is not 124
```
Expected:
- these PASS in both `uefi` and `bios`: every `check_web_*` above (`check_web_e2e` prints `E2E OK`; `check_web_session_terminal` proves the session survives `systemctl restart agentos-web`);
- `noseed_web_active` passes in `uefi-noseed`;
- the run ends with `ALL CHECKS PASSED`.

Optional mutation check (one extra build): set `KillMode=mixed` in `agentos-web.service`, rebuild and rerun `uefi`. `check_web_session_terminal` must FAIL. Then revert.

- [ ] **Step 5: CI**

In `.github/workflows/build.yml`:

(a) In "Host setup", add `tmux` to the apt list (the live terminal test in `web/server` needs it):
```yaml
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils mtools pipx shellcheck zstd tmux
```

(b) In "Lint and unit tests", add `mkosi.extra/usr/local/lib/agentos/web-serve test/web_serve_test.sh \` to the shellcheck list on a new line after `mkosi.extra/etc/profile.d/agentos.sh \`, and add `test/web_serve_test.sh` after `python3 test/computer_test.py`.

(c) Insert these two steps directly after "Lint and unit tests":
```yaml
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0
        with:
          node-version: 24

      - name: Web UI unit tests
        run: |
          (cd web/server && npm ci && npm run typecheck && npx vitest run)
          (cd web/ui && npm ci && npx vitest run && npm run build)
```

Check locally: `python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/build.yml"))' && echo YAML_OK`. Expected: `YAML_OK`.

- [ ] **Step 6: Commit**

```bash
git add test/web_ws.mjs test/web_e2e.mjs test/checks/96-web.sh .github/workflows/build.yml
git commit -m "test(web): in-VM checks for auth, CSRF, sessions, terminal, desktops, VNC, settings, audit and Playwright e2e; CI runs the web unit tests"
```

---

## Spec coverage

| Spec item | Task |
|---|---|
| Five pages: Overview, Sessions, Desktops, Settings, System | 6, 7, 8 (APIs: 2–5) |
| Node 24, TypeScript + Fastify, React + Vite + TypeScript SPA | 1, 6 |
| App binds `127.0.0.1:7070` only; `tailscale serve --bg --https=443 http://127.0.0.1:7070`, idempotent, at firstboot | 1, 9 (`web_serve_test.sh`, `check_web_service_loopback_only`) |
| Serve failure: firstboot warns, Overview and the console banner say why | 9 (`SERVE=`, `/run/issue.d`), 6 (Overview shows `serve:`) |
| `agentos-web.service` as agent, enabled by default; `AGENTOS_WEB=0` stops the service and withdraws serve | 9 (`check_web_disable_and_enable`) |
| Identity header against `AGENTOS_WEB_USERS`, case-insensitive; 401 missing, 403 unlisted, on HTTP and WebSocket | 1 (unit), 10 (`check_web_identity_codes`) |
| Not-configured static page, no API reachable | 1, 10 (`check_web_not_configured_page`) |
| CSRF: `X-AgentOS: 1` + Origin on POST/PUT/DELETE; Origin on WebSocket upgrades | 1, 6 (`api.ts` sends the header), 10 (`check_web_csrf`) |
| Accepted residual risk (local processes); Host pinned against DNS rebinding | 1 |
| Secrets: never returned, set/not-set from key names, write-only, never in logs or audit | 2 (unit + stdin values), 6 (`SecretField`), 10 (`check_web_settings_roundtrip_and_secrets`) |
| VNC: same-origin `/api/desktops/N/vnc`, token added server-side; view-only toggle | 4 (`vnc.test.ts`), 7, 10 (VNC banner check) |
| Audit: `agentos-web: <login> <action> <target>` at notice level for every mutating action | 1 (format), 2–5 (calls), 10 (`check_web_audit_line`) |
| Unit hardening: NoNewPrivileges off, ProtectHome off, PrivateTmp=no, Restart=on-failure | 9 (`check_web_unit_shape`) |
| Fixed actions table, `sudo -n`, argv only, unit allowlist `agentos-*`/docker/tailscaled, `agentos-update` without sudo, reboot/poweroff | 2 (`actions.test.ts`), 5 |
| `agentos-config remove-ssh-key`, `AGENTOS_WEB_USERS` (validated, menu item), `AGENTOS_WEB` (`0|1`); values validated by agentos-config | 2 |
| `/etc/agentos/web.conf` (root-written, 644) with `USERS=`, `ENABLED=` | 2 (`check_web_conf_follows_config`), 9 |
| Layout: sidebar, header with hostname, tailnet address and login; dark-first; usable on tablets | 6 (`App.tsx`, `style.css` breakpoint) |
| Overview: CPU/RAM/disk/load every 5 s, counts, Tailscale and serve, quick actions | 5, 6 |
| Sessions: list incl. external and ended, sidecars, attached count | 3, 7 |
| New session: CLI, folder tree under /home/agent or clone into `~/work/<name>`, name rules, `bash -lc`, realpath confinement | 3 (unit: traversal, symlink, prefix sibling), 7 |
| Terminal: xterm.js, resize, multiple viewers, closing detaches | 3 (live tmux test), 7, 10 (`check_web_session_terminal`, e2e) |
| Stop with confirm; sidecar stays, ended; Remove after reboot | 3, 7, 10 |
| Open terminal (Overview, System) creates a shell session | 6 (`quick.ts`), 8 |
| Desktops: 480 px thumbnail every 5 s, idle vs reaper limit, viewer attached, New/Destroy (confirm), max from desktop.conf | 4, 7, 10 (`check_web_desktop_thumbnail_vnc_destroy`) |
| Desktop view: view-only default, take control, full-screen | 7 |
| Settings: secrets with Clear; Tailscale status, auth key, ACL doc; SSH keys list/add/remove/GitHub; LAN SSH, console, auto-reboot; desktops; web users with self-removal confirm | 2, 6 |
| Save = `set` then `apply`; validation errors inline | 2, 6 (`SettingsForm.test.tsx`) |
| System: services with Restart, live journal, `agentos-update` live, last unattended run, typed-hostname reboot/poweroff | 5, 8 (`Power.test.tsx`) |
| Image: build in mkosi (`npm ci`, build, `npm prune --omit=dev`) into `/usr/local/lib/agentos/web`; node-pty compiled against the image's Node; size within budget | 9 (`check_web_size`, `check_root_size_budget`, finalize invariants) |
| Unit tests (vitest): auth, CSRF, WebSocket checks, actions argv, names/dirs, secrets never in responses | 1–5 |
| UI: typecheck, build, settings form component tests | 6–8 |
| In-VM smoke list (service/bind, 401/403/200, session + terminal echo, desktop + PNG + destroy, settings roundtrip + secret never returned, audit line) | 9, 10 |
| E2E: headless Playwright in the VM, identity header injected, every page, New session → type → output | 10 (`check_web_e2e`) |
| Not automated: real `tailscale serve` HTTPS; CI checks only the serve command logic | 9 (`web_serve_test.sh`, runs in CI from Task 10) |

## Self-review

- **Spec coverage:** every row above maps to a task. Section 5's "CI lint" is the new "Web UI unit tests" step (Task 10), placed next to the existing lint step.
- **Placeholders:** none. Every code step has the complete file or the exact replacement text. Lockfiles are generated by `npm install` in Tasks 1 and 6 and committed. Their transitive versions aren't fixed by this plan; every direct dependency is pinned exactly.
- **Names and types across tasks:**
  - `HttpError`, `Runner`, `RunOpts`, `RunResult`, `execRunner` come from `run.ts`, and every later module imports them from there.
  - `runAction`, `argv` and the regexes come from `actions.ts`.
  - `Deps` and `buildApp` come from `app.ts`.
  - `tmuxSessions` (sessions.ts) is used by `terminal.ts`; `activeDesktops` and `desktopNumber` (desktops.ts) by `vnc.ts`; `parseTailnetName` (auth.ts) by `app.ts` and `system.ts`.
  - On the UI side, `api`, `ApiError`, `wsUrl`, `usePoll(fn, ms, deps)`, `navigate`, `Link`, `confirmAction`, `ErrorText`, `openTerminal` and `newDesktop` keep the same signatures in Tasks 6–8.
  - The smoke checks rely on the server JSON shapes `{"id":"ag-smoke"…"state":"ended"}`, `{"id":N}`, `{"ok":true}` and `{"field":…}`, which match `sessions.ts`, `desktops.ts` and the error handler.
- **Staged states verified:** the cumulative server states after Tasks 1–5 and UI states after Tasks 6–8 were each compiled and tested on their own while writing this plan, with the expected counts quoted in each task.
