# AgentOS: Solenta Worker Host and Built-in CI — Design

Date: 2026-10-27
Status: Approved in brainstorming. Awaiting the user's spec review.
Builds on: the AgentOS base, desktops, installer and web UI specs (all merged on `master` at 6956e61).

## Goals

1. **Solenta worker host.** An AgentOS machine works as a remote host for Solenta.app 0.22, unmodified. Solenta's existing `remoteHost`/`remotePath` project setting runs every agent CLI on the box over SSH. On the box, the CLIs, API keys and Solenta's own MCP servers (`coder-threads`, `coder-memory`) all work.
2. **Built-in CI.** You can run CI for any repo on the box without GitHub: push to the box, or trigger from the web UI, the CLI or an agent. Agents get MCP tools and a skill that make "run CI, read the failure, fix, re-run" part of how they work.

## Non-goals

- Running Solenta itself on Linux: there's no Linux build, and the Electron main process requires a window.
- Changing Solenta.
- A full forge (PRs, issues). Forgejo may come later as a separate add-on.

## Facts about Solenta 0.22 this design relies on

Investigated from the app bundle (`/Applications/Solenta.app/Contents/Resources/app`):
- A project with `remoteHost` (`user@host`) and `remotePath` makes Solenta run each CLI as `ssh -o BatchMode=yes -o ConnectTimeout=10 user@host 'cd <remotePath> && env K=V <cli> …'` (`electron/ssh.js`).
- Per-run homes live under `$HOME/.solenta/<kind>/<threadId>` on the remote (`electron/remote-overlay.js`).
- The remote needs:
  - key-based (non-interactive) SSH;
  - the CLIs on the PATH of a **non-login** shell;
  - `git`, `bash` and `node`, which Solenta's preflight checks;
  - an existing git checkout at `remotePath`.
- `coder-threads` and `coder-memory` are HTTP MCP servers inside Solenta's Electron process. They bind `127.0.0.1` on a random port with a bearer token, and their config lives in `<userData>/orch-server.json` and `<userData>/memory-server.json`. CLIs get `http://127.0.0.1:<port>/mcp` URLs, so a remote box can't reach them unless something forwards that port.

## Part 1: Solenta worker host

### 1A. CLIs and API keys over non-login SSH (box)

- Wrappers in `/usr/local/bin` for `claude`, `codex`, `opencode` and `grok` (on every default PATH). Each wrapper:
  1. exports the agent's API keys by parsing `~/.config/agentos/secrets.env`, the same non-evaluating parser as `/etc/profile.d/agentos.sh`, factored into one shared file `/usr/local/lib/agentos/load-secrets.sh` and used by both;
  2. execs the real binary, found through the same PATH list as profile.d (`~/.local/bin`, `~/.opencode/bin`, `~/.grok/bin`, …), skipping `/usr/local/bin` itself so it can't loop;
  3. if the real binary is missing, prints `agentos: <cli> is not installed for user agent` and exits 127.
- The wrappers only act for user `agent`. For any other user they exec the real binary from that user's PATH, or fail cleanly.
- Self-updates are unaffected: the real binaries still live in the agent's home.

### 1B. Pairing (box)

- New `agentos-config solenta` subcommand, plus a "Solenta" card on the web UI Settings page. Both do the same steps:
  1. **SSH access.** Either paste the Mac's public key (`agentos-config add-ssh-key`), or rely on Tailscale SSH (the tailnet ACL decides). The card shows which applies.
  2. **Repo.** Clone a git URL into `~/work/<name>` using the sessions clone code, with the same allowlist (https, ssh, git@) and `--` separator. Or pick an existing directory under `/home/agent`.
  3. **Values for Solenta.** Show `remoteHost = agent@<tailnet DNS name or IP>` and `remotePath = /home/agent/work/<name>`, with copy buttons.
  4. **Preflight.** Run, as agent, `bash -c 'command -v git bash node claude codex opencode grok'` in a non-login, non-interactive environment equivalent to what Solenta's SSH command gets (`env -i HOME=/home/agent PATH=/usr/local/bin:/usr/bin:/bin bash -c …`). Also check the checkout (`git -C <path> rev-parse`) and that `~/.solenta` is writable. Show a pass or fail per item.
- No new state: pairing only writes `authorized_keys` and the checkout.

### 1C. Solenta's MCP servers on the box (Mac-side bridge)

- **`tools/solenta-bridge`:** a bash script that runs on the Mac. It ships in the AgentOS repo and can be downloaded from the web UI Solenta card. It:
  1. reads the ports from `~/Library/Application Support/Solenta/{orch-server.json,memory-server.json}`, port fields only, never the tokens;
  2. keeps `ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -R 127.0.0.1:<P>:127.0.0.1:<P>` (one `-R` per port) open to each configured box;
  3. re-reads when either file changes or the tunnel drops, with backoff.
- `solenta-bridge install <user@box>…` writes a launchd agent (`~/Library/LaunchAgents/os.agent.solenta-bridge.plist`), and `uninstall` removes it. Configured boxes go in `~/.config/agentos/solenta-bridge.conf`.
- **On the box:**
  - OpenSSH must allow remote forwarding for `agent`. That's the default, so check that `AllowTcpForwarding` isn't disabled.
  - Forwards bind 127.0.0.1 only (`GatewayPorts no`, the default).
  - A box check verifies a reverse forward to loopback works, and is not exposed on other interfaces.
- **Tailscale SSH:** if Tailscale SSH doesn't support `-R` remote forwards, the bridge connects over OpenSSH instead, on the tailnet address with key auth. The plan must verify this and document the result.
- **Security note,** in the docs and on the card: the `coder-threads` token, which Solenta hands to agents it runs, lets an agent drive Solenta on the Mac. Through the tunnel, the paired box's agents get the same power a local Solenta run has. The tunnel exposes the ports only on the box's loopback, and the bearer token is still required.

## Part 2: Built-in CI

### 2A. Engine: `agentos-ci`

A Python package in the existing venv (`/usr/local/lib/agentos/venv`), launched as `/usr/local/bin/agentos-ci`. One engine, three front-ends: the CLI (`--json` output), the MCP server, and the web UI (which shells out to the CLI).

**Pipeline selection**, per repo, first match wins:
1. **`.agentos/ci.yml`:**
   ```yaml
   image: node:24        # optional: run all steps in this container; default: on the box
   timeout: 30m          # optional per run; default 30m
   secrets: [NPM_TOKEN]  # optional: names from secrets.env exposed to steps
   steps:
     - name: install
       run: npm ci
     - name: test
       run: npm test
   ```
2. **`.github/workflows/*.yml`**, run with `act`. The event is `push`, plus `workflow_dispatch` where present. `act` is pinned with a checksum, installed at build time, and uses Docker with a default runner image mapping that the plan pins.
3. **Auto-detect**, by files present:

   | Files present | Command |
   |---|---|
   | `package.json` with a `test` script | `npm ci && npm test` |
   | `pyproject.toml` / `pytest.ini` / `tests/` | `pytest` |
   | `Cargo.toml` | `cargo test` |
   | `go.mod` | `go test ./...` |
   | `Makefile` with a `test` target | `make test` |

   Nothing found means the run fails with "no CI configuration found" and a hint.

**Execution:**
- Each run checks out the exact commit into a fresh `git worktree` (or `git clone --shared` for bare repos) under `~/.cache/agentos-ci/work/<run>`, removed afterwards.
- Runs as `agent`.
- Steps run in order with `bash -eo pipefail`.
- The environment is clean: PATH plus `CI=true` plus `AGENTOS_CI_RUN=<id>`, plus only the listed `secrets:`.
- With `image:`, steps run in `docker run --rm -v <worktree>:/w -w /w <image> bash -eo pipefail -c '<run>'`.
- The run timeout kills the step's process group.

**State:**
- Each run gets `~/.local/share/agentos-ci/runs/<id>/` holding `run.json` (repo, ref, commit, source, status, per-step status, times) and `<step>.log`.
- Run ids are monotonic: `YYYYMMDD-HHMMSS-<4 hex>`.
- Retention: the newest 200 runs are kept.
- Concurrency: at most `AGENTOS_CI_MAX_PARALLEL` (default 2) runs at once, using flock slots; the rest wait as `queued`.
- Statuses: `queued`, `running`, `passed`, `failed`, `cancelled`, `error`.
- Cancel sends SIGTERM to the process group, then SIGKILL after 10 s.

**CLI:**
- `agentos-ci run [PATH] [--ref REF] [--wait]`
- `agentos-ci status ID`
- `agentos-ci logs ID [--step S] [--tail N] [--follow]`
- `agentos-ci list [--repo PATH] [--limit N]`
- `agentos-ci cancel ID`
- `agentos-ci remote create NAME`, `agentos-ci remote list`

Every command takes `--json`.

### 2B. Push to the box

- `agentos-ci remote create NAME` creates the bare repo `~/git/NAME.git` with a `post-receive` hook. The hook starts `agentos-ci run ~/git/NAME.git --ref <pushed ref>` for every updated branch and prints the run id back to the pusher.
- It prints `git remote add agentos agent@<box>:git/NAME.git`.
- Pushes use SSH under the same access rules as everything else: allowlisted keys, or Tailscale SSH.
- `NAME` must match `[a-z0-9][a-z0-9-]{0,62}`.

### 2C. MCP tools for agents

A new MCP server, `agentos-ci` (FastMCP, same venv, stdio). It is registered in all four CLIs at boot by `register-mcp`, alongside `agentos-computer`. Tools:
- `ci_run(path: str, ref: str = "HEAD") -> {run_id}`: `path` must resolve inside `/home/agent`.
- `ci_wait(run_id: str, timeout_s: int = 1800) -> {status, failed_step, log_tail}`: blocks until the run finishes. `log_tail` is the last 200 lines of the failing step.
- `ci_status(run_id)`, `ci_logs(run_id, step?, tail=200)`, `ci_list(path?, limit=20)`, `ci_cancel(run_id)`.

### 2D. Skill for agents

One source text, `agentos-ci.md`, installed at first boot by `register-mcp` (the image may contain no CLI state) into each CLI's skill or global-instruction location. The plan verifies the exact paths:
- Claude Code: `~/.claude/skills/agentos-ci/SKILL.md`
- Codex: an appended section in `~/.codex/AGENTS.md`
- opencode: its global instructions file
- Grok: `~/.grok/skills/agentos-ci/`

Content:
- before declaring a task done in a repo with CI, run `ci_run` then `ci_wait`;
- on failure, read `log_tail` (or `ci_logs`), fix the root cause, and re-run;
- never weaken or delete tests or CI config to get a pass;
- report the run id and the result.

Install is idempotent and never overwrites a user-edited file. Each managed block is marked, and only that block is replaced.

### 2E. Web UI

- **CI page:**
  - runs list (repo, ref, commit, status, duration);
  - run detail with steps and a live log per step (WebSocket tail, same stream pattern and backpressure as the journal);
  - Re-run and Cancel buttons;
  - "Run CI" for a directory under `/home/agent` (DirPicker);
  - a list of push remotes with their `git remote add` lines.
- **Overview:** status of the latest run.
- All actions go through the existing auth, CSRF and audit, and call `agentos-ci … --json` as agent. No sudo is needed.

## Security

- CI runs repository code as `agent`: the same trust as agents running the code themselves. Pushes need allowlisted SSH or Tailscale access.
- `docker` group membership (required for `image:` and `act`) was already root-equivalent on this box. Nothing new is granted.
- CI steps don't inherit API keys. Exposing one requires listing it under `secrets:` in the repo's config, and that's visible in the run's metadata (names only, never values).
- The Solenta bridge exposes Solenta's MCP ports only on the box's loopback. Tokens never leave the Mac's config files through the bridge.

## Testing

- **Unit (pytest, `agentos-ci`):**
  - pipeline selection order;
  - `ci.yml` parsing and validation;
  - auto-detect rules;
  - run-state transitions;
  - queueing at max parallel;
  - cancel kills the process group;
  - retention;
  - name and path validation;
  - secrets are exposed only when listed.
- **Unit (bash):** wrapper resolution (no self-loop, missing binary → 127), and the `solenta-bridge` port parsing from sample JSON (tokens never read or printed).
- **In-VM smoke checks (`test/checks/97-solenta.sh`, `98-ci.sh`):**
  - over a non-login, non-interactive command (`ssh agent@vm 'claude --version'`, or `env -i … bash -c`), every CLI resolves and an API key from `secrets.env` is visible;
  - the Solenta preflight passes;
  - a reverse forward (`ssh -R`) from the host binds only on the VM's loopback and is reachable there;
  - CI: `remote create` → push a sample repo with a passing `.agentos/ci.yml` → the run passes. A failing step → `failed`, with that step's log tail;
  - `act` runs a trivial workflow in Docker;
  - auto-detect on a sample npm project;
  - the MCP `ci_run` + `ci_wait` end-to-end;
  - the skill file is present for each CLI after boot;
  - the web CI API lists and streams the run.
- **Manual:** pair with a real Solenta.app on the Mac; run a thread on the box; confirm that `coder-threads` and `coder-memory` work through the bridge.

## Out of scope (this round)

Forgejo or PRs; CI result notifications (email, chat); build caches across runs; matrix builds outside `act`; Windows and macOS CI targets; running Solenta on Linux.
