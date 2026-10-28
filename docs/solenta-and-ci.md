# Solenta and built-in CI on AgentOS

## Solenta

AgentOS works with an unmodified Solenta.app in two modes. Use Mode A unless you have a reason not to. Requires Solenta 0.27 or later: 0.26.0's Linux build always creates a window, even under `--headless`, and crashes with no X display; 0.27.0 fixes this, and AgentOS runs it with no X server at all.

### Mode A: Solenta on the box (recommended)

Solenta's own *Remote Connections* installs Solenta's Linux build on the box over SSH, runs it headless, and opens it on your Mac through an SSH tunnel. The agents, their CLIs, and Solenta's `coder-threads` and `coder-memory` all run on the box.

1. **SSH access.** Add your Mac's public key (`sudo agentos-config add-ssh-key "ssh-ed25519 AAAA… you@mac"`, or the web UI's SSH keys panel), or use Tailscale SSH, where your tailnet policy decides.
2. **Host key.** Solenta refuses a host that isn't in the Mac's `~/.ssh/known_hosts`. The Solenta card in the web UI (or `sudo agentos-config solenta`) shows the box's host key fingerprints and an `ssh-keyscan` line. Compare the fingerprints with what `ssh agent@<box>` shows on the Mac, then run the line on the Mac.
3. **Connect.** In Solenta, open Settings, Connections, Remote Connections, and add `agent@<box>`. Solenta installs itself into `~/solenta` on the box.

The box does the rest:
- The Electron runtime libraries Solenta's `ldd` check needs are in the image.
- `agentos-solenta.path` notices the install (and every upgrade) and starts `agentos-solenta.service`. The service runs `~/solenta/solenta --headless --serve-web=4620 --no-sandbox` as `agent`, keeps it running after your SSH session ends, and restarts it after Solenta's upgrade stops the old build. No X server is involved; headless Electron runs without one on 0.27.0+.
- Port 4620 stays on the box's loopback: Solenta reaches it through its own `ssh -L`.

Turn this off with `sudo agentos-config set AGENTOS_SOLENTA 0 && sudo agentos-config apply`.

### Mode B: Solenta on the Mac, agents on the box

Set a Solenta project's `remoteHost` and `remotePath` to the values the Solenta card shows (`agent@<box>` and a checkout under `/home/agent`). Solenta then runs each agent CLI on the box as `ssh agent@<box> 'cd <remotePath> && … <cli> …'`.

- `claude`, `codex`, `opencode` and `grok` resolve in that non-login shell through wrappers in `/usr/local/bin`. The wrappers load the API keys from `~/.config/agentos/secrets.env`.
- The card's preflight runs the same kind of command and shows a pass or fail per CLI, for `git`, `bash` and `node`, for the checkout, and for `~/.solenta`.

**Solenta's MCP servers (`coder-threads`, `coder-memory`)** listen on the Mac's loopback. To reach them from the box, run the bridge on the Mac. Download `solenta-bridge` from the Solenta card, or take it from `tools/solenta-bridge` in this repository, then run:

```
bash solenta-bridge install agent@<box>
```

It installs a launchd agent (`~/Library/LaunchAgents/os.agent.solenta-bridge.plist`) that keeps an `ssh -N -R` tunnel open to each box and reconnects when Solenta's ports change or the connection drops. `bash solenta-bridge uninstall` removes it. The bridge reads only the `port` fields of Solenta's `orch-server.json` and `memory-server.json`, never the tokens.

**Tailscale SSH and `-R`:** Tailscale SSH serves remote forwards. They bind loopback only, but only when your tailnet policy's SSH rule grants remote port forwarding. When Tailscale SSH is on (the AgentOS default), port 22 on the box's tailnet address belongs to tailscaled, so the bridge can't use OpenSSH there. If your policy refuses the forward, the bridge's log (`~/Library/Logs/solenta-bridge.log`) shows `remote port forwarding failed`. In that case, connect over the LAN instead: `sudo agentos-config set AGENTOS_LAN_SSH 1`, then `bash solenta-bridge install agent@<LAN address>`.

**Security.** Solenta hands the `coder-threads` bearer token to the agents it runs, and that token lets an agent drive Solenta on your Mac. Through the bridge, the paired box's agents get the same power a local Solenta run has. The tunnel exposes the ports only on the box's loopback, and the bearer token is still required.

## Built-in CI

`agentos-ci` runs CI for any git repository under `/home/agent`, without GitHub. Each run checks out one commit into a scratch directory, runs the steps as `agent`, and keeps the newest 200 runs in `~/.local/share/agentos-ci/runs/`.

**What runs** (first match wins):
1. `.agentos/ci.yml`:
   ```yaml
   image: node:24        # optional: run every step in this container (default: on the box)
   timeout: 30m          # optional, for the whole run (default 30m)
   secrets: [NPM_TOKEN]  # optional: names from secrets.env exposed to the steps
   steps:
     - name: install
       run: npm ci
     - name: test
       run: npm test
   ```
2. `.github/workflows/*.yml` with an `on: push` (or `workflow_dispatch`) trigger, run with `act`. `ubuntu-latest` and `ubuntu-24.04` map to `catthehacker/ubuntu:act-24.04`, and `ubuntu-22.04` to `act-22.04`. Docker pulls the image (about 570 MB) on first use.
3. Otherwise, a test entry point: an npm `test` script (`npm ci && npm test`), `pyproject.toml`/`pytest.ini`/`tests/` (`pytest`), `Cargo.toml` (`cargo test`), `go.mod` (`go test ./...`), or a Makefile `test` target (`make test`).

**Starting runs:**
- `agentos-ci run [PATH] [--ref REF] [--wait]`
- the web UI's CI page
- the agents' MCP tools (`ci_run`, `ci_wait`, …)
- a push: `agentos-ci remote create NAME` makes `~/git/NAME.git` and prints the `git remote add agentos agent@<box>:git/NAME.git` line for your machine. Every push to it runs CI for each pushed branch, and `git push` prints the run id.

**Other commands:**
- `agentos-ci status ID`
- `agentos-ci logs ID [--step S] [--follow]`
- `agentos-ci list`
- `agentos-ci cancel ID`

Every command takes `--json`. At most `AGENTOS_CI_MAX_PARALLEL` runs (default 2) run at once; the rest wait as `queued`.

**Trust model.** CI steps run as the `agent` user, the same user everything else on the box runs as. `agent` has passwordless sudo and is in the `docker` group, both root-equivalent: a CI step can become root, read `~/.config/agentos/secrets.env` in full, touch any other user's files, or otherwise do anything `agent` can do on this box. Only the step's own *environment* is kept clean of API keys — `PATH`, `HOME`, `LANG`, `CI=true` and `AGENTOS_CI_RUN`, plus any names the repo lists under `secrets:` (and only those names; the run records the names, never the values). That environment scrubbing is not a sandbox: a step that reads the secrets file directly, or escalates with the sudo and docker access it already has, sees everything regardless of what's in its environment. `image:` steps and `act` runs happen inside a container, so they see only the repository checkout mounted into it — but the container itself runs via the same root-equivalent Docker access, so this is a convenience boundary for accidents, not a security boundary against a hostile repo. **Never run untrusted code through agentos-ci.** Treat pushing to an `agentos-ci remote` or pointing `agentos-ci run` at a path exactly like running that code directly as yourself on the box.

**Agents.** Every agent CLI gets the `agentos-ci` MCP server and a short skill: before declaring work in a repository done, commit, run CI, wait for it, fix real failures, and never weaken tests to get a pass.

**Recovering a malformed skill block.** The skill installer rewrites only the text between its `<!-- agentos-ci:begin … -->` and `<!-- agentos-ci:end -->` markers; this keeps hand-edited content elsewhere in `~/.codex/AGENTS.md` and `~/.config/opencode/AGENTS.md` untouched across upgrades. If a file ends up with only one of the two markers, markers out of order, or more than one of either (for example from a bad manual edit or a merge), the installer refuses to guess what you meant: it leaves the file alone and only logs a warning to the journal, rather than risking your other content. To recover: for `~/.codex/AGENTS.md` and `~/.config/opencode/AGENTS.md`, delete both markers (the `agentos-ci:begin` and `agentos-ci:end` lines) *and* the text between them, by hand; for `~/.claude/skills/agentos-ci/SKILL.md` and `~/.grok/skills/agentos-ci/SKILL.md`, delete the whole file instead. The next boot, or the next `sudo agentos-config apply`, re-installs it.
