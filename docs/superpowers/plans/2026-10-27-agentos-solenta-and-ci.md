# AgentOS: Solenta on AgentOS and Built-in CI Implementation Plan (Plan 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An unmodified Solenta.app 0.26 works with an AgentOS box. In Mode A, Solenta runs headless on the box, installed by Solenta's own Remote Connections and kept alive by a unit. In Mode B, the box is a worker host for a Mac-side Solenta. Any repo on the box gets CI without GitHub, which agents drive through MCP tools and a skill.

**Architecture:**
- **Mode A.** The image ships the Electron runtime libraries. `agentos-solenta.path` (PathChanged) starts `agentos-solenta.service`, which runs as `agent` and execs the Solenta build that Remote Connections unpacked into `~/solenta`, on loopback port 4620.
- **Mode B.** Wrappers in `/usr/local/bin` make the four agent CLIs, and their API keys, work over non-login SSH. They share one secrets parser (`load-secrets.sh`) with `/etc/profile.d`.
  - `solenta-pair` computes the pairing facts and preflight for the web UI's Solenta card and for `agentos-config solenta`.
  - A Mac-side `tools/solenta-bridge` keeps `ssh -R` tunnels open to Solenta's MCP ports.
- **CI.** `agentos-ci` is one Python package in the existing venv, with three front ends: the CLI (`--json`), the MCP server (stdio), and the web UI, which shells out to the CLI.
  - A run is a detached worker that waits for a flock slot, `git clone --shared`s the exact commit, runs the steps in their own process groups with a clean environment, and records `run.json` and per-step logs.
  - Push remotes are bare repos whose shared `post-receive` hook starts a run per branch.

**Tech Stack:**
- the existing stack: bash, systemd 257 (Debian 13), mkosi 27, Python 3.13 venv, Node 24 server and React UI;
- new: PyYAML 6 and `mcp>=1.28,<2` (FastMCP) in the venv, nektos/act 0.2.89 (pinned binary), pytest (host-only), vitest 5.0.5.

**Builds on:** `master` at 6956e61 (the web UI is merged), on branch `solenta-ci`, which holds only the spec commits. Implement from the main checkout `/Users/willem/Projects/AgentOS`, on branch `solenta-ci`. Read `.superpowers/sdd/context.md` for the build host workflow (devvm, `devvm.sh`, `TMPDIR=/var/tmp`, foreground polling).

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-10-27-agentos-solenta-and-ci-design.md`). When this plan and the spec disagree, the spec wins, except for the deliberate, evidenced adjustments listed under "Spec adjustments" below.

- Solenta.app 0.26 (Nightly), unmodified, works with an AgentOS box in two modes
- Non-goals: Changing Solenta. / A full forge (PRs, issues).
- Mode B's bridge is unnecessary in Mode A, so docs and the card present Mode A first.
- Runtime libraries in the image, so the post-install `ldd` check passes: `libnss3 libnspr4 libgtk-3-0 libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libxfixes3 libpango-1.0-0 libcairo2 libdbus-1-3 libexpat1 libxext6 libx11-6 libxcb1 libglib2.0-0`
- `agentos-solenta.service`, a system unit running as `agent`, owns the headless process once Solenta has installed it.
- Condition: `ConditionPathExists=` on either install path (`/home/agent/solenta/solenta` or `/home/agent/solenta/solenta-nightly`).
- Start command: `<bin> --headless --serve-web=4620 --no-sandbox`, with `Environment=PATH=/usr/local/bin:/usr/bin:/bin` so the 1A wrappers resolve the CLIs.
- Enabled by `AGENTOS_SOLENTA` (default `1`, set with `agentos-config`).
- Network: port 4620 stays on loopback. Solenta reaches it through its own `ssh -L`, so no firewall change is needed.
- Check: the card shows `agentos-solenta` status, the installed version (from the tarball's `package.json` or the binary's `--version`), and whether `~/.config/Solenta/web-token` exists. It never shows the token.
- Wrappers in `/usr/local/bin` for `claude`, `codex`, `opencode` and `grok` (on every default PATH).
- [The wrapper] exports the agent's API keys by parsing `~/.config/agentos/secrets.env`, the same non-evaluating parser as `/etc/profile.d/agentos.sh`, factored into one shared file `/usr/local/lib/agentos/load-secrets.sh` and used by both
- [The wrapper] execs the real binary, found through the same PATH list as profile.d (`~/.local/bin`, `~/.opencode/bin`, `~/.grok/bin`, …), skipping `/usr/local/bin` itself so it can't loop
- if the real binary is missing, prints `agentos: <cli> is not installed for user agent` and exits 127.
- The wrappers only act for user `agent`. For any other user they exec the real binary from that user's PATH, or fail cleanly.
- Self-updates are unaffected: the real binaries still live in the agent's home.
- Repo: Clone a git URL into `~/work/<name>` using the sessions clone code, with the same allowlist (https, ssh, git@) and `--` separator. Or pick an existing directory under `/home/agent`.
- Preflight: Run, as agent, `bash -c 'command -v git bash node claude codex opencode grok'` in a non-login, non-interactive environment … (`env -i HOME=/home/agent PATH=/usr/local/bin:/usr/bin:/bin bash -c …`). Also check the checkout (`git -C <path> rev-parse`) and that `~/.solenta` is writable. Show a pass or fail per item.
- No new state: pairing only writes `authorized_keys` and the checkout.
- [The bridge] reads the ports from `~/Library/Application Support/Solenta/{orch-server.json,memory-server.json}`, port fields only, never the tokens
- [The bridge] keeps `ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -R 127.0.0.1:<P>:127.0.0.1:<P>` (one `-R` per port) open to each configured box; re-reads when either file changes or the tunnel drops, with backoff.
- `solenta-bridge install <user@box>…` writes a launchd agent (`~/Library/LaunchAgents/os.agent.solenta-bridge.plist`), and `uninstall` removes it. Configured boxes go in `~/.config/agentos/solenta-bridge.conf`.
- Forwards bind 127.0.0.1 only (`GatewayPorts no`, the default).
- A Python package in the existing venv (`/usr/local/lib/agentos/venv`), launched as `/usr/local/bin/agentos-ci`. One engine, three front-ends: the CLI (`--json` output), the MCP server, and the web UI (which shells out to the CLI).
- Pipeline selection, per repo, first match wins: `.agentos/ci.yml`; `.github/workflows/*.yml` run with `act`; auto-detect.
- `act` is pinned with a checksum, installed at build time, and uses Docker with a default runner image mapping that the plan pins.
- Nothing found means the run fails with "no CI configuration found" and a hint.
- Steps run in order with `bash -eo pipefail`.
- The environment is clean: PATH plus `CI=true` plus `AGENTOS_CI_RUN=<id>`, plus only the listed `secrets:`.
- With `image:`, steps run in `docker run --rm -v <worktree>:/w -w /w <image> bash -eo pipefail -c '<run>'`.
- The run timeout kills the step's process group.
- Each run gets `~/.local/share/agentos-ci/runs/<id>/` holding `run.json` (repo, ref, commit, source, status, per-step status, times) and `<step>.log`.
- Run ids are monotonic: `YYYYMMDD-HHMMSS-<4 hex>`.
- Retention: the newest 200 runs are kept.
- Concurrency: at most `AGENTOS_CI_MAX_PARALLEL` (default 2) runs at once, using flock slots; the rest wait as `queued`.
- Statuses: `queued`, `running`, `passed`, `failed`, `cancelled`, `error`.
- Cancel sends SIGTERM to the process group, then SIGKILL after 10 s.
- CLI: `agentos-ci run [PATH] [--ref REF] [--wait]`, `status ID`, `logs ID [--step S] [--tail N] [--follow]`, `list [--repo PATH] [--limit N]`, `cancel ID`, `remote create NAME`, `remote list`. Every command takes `--json`.
- `agentos-ci remote create NAME` creates the bare repo `~/git/NAME.git` with a `post-receive` hook … for every updated branch and prints the run id back to the pusher. It prints `git remote add agentos agent@<box>:git/NAME.git`. `NAME` must match `[a-z0-9][a-z0-9-]{0,62}`.
- MCP server `agentos-ci` (FastMCP, same venv, stdio), registered in all four CLIs at boot by `register-mcp`, alongside `agentos-computer`. Tools: `ci_run(path: str, ref: str = "HEAD") -> {run_id}` (`path` must resolve inside `/home/agent`); `ci_wait(run_id: str, timeout_s: int = 1800) -> {status, failed_step, log_tail}` (`log_tail` is the last 200 lines of the failing step); `ci_status(run_id)`, `ci_logs(run_id, step?, tail=200)`, `ci_list(path?, limit=20)`, `ci_cancel(run_id)`.
- Skill: one source text, `agentos-ci.md`, installed at first boot by `register-mcp` (the image may contain no CLI state) into each CLI's skill or global-instruction location. Install is idempotent and never overwrites a user-edited file. Each managed block is marked, and only that block is replaced.
- Skill content: run `ci_run` then `ci_wait` before declaring a task done; on failure read `log_tail` (or `ci_logs`), fix the root cause, re-run; never weaken or delete tests or CI config to get a pass; report the run id and the result.
- Web UI CI page: runs list (repo, ref, commit, status, duration); run detail with steps and a live log per step (WebSocket tail, same stream pattern and backpressure as the journal); Re-run and Cancel buttons; "Run CI" for a directory under `/home/agent` (DirPicker); a list of push remotes with their `git remote add` lines. Overview: status of the latest run.
- All actions go through the existing auth, CSRF and audit, and call `agentos-ci … --json` as agent. No sudo is needed.
- CI steps don't inherit API keys. Exposing one requires listing it under `secrets:` in the repo's config, and that's visible in the run's metadata (names only, never values).
- The Solenta bridge exposes Solenta's MCP ports only on the box's loopback. Tokens never leave the Mac's config files through the bridge.
- Out of scope (this round): Forgejo or PRs; CI result notifications (email, chat); build caches across runs; matrix builds outside `act`; Windows and macOS CI targets; running Solenta on Linux.

Repo conventions (from the earlier plans):
- Bash scripts are `#!/bin/bash` with `set -euo pipefail` and must be `shellcheck -S warning` clean. The `post-receive` hook uses `set -uo pipefail` on purpose: one bad ref must not stop the others.
- Checks in `test/checks/*.sh` use `&&` chains. Don't rely on `set -e` inside check functions. Prove the guest side first, before any negative assertion. Check names are unique; `smoke.sh` runs them sorted by name, so every check sets up its own state.
- Smoke tests on devvm run with `TMPDIR=/var/tmp`.
- Root used space ≤ 7168 MiB (`check_root_size_budget`). No CLI state in the image (finalize invariants stay green).
- UI: React only, no UI framework, one stylesheet. Server: every exec goes through the `Runner` and the fixed actions table.

## Facts verified while writing this plan (2026-10-27)

| Fact | How | Result |
|---|---|---|
| Solenta 0.26 Remote Connections (`/Applications/Solenta Nightly.app/Contents/Resources/app/electron/remoteConnections.js`, `package.json` 0.26.0; read only, nothing secret printed) | Read `prepareHostCommand`, `installHostCommand`, `sshArgs`, `APT_PACKAGES` | Start: if `curl 127.0.0.1:<p>/` fails and `pgrep -x solenta`/`solenta-nightly` finds nothing, it runs `nohup "$bin" --headless --serve-web=<p> --no-sandbox`. `$bin` is `command -v solenta`/`solenta-nightly`, else the first executable of `$HOME/solenta/solenta`, `$HOME/solenta/solenta-nightly`, `$HOME/.local/share/solenta/solenta`, `/opt/solenta/solenta`. It logs to `$HOME/.solenta-headless.log`. A process that is already running gets `--handoff-only`. The token comes from `${XDG_CONFIG_HOME:-$HOME/.config}/Solenta/web-token`. Install unpacks into `$HOME/.solenta-new`, runs `pkill -TERM -f "$HOME/solenta/solenta[a-z-]* --headless"`, waits up to 15 s with `pgrep -f`, then `mv $HOME/solenta $HOME/solenta.old` and `mv <new> $HOME/solenta`, then `ldd` lists missing libraries. Every ssh call uses `-T -o BatchMode=yes -o StrictHostKeyChecking=yes`, and the tunnel is `-N -L 127.0.0.1:<local>:127.0.0.1:<port>`. Default port 4620. The release repo is `currentbits/solenta`, and `v0.26.0` has asset `Solenta-v0.26.0-linux-x64.tar.gz` with a `sha256:` digest. The tarball keeps `resources/app/package.json` next to the binary. |
| Solenta on Linux runs one instance at a time | `electron/main.js` | `requestSingleInstanceLock()`: on Linux a second launch exits 0 (after handing `--serve-web` to the first). A second copy can never double-serve 4620. |
| Solenta's spawned CLIs get their PATH from the login shell | `electron/pathEnv.js` | It runs `$SHELL -lic` and reads `PATH` plus `env -0`. Under the unit, `SHELL=/bin/bash` (systemd sets it for `User=`), so profile.d's PATH and keys apply too. The wrappers cover non-login SSH (Mode B). |
| Solenta's MCP config files | `orchServer.js`, `memory-sup.js`, and the local files' key names only | `orch-server.json` holds `{port, token}` and `memory-server.json` holds `{dbPath, port, token}`, written by `JSON.stringify(…, null, 2)`. The servers bind `127.0.0.1`. |
| Trixie package names for the Electron libraries | `apt-cache policy` on devvm (Debian 13) | No candidate for `libgtk-3-0`, `libasound2`, `libatk1.0-0`, `libatk-bridge2.0-0`, `libatspi2.0-0`, `libcups2`, `libglib2.0-0`. The trixie names are `libgtk-3-0t64`, `libasound2t64`, `libatk1.0-0t64`, `libatk-bridge2.0-0t64`, `libatspi2.0-0t64`, `libcups2t64`, `libglib2.0-0t64`. The other 16 keep their names. |
| Are they already in the image? | The last build's `mkosi.output/agentos.manifest` on devvm (643 packages) | **All 23 are already installed**, by Chromium and `playwright install-deps`. Size cost 0; they are listed explicitly so they stay. |
| `act` | `gh api repos/nektos/act/releases/latest`, a download, `shasum -a 256`, and the release's `checksums.txt` | Latest is `v0.2.89` (2026-06-01). Asset `act_Linux_x86_64.tar.gz`, sha256 `0191d6f1f3b716b5c55820032605d05fc3c1cdbf581ebeff655019e5dd1524c0` (matches `checksums.txt`). It contains `act` (21,115,064 bytes), `LICENSE` and `README.md`. |
| `act` without `-P` | `cmd/root.go` at v0.2.89 | With no `-P` and no actrc, act runs an interactive image survey. Passing `-P` skips it. `--pull` defaults to true; `--pull=false` pulls only a missing image. `--rm` removes containers after a failure. |
| Runner image | Docker Hub tag API, amd64 | `catthehacker/ubuntu:act-24.04` (= `act-latest`, 567 MB compressed); `full-latest` 18,968 MB; `node:24-bookworm-slim` 81 MB. **Chosen:** `ubuntu-latest`/`ubuntu-24.04` → `catthehacker/ubuntu:act-24.04`, `ubuntu-22.04` → `catthehacker/ubuntu:act-22.04`. The node image lacks the Ubuntu userland that typical workflows assume (`apt-get`, `sudo`, build tools), and `full` is 19 GB. Pulled on first use, never baked in. |
| Skill and instruction locations | Claude Code docs (code.claude.com/docs/en/skills); opencode docs (/docs/rules, /docs/skills); Codex docs (agents-md) and `openai/codex` source; `xai-org/grok-build` user guide 08-skills.md and 05-configuration.md | Claude Code: `~/.claude/skills/<name>/SKILL.md`, `description` recommended. opencode: global rules `~/.config/opencode/AGENTS.md`; global skills `~/.config/opencode/skills`, **`~/.claude/skills`** and `~/.agents/skills`; the name must match `^[a-z0-9]+(-[a-z0-9]+)*$`. Codex: `~/.codex/AGENTS.md` (`AGENTS.override.md` wins if present; 32 KiB limit); its MCP `DEFAULT_TOOL_TIMEOUT` is 300 s, overridable per server with `tool_timeout_sec`. Grok: `~/.grok/skills/<name>/SKILL.md` with required `name` and `description`; config in `~/.grok/config.toml`. |
| Tailscale SSH and `-R` | `tailscale/tailscale` at 2b62983: `ssh/tailssh/tailssh.go`, `fwdmonitor.go`, `tailcfg.go`. The KB page (1193) doesn't mention forwarding | **Supported.** `tcpip-forward` is served; binds are forced to loopback (`fwdLoopbackBindAddr`, else "binding to non-loopback addresses is not permitted"). It is allowed only when the control plane's `SSHAction.AllowRemotePortForwarding` is true (capver 63). With `tailscale up --ssh` (firstboot), port 22 on the tailnet address is tailscaled's, so OpenSSH isn't reachable there. |
| systemd path and restart semantics | Throwaway units in `/run/systemd/system` on devvm (systemd 257.13), removed afterwards | (1) `PathChanged=` fires when a new directory containing the file is renamed into place: both the first install and an upgrade. (2) `PathExists=` with a service that skips (`ExecCondition`) re-triggers until `unit-start-limit-hit`. (3) `Restart=always` restarts after SIGTERM (new MainPID). (4) A failed `ExecCondition` doesn't trigger `Restart=always` (NRestarts 0). |
| OpenSSH defaults | Debian sshd defaults (checked in the VM by `check_reverse_forward_loopback_only`) | `AllowTcpForwarding yes` and `GatewayPorts no`; AgentOS's `sshd_config.d/10-agentos.conf` sets neither. |
| PyPI | `pip install 'mcp>=1.28,<2'` vs unpinned in a trixie container | An unpinned `mcp` resolves to 2.x, where `mcp.server.fastmcp` is gone. Keep `<2`, as the image already does. PyYAML 6.0.3. |

All code in this plan was run while writing it:
- **pytest:** 61 tests, on macOS (Python 3.14) and in a `debian:trixie` container (Python 3.13); the per-task stages give 47 after Task 5, 59 after Task 6, and 61 after Task 7.
- **vitest:** server 98 passed and 1 skipped, UI 18. Staged server states give 90+1 after Task 3, 91+1 after Task 4, and 98+1 after Task 8. Both packages pass `tsc` and the UI builds.
- **bash:** `wrapper_test.sh`, `solenta_pair_test.sh`, `bridge_test.sh` (the bridge also under macOS bash 3.2) and `env_test.sh`.
- **shellcheck:** every new or changed script is `shellcheck -S warning` clean.
- **Not run while writing:** the image build and the in-VM checks. Tasks 2 and 9 run them.

## Spec adjustments (with evidence)

1. **`Restart=always`, not `on-failure`, plus `RestartSec=5`.** Solenta's upgrade stops the old build with `pkill -TERM`. For `Restart=on-failure`, SIGTERM is a clean exit (systemd.service: SIGHUP, SIGINT, SIGTERM and SIGPIPE are clean), so the unit would not bring up the new binary. With `always`, the restart lands after Solenta's rename; it moves the directory within about 1 s of the old process exiting. Verified on systemd 257 (fact table). `KillMode=process` is kept.
2. **The `.path` unit uses `PathChanged=`, not a level trigger.** `PathExists=` re-starts the service each time it stops while the file exists, and loops into the start limit (verified).
3. **`ExecCondition` skips the start when 4620 already answers.** Solenta may `nohup` its own copy in a restart gap. The single-instance lock would make the unit's copy exit 0 forever. The skip doesn't trigger `Restart=` (verified). The `ponytail:` comment in the unit names the ceiling.
4. **`ExecStart` is a fixed, root-owned launcher** (`/usr/local/lib/agentos/solenta-start`) that execs whichever of the two install paths exists, with fixed arguments. This is the spec's `<bin>`. It has no PATH lookup and no input: the unit runs nothing but the installed Solenta binary.
5. **The CI step environment also has `HOME` and `LANG`**, and `PATH` includes the agent's tool dirs (`~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`). npm, cargo and go don't work without `HOME`. Neither carries a secret. Inside a CI step (`AGENTOS_CI_RUN` set), `load-secrets.sh` exports no keys, so a step that runs `claude` through a wrapper still gets none.
6. **The checkout is always `git clone --shared --no-checkout` plus `checkout --detach <commit>`,** for work trees as well as bare repos (the spec offers worktree "or" clone). It never touches the source repo's worktree list.
7. **"No CI configuration found" is status `error`** (not `failed`). `failed` means a step failed; `error` means the run couldn't run. The hint is in `run.json` `error`, in `ci_wait`'s `log_tail`, and in `agentos-ci logs`.
8. **The 4 hex digits of the run id count up within a second** (0000, 0001, …) under a flock, which makes ids strictly monotonic without waiting.
9. **The journal stream had no backpressure.** "Same stream pattern and backpressure as the journal" is implemented by adding the terminal's pause/resume backpressure to the shared `streamToSocket`, so the journal gains it too.
10. **The bridge has no OpenSSH fallback over the tailnet.** Tailscale SSH serves `-R` (loopback-only binds) when the policy allows it. With `--ssh` on, port 22 on the tailnet address isn't OpenSSH anyway. The documented fallback is the LAN (`AGENTOS_LAN_SSH=1`, `install agent@<LAN address>`). The manual Mode B test confirms the forward under a real policy.
11. **The skill goes to four places:**
    - `~/.claude/skills/agentos-ci/SKILL.md` and `~/.grok/skills/agentos-ci/SKILL.md`: whole files with frontmatter, and a marked block inside;
    - managed blocks appended to `~/.codex/AGENTS.md` and `~/.config/opencode/AGENTS.md`.

    opencode also reads `~/.claude/skills`, so it sees the skill twice, which is harmless. A skill file whose markers the user removed is left alone ("kept"). Codex's `agentos-ci` entry gets `tool_timeout_sec = 1800`, because its default 300 s would cut `ci_wait` off. For every CLI, the skill says to call `ci_wait` again if it returns early.
12. **`agentos-ci-mcp` is a launcher with no arguments,** so `register-mcp` keeps one config shape (`command = "…"`) for all four CLIs.
13. **The pairing CLI** is `agentos-config solenta [PATH]`, plus `agentos-config solenta clone URL NAME` for the clone step. The web card clones through the refactored sessions code (`cloneRepo`); the CLI clone in `solenta-pair` uses the same allowlist regex and `--`.
14. **Container steps leave root-owned files** in the checkout (no userns-remap on this box). After the run, the run's own image deletes them (`find /w -mindepth 1 -delete`), and then the checkout is removed.
15. **`ci.yml` step names are restricted** to `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`, because they name the log files. Image references can't start with `-`.
16. **`AGENTOS_CI_MAX_PARALLEL`** lives in `agentos.env`, which is root-only. Firstboot publishes it as `/etc/agentos/ci.conf` (`MAX_PARALLEL=`, world-readable), like `desktop.conf`.

## File map

```
mkosi.extra/usr/local/lib/agentos/load-secrets.sh      NEW  shared secrets parser + AGENTOS_USER_DIRS (sh)
mkosi.extra/etc/profile.d/agentos.sh                   MOD  sources load-secrets.sh
mkosi.extra/usr/local/lib/agentos/cli-wrapper          NEW  wrapper for claude/codex/opencode/grok
mkosi.extra/usr/local/bin/{claude,codex,opencode,grok} NEW  symlinks -> ../lib/agentos/cli-wrapper
mkosi.conf.d/40-solenta.conf                           NEW  Electron runtime libraries (trixie names)
mkosi.extra/usr/local/lib/agentos/solenta-start        NEW  ExecStart launcher (fixed paths and args)
mkosi.extra/etc/systemd/system/agentos-solenta.service NEW  Mode A unit
mkosi.extra/etc/systemd/system/agentos-solenta.path    NEW  PathChanged trigger
mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset  MOD  enable agentos-solenta.path
mkosi.extra/usr/local/lib/agentos/env.sh               MOD  validate AGENTOS_SOLENTA, AGENTOS_CI_MAX_PARALLEL
mkosi.extra/usr/local/sbin/agentos-firstboot           MOD  5c Solenta units, 5d ci.conf, warning text
mkosi.extra/usr/local/lib/agentos/solenta-pair         NEW  pairing facts + preflight (JSON), clone
mkosi.extra/usr/local/bin/agentos-config               MOD  `solenta [PATH]`, `solenta clone URL NAME`, menu item
tools/solenta-bridge                                   NEW  Mac-side ssh -R bridge + launchd install
mkosi.extra/usr/local/lib/agentos/ci/main.py           NEW  entry point
mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/{__init__,pipeline,runs,cli,remotes,skill,mcp_server}.py  NEW
mkosi.extra/usr/local/lib/agentos/ci/post-receive      NEW  shared push hook
mkosi.extra/usr/local/lib/agentos/ci/skill.md          NEW  the agentos-ci skill text (spec's agentos-ci.md)
mkosi.extra/usr/local/bin/agentos-ci, agentos-ci-mcp   NEW  launchers
mkosi.extra/usr/local/lib/agentos/register-mcp         MOD  register both servers, install the skill
mkosi.prepare.chroot                                   MOD  pyyaml, act (pinned), bridge copy
mkosi.finalize.chroot                                  MOD  manifest (act), invariants
web/server/src/{actions,sessions,solenta,ci,system,settings,app}.ts   MOD/NEW
web/server/test/{solenta,ci}.test.ts NEW; {helpers,system}.test.ts MOD
web/ui/src/pages/CI.tsx, components/{SolentaCard,Copy}.tsx NEW; App, Overview, Settings, types, format, style MOD
web/ui/test/{CI,SolentaCard}.test.tsx NEW; Settings.test.tsx MOD
test/wrapper_test.sh, test/solenta_pair_test.sh, test/bridge_test.sh   NEW  bash unit tests
test/env_test.sh                                       MOD  AGENTOS_LIB, new settings
test/ci/{conftest,test_pipeline,test_runs,test_cli,test_remotes_hook,test_skill_mcp}.py  NEW  pytest
test/checks/97-solenta.sh, test/checks/98-ci.sh, test/ci_mcp_client.py NEW
test/web_ws.mjs, test/web_e2e.mjs                      MOD  cilog mode; CI page + Solenta card
.github/workflows/build.yml                            MOD  shellcheck list, bash tests, pytest
docs/solenta-and-ci.md                                 NEW  Mode A first, Mode B + bridge, security, CI
```

## Working locally

- **Python tests** run on the Mac. Create the venv once:
  ```
  python3 -m venv /tmp/agentos-ci-venv && /tmp/agentos-ci-venv/bin/pip install -q pytest 'pyyaml>=6,<7' 'mcp>=1.28,<2'
  ```
  Then run `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci`. `mcp` must stay `<2` (fact table).
- **Bash unit tests** need bash ≥ 4.4 (the wrapper uses empty arrays under `set -u`), so run them on devvm through `devvm.sh sh`. `tools/solenta-bridge` and `test/bridge_test.sh` also run on the Mac's bash 3.2. devvm has no `jq`, so install it once, as build-host tooling like shellcheck: `ssh root@devvm 'apt-get install -y jq'`. CI installs it in "Host setup".
- **Web tests** run on the Mac with Node ≥ 22.22 (`~/.local/bin/node`): `npx vitest run` in `web/server` and `web/ui`.
- **shellcheck** runs on devvm: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning <files>'`.

---
### Task 1: Shared secrets parser and the CLI wrappers

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/load-secrets.sh`, `mkosi.extra/usr/local/lib/agentos/cli-wrapper` (mode 755)
- Create: symlinks `mkosi.extra/usr/local/bin/{claude,codex,opencode,grok}` → `../lib/agentos/cli-wrapper`
- Modify: `mkosi.extra/etc/profile.d/agentos.sh` (whole file), `mkosi.finalize.chroot` (one invariant)
- Test: `test/wrapper_test.sh` (new, mode 755), `test/env_test.sh` (one line)

**Interfaces:**
- Consumes: `~/.config/agentos/secrets.env` (written by firstboot and agentos-config).
- Produces:
  - `load-secrets.sh` (POSIX sh, sourced) sets `AGENTOS_USER_DIRS="$HOME/.local/bin $HOME/.cargo/bin $HOME/.bun/bin $HOME/.opencode/bin $HOME/.grok/bin"` and exports the `KEY=value` lines, **unless `AGENTOS_CI_RUN` is set**. `AGENTOS_LIB` (default `/usr/local/lib/agentos`) locates it, so tests can run it from the repo.
  - `/usr/local/bin/<cli>` → `cli-wrapper`:
    - for user agent (`AGENTOS_AGENT_USER` overrides the name, tests only), it loads the keys and execs the first executable `<dir>/<cli>` over `AGENTOS_USER_DIRS` and then `$PATH`, skipping anything whose `readlink -f` is the wrapper itself;
    - with `AGENTOS_WHICH=1`, it prints that path instead of exec-ing it (the preflight in Task 3 uses this);
    - with no binary found, it prints `agentos: <cli> is not installed for user <user>` and exits 127.

- [ ] **Step 1: Write the failing test**

`test/wrapper_test.sh`:
```bash
#!/bin/bash
# Unit test for the CLI wrappers (cli-wrapper + load-secrets.sh), run as any user: AGENTOS_AGENT_USER
# names the current user as "the agent". Needs bash >= 4.4.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
LIB=$R/mkosi.extra/usr/local/lib/agentos
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
h=$d/home; mkdir -p "$h/.local/bin" "$h/.grok/bin" "$h/.config/agentos" "$d/bin" "$d/bin2" "$d/sys"
printf 'ANTHROPIC_API_KEY=sk-ant-1==\nXAI_API_KEY=xai-2\nnot a line\nlower=x\n' > "$h/.config/agentos/secrets.env"
for c in claude codex opencode grok; do ln -s "$LIB/cli-wrapper" "$d/bin/$c"; done
ln -s "$LIB/cli-wrapper" "$d/bin2/codex"                       # a second wrapper copy elsewhere on PATH
printf '#!/bin/sh\necho "real-claude key=$ANTHROPIC_API_KEY args=$*"\n' > "$h/.local/bin/claude"
printf '#!/bin/sh\necho "real-grok xai=$XAI_API_KEY"\n' > "$h/.grok/bin/grok"
printf '#!/bin/sh\necho "system-opencode key=${ANTHROPIC_API_KEY:-none}"\n' > "$d/sys/opencode"
chmod +x "$h/.local/bin/claude" "$h/.grok/bin/grok" "$d/sys/opencode"
me=$(id -un)
run() { env -i HOME="$h" PATH="$d/bin:$d/bin2:$d/sys:/usr/bin:/bin" AGENTOS_LIB="$LIB" "$@"; }
as_agent() { run AGENTOS_AGENT_USER="$me" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# agent: keys loaded (trailing "=" kept), real binary from the tool dirs, argv passed through
[ "$(as_agent bash -c 'claude -p "a b"')" = 'real-claude key=sk-ant-1== args=-p a b' ] || fail claude
[ "$(as_agent bash -c grok)" = 'real-grok xai=xai-2' ] || fail grok
# found on PATH (after skipping the wrapper itself), still with keys
[ "$(as_agent bash -c opencode)" = 'system-opencode key=sk-ant-1==' ] || fail opencode-path
# missing everywhere: no self-loop (two wrapper copies on PATH), clear message, 127
set +e; out=$(as_agent timeout 5 bash -c codex 2>&1); rc=$?; set -e
[ "$rc" = 127 ] && [ "$out" = "agentos: codex is not installed for user $me" ] || fail "codex rc=$rc out=$out"
# AGENTOS_WHICH prints the resolved binary
[ "$(as_agent AGENTOS_WHICH=1 bash -c claude)" = "$h/.local/bin/claude" ] || fail which
set +e; as_agent AGENTOS_WHICH=1 bash -c codex 2>/dev/null; rc=$?; set -e; [ "$rc" = 127 ] || fail which-missing
# inside a CI run: no keys from secrets.env
[ "$(as_agent AGENTOS_CI_RUN=x bash -c claude)" = 'real-claude key= args=' ] || fail ci
# another user: no keys, no agent tool dirs, only their own PATH
[ "$(run AGENTOS_AGENT_USER=someone-else bash -c opencode)" = 'system-opencode key=none' ] || fail other-user
set +e; out=$(run AGENTOS_AGENT_USER=someone-else bash -c claude 2>&1); rc=$?; set -e
[ "$rc" = 127 ] && [[ $out == "agentos: claude is not installed for user $me" ]] || fail "other-user claude: $out"
# profile.d shares the parser: same keys and tool dirs, under sh and bash
for sh in sh bash; do
  got=$(HOME=$h AGENTOS_LIB=$LIB $sh -c '. "$1"; printf "%s|%s" "$ANTHROPIC_API_KEY" "$PATH"' sh "$R/mkosi.extra/etc/profile.d/agentos.sh")
  [[ $got == "sk-ant-1==|$h/.grok/bin:$h/.local/bin:"* ]] || fail "profile.d ($sh): $got"
done
echo "wrapper OK"
```

- [ ] **Step 2: Run it to see it fail**

Run: `chmod 755 test/wrapper_test.sh && .superpowers/sdd/devvm.sh sh 'test/wrapper_test.sh'`
Expected: a non-zero exit. The symlinks point at a missing `cli-wrapper`, so the first assertion prints `FAIL: claude`.

- [ ] **Step 3: Write the shared parser, the wrapper and the symlinks**

`mkosi.extra/usr/local/lib/agentos/load-secrets.sh`:
```bash
# shellcheck shell=sh
# AgentOS: the agent's tool directories and API keys. Sourced (never executed) by
# /etc/profile.d/agentos.sh and by the CLI wrappers in /usr/local/bin (cli-wrapper). POSIX sh:
# profile.d also runs under dash. Sets AGENTOS_USER_DIRS and exports the keys in secrets.env.
# shellcheck disable=SC2034 # read by the scripts that source this file
AGENTOS_USER_DIRS="$HOME/.local/bin $HOME/.cargo/bin $HOME/.bun/bin $HOME/.opencode/bin $HOME/.grok/bin"

# Keys are parsed, never sourced: values are data, not shell. A CI step (agentos-ci sets
# AGENTOS_CI_RUN) gets only the keys its repo lists under secrets:, so none from here.
if [ -z "${AGENTOS_CI_RUN:-}" ] && [ -r "$HOME/.config/agentos/secrets.env" ]; then
  # Split on the first "=" by hand: IFS='=' read would drop a trailing "=" (base64 padding).
  while IFS= read -r _ag_l || [ -n "$_ag_l" ]; do
    _ag_k=${_ag_l%%=*}; _ag_v=${_ag_l#*=}
    case $_ag_l in *=*) ;; *) continue ;; esac
    case $_ag_k in ''|[!A-Z_]*|*[!A-Z0-9_]*) continue ;; esac
    export "$_ag_k=$_ag_v"
  done < "$HOME/.config/agentos/secrets.env"
  unset _ag_l _ag_k _ag_v
fi
```

`mkosi.extra/etc/profile.d/agentos.sh` (whole file; the PATH loop and the parser now come from `load-secrets.sh`, and the tty1 block is unchanged):
```bash
# shellcheck shell=sh
# AgentOS: user toolchain paths and API keys for the agent user (shared with the CLI wrappers).
# shellcheck source=../../usr/local/lib/agentos/load-secrets.sh
. "${AGENTOS_LIB:-/usr/local/lib/agentos}/load-secrets.sh"
for d in $AGENTOS_USER_DIRS; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
unset d
export PATH

# AgentOS: terminal console mode — full-screen terminal on tty1 after login.
if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ "$(id -un)" = agent ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
   grep -qx 'AGENTOS_CONSOLE=terminal' /etc/agentos/console.mode 2>/dev/null && [ -e /dev/dri/card0 ]; then
  # No exec: if cage cannot start (no GPU/seat), fall back to this shell instead of a login loop.
  cage -- foot -e tmux new -A -s main
fi
```

`mkosi.extra/usr/local/lib/agentos/cli-wrapper`:
```bash
#!/bin/bash
# AgentOS: /usr/local/bin/{claude,codex,opencode,grok} are symlinks to this file, so the CLIs
# resolve and see their API keys in a non-login, non-interactive shell too (ssh host 'claude …',
# as Solenta runs them), where /etc/profile.d never runs. For user agent it loads the keys and
# execs the real CLI from the agent's tool directories, then PATH; anyone else gets their own
# PATH. Any candidate that resolves back to this file is skipped, so it can never exec itself.
# AGENTOS_WHICH=1 prints the binary it would run instead (the Solenta preflight uses it).
set -euo pipefail
cli=${0##*/}
self=$(readlink -f "$0")
user=$(id -un)
dirs=()
if [ "$user" = "${AGENTOS_AGENT_USER:-agent}" ]; then
  : "${HOME:=/home/agent}"
  export HOME
  # shellcheck source=load-secrets.sh
  . "${AGENTOS_LIB:-/usr/local/lib/agentos}/load-secrets.sh"
  read -ra dirs <<< "$AGENTOS_USER_DIRS"
fi
IFS=: read -ra path_dirs <<< "${PATH:-/usr/bin:/bin}"
for d in "${dirs[@]}" "${path_dirs[@]}"; do
  c=${d:-.}/$cli
  [ -n "$d" ] && [ -f "$c" ] && [ -x "$c" ] || continue
  [ "$(readlink -f "$c")" = "$self" ] && continue
  if [ -n "${AGENTOS_WHICH:-}" ]; then printf '%s\n' "$c"; exit 0; fi
  # shellcheck disable=SC2093 # exec replaces this process; the loop only continues past skipped candidates
  exec "$c" "$@"
done
echo "agentos: $cli is not installed for user $user" >&2
exit 127
```

```bash
chmod 755 mkosi.extra/usr/local/lib/agentos/cli-wrapper
for c in claude codex opencode grok; do ln -s ../lib/agentos/cli-wrapper "mkosi.extra/usr/local/bin/$c"; done
```

`agentos-update`, `finalize` and the smoke checks' `vml` still see the real binaries first: profile.d puts the agent's tool dirs ahead of `/usr/local/bin`.

- [ ] **Step 4: Point `env_test.sh` at the repo copy of the parser**

In `test/env_test.sh`, find:
```bash
  got=$(HOME=$h $sh -c '. "$1"; printf "%s|%s|%s" "$PAD_TOKEN" "$PAD1_TOKEN" "$NOEOL_TOKEN"' sh "$(dirname "$0")/../mkosi.extra/etc/profile.d/agentos.sh")
```
Replace with:
```bash
  got=$(HOME=$h AGENTOS_LIB="$(dirname "$0")/../mkosi.extra/usr/local/lib/agentos" $sh -c '. "$1"; printf "%s|%s|%s" "$PAD_TOKEN" "$PAD1_TOKEN" "$NOEOL_TOKEN"' sh "$(dirname "$0")/../mkosi.extra/etc/profile.d/agentos.sh")
```

- [ ] **Step 5: Guard the symlinks in the image**

In `mkosi.finalize.chroot`, find:
```bash
if [ -e /etc/agentos/mcp-token ]; then fail "mcp-token baked into image (first-boot-only secret)"; fi
```
Replace with:
```bash
if [ -e /etc/agentos/mcp-token ]; then fail "mcp-token baked into image (first-boot-only secret)"; fi
for c in claude codex opencode grok; do
  [ "$(readlink -f "/usr/local/bin/$c")" = /usr/local/lib/agentos/cli-wrapper ] || fail "/usr/local/bin/$c is not the CLI wrapper"
done
```

- [ ] **Step 6: Run the tests and shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'test/wrapper_test.sh && test/env_test.sh && shellcheck -S warning mkosi.extra/usr/local/lib/agentos/cli-wrapper mkosi.extra/usr/local/lib/agentos/load-secrets.sh mkosi.extra/etc/profile.d/agentos.sh test/wrapper_test.sh test/env_test.sh mkosi.finalize.chroot && echo SC-OK'`
Expected:
```
wrapper OK
env.sh OK
profile.d OK
validate_setting OK
SC-OK
```

- [ ] **Step 7: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/load-secrets.sh mkosi.extra/usr/local/lib/agentos/cli-wrapper \
  mkosi.extra/usr/local/bin/claude mkosi.extra/usr/local/bin/codex mkosi.extra/usr/local/bin/opencode mkosi.extra/usr/local/bin/grok \
  mkosi.extra/etc/profile.d/agentos.sh mkosi.finalize.chroot test/wrapper_test.sh test/env_test.sh
git commit -m "feat(image): CLI wrappers load API keys in non-login shells; one shared secrets parser"
```

---

### Task 2: Mode A: Electron libraries, `agentos-solenta` units, `AGENTOS_SOLENTA`

**Files:**
- Create: `mkosi.conf.d/40-solenta.conf`, `mkosi.extra/usr/local/lib/agentos/solenta-start` (mode 755), `mkosi.extra/etc/systemd/system/agentos-solenta.service`, `mkosi.extra/etc/systemd/system/agentos-solenta.path`
- Modify: `mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset`, `mkosi.extra/usr/local/lib/agentos/env.sh`, `mkosi.extra/usr/local/sbin/agentos-firstboot`
- Test: `test/env_test.sh` (one line), `test/checks/97-solenta.sh` (new; Task 9 appends the Mode B checks)

**Interfaces:**
- Consumes: Solenta's Remote Connections install layout (fact table): `~agent/solenta/{solenta,solenta-nightly}`, renamed into place.
- Produces:
  - the units `agentos-solenta.service` (`User=agent`, `Restart=always`, `KillMode=process`, loopback 4620) and `agentos-solenta.path`;
  - the setting `AGENTOS_SOLENTA` (`0|1`, default 1), validated by `validate_setting`.
  - Task 3's `solenta-pair` reads `systemctl is-enabled agentos-solenta.path`, `systemctl is-active agentos-solenta.service`, `~/solenta/resources/app/package.json` and `~/.config/Solenta/web-token` (existence only).

- [ ] **Step 1: Write the failing tests**

In `test/env_test.sh`, find:
```bash
ok SOME_OTHER_KEY anything
```
Replace with:
```bash
ok AGENTOS_SOLENTA 0; ok AGENTOS_SOLENTA 1; bad AGENTOS_SOLENTA yes
ok SOME_OTHER_KEY anything
```

`test/checks/97-solenta.sh` (the Mode A part):
```bash
# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

# --- Mode A: Solenta headless on the box -------------------------------------------------------
SOLENTA_LIBS='libnss3 libnspr4 libgtk-3-0t64 libgbm1 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64
  libatspi2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libxfixes3
  libpango-1.0-0 libcairo2 libdbus-1-3 libexpat1 libxext6 libx11-6 libxcb1 libglib2.0-0t64'
check_solenta_libs_installed() {
  # shellcheck disable=SC2086 # word-split the list on purpose
  test "$(vm "dpkg-query -W -f '\${db:Status-Status}\n' $(echo $SOLENTA_LIBS) | grep -cx installed")" = 23
}
check_solenta_units_idle_without_install() {
  # Guest-side proof first: the units exist and are enabled; then, with no ~/solenta, inactive.
  vm 'systemctl is-enabled --quiet agentos-solenta.path && systemctl is-enabled --quiet agentos-solenta.service &&
      systemctl is-active --quiet agentos-solenta.path && test ! -e ~/solenta &&
      sudo systemctl start agentos-solenta.service &&
      test "$(systemctl show agentos-solenta.service -p ConditionResult --value)" = no &&
      ! systemctl is-active --quiet agentos-solenta.service'
}
# A stand-in for the Linux build: answers on --serve-web=PORT through python's http.server. It
# stays the parent of the server (no exec), so its own command line keeps Solenta's pkill pattern.
SOLENTA_STUB='#!/bin/bash
port=4620; for a in "$@"; do case $a in --serve-web=*) port=${a#*=};; esac; done
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 & child=$!
trap '"'"'kill $child; exit 0'"'"' TERM
wait'
solenta_install_stub() {  # the way Solenta installs: unpack beside, then rename into place
  vm "rm -rf ~/.solenta-new ~/solenta && mkdir -p ~/.solenta-new/pkg && printf '%s\n' '$SOLENTA_STUB' > ~/.solenta-new/pkg/solenta &&
      chmod +x ~/.solenta-new/pkg/solenta && mv ~/.solenta-new/pkg ~/solenta && rm -rf ~/.solenta-new"
}
solenta_cleanup() { vm 'sudo systemctl stop agentos-solenta.service; rm -rf ~/solenta ~/solenta.old'; }
check_solenta_stub_survives_logout_and_pkill() {
  local rc=0 pid1 pid2
  solenta_install_stub &&
  vm 'for _ in $(seq 1 30); do curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && exit 0; sleep 1; done; exit 1' &&
  pid1=$(vm 'systemctl show agentos-solenta.service -p MainPID --value') && test "$pid1" -gt 0 &&
  # A new SSH session (the last one has logged out): the same process still serves.
  test "$(vm 'systemctl show agentos-solenta.service -p MainPID --value')" = "$pid1" &&
  vm 'curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && ps -o args= -p "$(systemctl show agentos-solenta.service -p MainPID --value)" | grep -q "^/bin/bash /home/agent/solenta/solenta --headless --serve-web=4620 --no-sandbox$"' &&
  # Solenta's upgrade stops the old build exactly like this; Restart=always brings one back.
  vm 'pkill -TERM -f "$HOME/solenta/solenta[a-z-]* --headless"' &&
  vm 'for _ in $(seq 1 30); do sleep 1; p=$(systemctl show agentos-solenta.service -p MainPID --value)
        [ "$p" -gt 0 ] && [ "$p" != '"$pid1"' ] && curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && exit 0; done; exit 1' || rc=1
  pid2=$(vm 'systemctl show agentos-solenta.service -p MainPID --value') || rc=1
  [ "$pid2" != "$pid1" ] || rc=1
  solenta_cleanup
  return "$rc"
}
check_solenta_upgrade_rename_restarts() {
  # An upgrade renames a new ~/solenta into place: the .path unit (PathChanged) starts the service.
  local rc=0
  vm 'sudo systemctl stop agentos-solenta.service' && solenta_install_stub &&
  vm 'for _ in $(seq 1 30); do systemctl is-active --quiet agentos-solenta.service && exit 0; sleep 1; done; exit 1' || rc=1
  solenta_cleanup
  return "$rc"
}
check_solenta_skips_when_port_taken() {
  # Solenta's own nohup copy already serves 4620: the unit stays out of the way (no restart loop).
  local rc=0
  solenta_install_stub && vm 'sudo systemctl stop agentos-solenta.service &&
    (setsid python3 -m http.server 4620 --bind 127.0.0.1 </dev/null >/dev/null 2>&1 &) &&
    for _ in $(seq 1 20); do curl -s -o /dev/null -m 1 http://127.0.0.1:4620/ && break; sleep 0.5; done &&
    n=$(systemctl show agentos-solenta.service -p NRestarts --value) &&
    sudo systemctl start agentos-solenta.service; sleep 8
    ! systemctl is-active --quiet agentos-solenta.service &&
    test "$(systemctl show agentos-solenta.service -p NRestarts --value)" = "$n"' || rc=1
  vm 'pkill -f "http.server 4620" || true'
  solenta_cleanup
  return "$rc"
}
check_solenta_setting_off_and_on() {
  local rc=0
  vm 'sudo agentos-config set AGENTOS_SOLENTA 0 && sudo agentos-config apply &&
      ! systemctl is-enabled --quiet agentos-solenta.path && ! systemctl is-enabled --quiet agentos-solenta.service' || rc=1
  vm 'sudo agentos-config set AGENTOS_SOLENTA 1 && sudo agentos-config apply &&
      systemctl is-enabled --quiet agentos-solenta.path && systemctl is-active --quiet agentos-solenta.path' || rc=1
  return "$rc"
}
check_solenta_real_tarball() {
  # Optional: the real Linux build, installed by the same steps remoteConnections.js runs, answers
  # on 4620 under the unit. Needs GitHub; SKIP offline.
  local url sha
  vm 'curl -s -o /dev/null -m 10 https://api.github.com' || { echo "SKIP: no network to api.github.com"; return 0; }
  read -r url sha < <(vm 'curl -fsS -m 20 https://api.github.com/repos/currentbits/solenta/releases/tags/v0.26.0 |
    jq -r ".assets[] | select(.name | test(\"linux-x64\")) | \"\(.browser_download_url) \(.digest | ltrimstr(\"sha256:\"))\""') ||
    { echo "SKIP: no v0.26.0 linux-x64 release asset"; return 0; }
  local rc=0
  vm "rm -rf ~/.solenta-new && mkdir -p ~/.solenta-new && curl -fsSL -o ~/.solenta-download.tar.gz '$url' &&
      test \"\$(sha256sum ~/.solenta-download.tar.gz | cut -d ' ' -f 1)\" = '$sha' &&
      tar -xzf ~/.solenta-download.tar.gz -C ~/.solenta-new && rm -f ~/.solenta-download.tar.gz &&
      for d in ~/.solenta-new/*/; do [ -x \"\$d/solenta\" ] && src=\${d%/}; done && rm -rf ~/solenta && mv \"\$src\" ~/solenta &&
      test -z \"\$(ldd ~/solenta/solenta | grep 'not found')\" &&
      for _ in \$(seq 1 90); do curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && exit 0; sleep 1; done; exit 1" || rc=1
  vm 'test -s ~/.config/Solenta/web-token && /usr/local/lib/agentos/solenta-pair status | jq -e ".modeA.version == \"0.26.0\" and .modeA.webToken"' >/dev/null || rc=1
  vm 'sudo systemctl stop agentos-solenta.service; rm -rf ~/solenta ~/.solenta-new ~/.config/Solenta ~/.solenta-headless.log'
  return "$rc"
}
```

- [ ] **Step 2: Run the unit test to see it fail**

Run: `.superpowers/sdd/devvm.sh sh 'test/env_test.sh'`
Expected: `should reject AGENTOS_SOLENTA='yes'`, exit 1.

- [ ] **Step 3: Add the libraries, the launcher and the units**

`mkosi.conf.d/40-solenta.conf`:
```ini
# Electron runtime libraries for Solenta's Linux build (Mode A: Solenta's Remote Connections
# installs it over SSH and checks it with ldd). All already arrive with Chromium and Playwright's
# deps; listed so they stay if those ever change. Trixie names (t64 ABI renames verified with
# apt-cache on Debian 13): libgtk-3-0t64, libasound2t64, libatk1.0-0t64, libatk-bridge2.0-0t64,
# libatspi2.0-0t64, libcups2t64, libglib2.0-0t64.
[Content]
Packages=
        libnss3
        libnspr4
        libgtk-3-0t64
        libgbm1
        libasound2t64
        libatk1.0-0t64
        libatk-bridge2.0-0t64
        libatspi2.0-0t64
        libcups2t64
        libdrm2
        libxkbcommon0
        libxcomposite1
        libxdamage1
        libxrandr2
        libxfixes3
        libpango-1.0-0
        libcairo2
        libdbus-1-3
        libexpat1
        libxext6
        libx11-6
        libxcb1
        libglib2.0-0t64
```

`mkosi.extra/usr/local/lib/agentos/solenta-start`:
```bash
#!/bin/bash
# ExecStart of agentos-solenta.service: exec the Solenta build that Solenta's Remote Connections
# installed in ~agent/solenta, with fixed arguments. Runs nothing else, takes no input.
set -euo pipefail
for bin in /home/agent/solenta/solenta /home/agent/solenta/solenta-nightly; do
  # Same argv as Solenta's own `nohup` start, so its pkill/pgrep patterns find this process too.
  if [ -f "$bin" ] && [ -x "$bin" ]; then exec "$bin" --headless --serve-web=4620 --no-sandbox; fi
done
echo "agentos-solenta: no Solenta in /home/agent/solenta" >&2
exit 1
```

`mkosi.extra/etc/systemd/system/agentos-solenta.service`:
```ini
[Unit]
Description=Solenta headless on 127.0.0.1:4620 (installed over SSH by Solenta Remote Connections)
After=network.target agentos-firstboot.service
ConditionPathExists=|/home/agent/solenta/solenta
ConditionPathExists=|/home/agent/solenta/solenta-nightly

[Service]
User=agent
WorkingDirectory=/home/agent
Environment=PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8
# A copy Solenta started itself (its `nohup`, during a restart gap) may already serve 4620: leave it
# be. A skipped condition does not trigger Restart=. ponytail: if that copy dies later, the next
# boot or the next Solenta upgrade brings the unit back.
ExecCondition=/bin/sh -c '! /usr/bin/curl -s -o /dev/null -m 2 http://127.0.0.1:4620/'
ExecStart=/usr/local/lib/agentos/solenta-start
SyslogIdentifier=agentos-solenta
# always, not on-failure: Solenta's upgrade stops the old build with pkill (SIGTERM, a "clean" exit
# for on-failure). 5 s lets it swap ~/solenta first (it waits up to 15 s for the old process to go).
Restart=always
RestartSec=5
# Agent sessions (tmux) Solenta starts live in this cgroup: a restart must not kill them.
KillMode=process
# Light hardening, like agentos-web: the agents it runs use sudo and work in /home/agent.
NoNewPrivileges=no
ProtectHome=no
PrivateTmp=no

[Install]
WantedBy=multi-user.target
```

`mkosi.extra/etc/systemd/system/agentos-solenta.path`:
```ini
[Unit]
Description=Start agentos-solenta when Solenta Remote Connections installs or upgrades Solenta

[Path]
# PathChanged (edge), not PathExists (level): a level trigger re-starts the service every time it
# stops while the file exists, and the ExecCondition skip would loop until the start limit.
# Verified on systemd 257: renaming a new ~/solenta into place fires these.
PathChanged=/home/agent/solenta/solenta
PathChanged=/home/agent/solenta/solenta-nightly
Unit=agentos-solenta.service

[Install]
WantedBy=paths.target
```

In `mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset`, find `enable agentos-reap-desktops.timer` and add a line after it:
```
enable agentos-solenta.path
```
The service is already covered by `enable agentos-*.service`.

- [ ] **Step 4: The setting: validation and firstboot**

In `mkosi.extra/usr/local/lib/agentos/env.sh`, find:
```bash
    AGENTOS_LAN_SSH|AGENTOS_AUTO_REBOOT|AGENTOS_WEB) re='^[01]$'; want='0 or 1' ;;
```
Replace with:
```bash
    AGENTOS_LAN_SSH|AGENTOS_AUTO_REBOOT|AGENTOS_WEB|AGENTOS_SOLENTA) re='^[01]$'; want='0 or 1' ;;
```

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, find:
```bash
# 6. Console lockout prevention last, so it sees Tailscale. It restarts getty@tty1, which is
```
Insert before it:
```bash
# 5c. Solenta Mode A (AGENTOS_SOLENTA, default on): the .path unit starts agentos-solenta when
# Solenta's Remote Connections installs it; the service's condition keeps it inactive until then.
if [ "$(env_get "$AGENTOS_ENV" AGENTOS_SOLENTA | grep -x 0 || echo 1)" = 1 ]; then
  systemctl enable --quiet agentos-solenta.path agentos-solenta.service
  systemctl start --no-block agentos-solenta.path agentos-solenta.service
else
  systemctl disable --quiet --now --no-block agentos-solenta.path agentos-solenta.service
fi

```

- [ ] **Step 5: Run the unit test and shellcheck**

Run: `chmod 755 mkosi.extra/usr/local/lib/agentos/solenta-start && .superpowers/sdd/devvm.sh sh 'test/env_test.sh && shellcheck -S warning mkosi.extra/usr/local/lib/agentos/solenta-start mkosi.extra/usr/local/sbin/agentos-firstboot mkosi.extra/usr/local/lib/agentos/env.sh test/checks/97-solenta.sh && echo SC-OK'`
Expected: `env.sh OK`, `profile.d OK`, `validate_setting OK`, `SC-OK`.

- [ ] **Step 6: Build and run the Mode A checks in the VM**

Run: `.superpowers/sdd/devvm.sh run 'mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi'`, then `.superpowers/sdd/devvm.sh wait <JOB>` until the exit code isn't 124.
Expected, among the PASS lines:
```
PASS [uefi] check_solenta_libs_installed
PASS [uefi] check_solenta_real_tarball            (or "SKIP [uefi] check_solenta_real_tarball: no network to api.github.com")
PASS [uefi] check_solenta_setting_off_and_on
PASS [uefi] check_solenta_skips_when_port_taken
PASS [uefi] check_solenta_stub_survives_logout_and_pkill
PASS [uefi] check_solenta_units_idle_without_install
PASS [uefi] check_solenta_upgrade_rename_restarts
ALL CHECKS PASSED (… skipped)
```
If `check_solenta_real_tarball` fails on `ldd`, the failure lists the missing library. Add its trixie package to `40-solenta.conf` and record the deviation.

- [ ] **Step 7: Commit**

```bash
git add mkosi.conf.d/40-solenta.conf mkosi.extra/usr/local/lib/agentos/solenta-start mkosi.extra/etc/systemd/system/agentos-solenta.service \
  mkosi.extra/etc/systemd/system/agentos-solenta.path mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset \
  mkosi.extra/usr/local/lib/agentos/env.sh mkosi.extra/usr/local/sbin/agentos-firstboot test/env_test.sh test/checks/97-solenta.sh
git commit -m "feat(solenta): Mode A: Electron libraries, agentos-solenta service and path units, AGENTOS_SOLENTA"
```

---

### Task 3: Pairing backend: `solenta-pair`, `agentos-config solenta`, the web API

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/solenta-pair` (mode 755), `web/server/src/solenta.ts`
- Modify: `mkosi.extra/usr/local/bin/agentos-config`, `web/server/src/actions.ts` (whole file), `web/server/src/sessions.ts` (extract `cloneRepo`), `web/server/src/app.ts`
- Test: `test/solenta_pair_test.sh` (new, mode 755), `web/server/test/solenta.test.ts` (new)

**Interfaces:**
- Consumes:
  - `cli-wrapper`'s `AGENTOS_WHICH=1` (Task 1);
  - `systemctl` states of Task 2's units;
  - `tailscale status --json`;
  - `/etc/ssh/ssh_host_*_key.pub`.
- Produces:
  - `solenta-pair status [-- PATH]` prints JSON:
    ```
    {host, remoteHost: "agent@<host>", remotePath: string|null, tailscaleSsh: bool,
     hostKeys: [{type, fingerprint}], keyscan: "ssh-keyscan -t ed25519 <host> >> ~/.ssh/known_hosts",
     modeA: {enabled: bool, service: string, version: string|null, webToken: bool},
     preflight: [{item, ok, detail}]}
    ```
    The preflight items are `git bash node claude codex opencode grok`, `.solenta writable`, and `git checkout` (only with PATH).
  - `solenta-pair clone URL NAME` clones into `~/work/NAME` and prints the path.
  - `agentos-config solenta [PATH]` and `agentos-config solenta clone URL NAME`.
  - Web: `GET /api/solenta[?path=]` returns that JSON; `POST /api/solenta/clone {repo, name}` returns `201 {path}`.
  - `cloneRepo(deps, repo, name, login): Promise<string>`, exported from `sessions.ts`. It throws `HttpError(400, …, 'repo' | 'name')`.
  - The action `{name: 'solenta-status', path?}` runs `[SOLENTA_PAIR, 'status', '--', path]` as agent, with no sudo.
  - `test/env` overrides: `TAILSCALE`, `AGENTOS_SSH_DIR`, `AGENTOS_WRAPPER`, `AGENTOS_PREFLIGHT_PATH`.

- [ ] **Step 1: Write the failing tests**

`test/solenta_pair_test.sh`:
```bash
#!/bin/bash
# Unit test for solenta-pair against fake host keys, a fake tailscale and fake CLIs.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
P=$R/mkosi.extra/usr/local/lib/agentos/solenta-pair
W=$R/mkosi.extra/usr/local/lib/agentos/cli-wrapper
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
h=$d/home; mkdir -p "$h/.config/Solenta" "$h/solenta/resources/app" "$d/ssh" "$d/bin" "$d/real" "$d/fake"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$d/ssh/ssh_host_ed25519_key"
fp=$(ssh-keygen -l -f "$d/ssh/ssh_host_ed25519_key.pub" | awk '{print $2}')
printf '#!/bin/sh\necho "{\\"Self\\":{\\"DNSName\\":\\"box.tail.ts.net.\\",\\"TailscaleIPs\\":[\\"100.64.0.9\\"],\\"sshHostKeys\\":[\\"x\\"]}}"\n' > "$d/fake/tailscale"
printf '#!/bin/sh\necho inactive\nexit 3\n' > "$d/fake/systemctl"
echo 'SUPERSECRET-web-token' > "$h/.config/Solenta/web-token"
echo '{"version":"0.26.0"}' > "$h/solenta/resources/app/package.json"
# The wrappers come first on the preflight PATH; the real CLIs sit behind them (grok is missing).
for c in claude codex opencode grok; do ln -s "$W" "$d/bin/$c"; done
for c in claude codex opencode; do printf '#!/bin/sh\n' > "$d/real/$c"; chmod +x "$d/real/$c"; done
for c in git bash; do ln -s "$(command -v "$c")" "$d/bin/$c"; done
printf '#!/bin/sh\n' > "$d/bin/node"; chmod +x "$d/bin/node"
git init -q "$h/work-repo"
chmod +x "$d/fake/"*
pair() { HOME=$h PATH="$d/fake:$PATH" TAILSCALE="$d/fake/tailscale" \
         AGENTOS_SSH_DIR="$d/ssh" AGENTOS_WRAPPER="$W" AGENTOS_PREFLIGHT_PATH="$d/bin:$d/real:/usr/bin:/bin" "$P" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(pair status -- "$h/work-repo")
! grep -q SUPERSECRET <<< "$out" || fail "token printed"
jq -e --arg fp "$fp" --arg wr "$h/work-repo" '
  .host == "box.tail.ts.net" and .remoteHost == "agent@box.tail.ts.net" and .remotePath == $wr and
  .tailscaleSsh == true and .hostKeys == [{type: "ssh-ed25519", fingerprint: $fp}] and
  .keyscan == "ssh-keyscan -t ed25519 box.tail.ts.net >> ~/.ssh/known_hosts" and
  .modeA == {enabled: false, service: "inactive", version: "0.26.0", webToken: true}' <<< "$out" >/dev/null || fail "status: $out"
jq -e --arg d "$d" '([.preflight[] | {(.item): .ok}] | add) == {git: true, bash: true, node: true, claude: true,
  codex: true, opencode: true, grok: false, ".solenta writable": true, "git checkout": true}
  and (.preflight[] | select(.item == "claude") | .detail) == "\($d)/real/claude"
  and (.preflight[] | select(.item == "grok") | .detail | test("grok is not installed"))' <<< "$out" >/dev/null || fail "preflight: $out"
pair status -- "$d" | jq -e '.preflight[] | select(.item == "git checkout") | .ok == false' >/dev/null || fail "non-repo passed"
pair status | jq -e '.remotePath == null and ([.preflight[].item] | index("git checkout") == null)' >/dev/null || fail "no path"
for bad in 'file:///etc' '-uhttps://x' 'https://a b' 'ext::sh -c id'; do
  if pair clone "$bad" demo 2>/dev/null; then fail "clone accepted $bad"; fi
done
if pair clone https://example.invalid/x.git '../x' 2>/dev/null; then fail "clone accepted a bad name"; fi
echo "solenta-pair OK"
```

`web/server/test/solenta.test.ts`:
```ts
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const PAIR = '/usr/local/lib/agentos/solenta-pair';
const STATUS = { host: 'box.ts.net', remoteHost: 'agent@box.ts.net', remotePath: null, tailscaleSsh: true, hostKeys: [],
  keyscan: 'ssh-keyscan -t ed25519 box.ts.net >> ~/.ssh/known_hosts', modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] };

describe('solenta', () => {
  it('returns solenta-pair status, with a path confined to home', async () => {
    const { deps, calls } = fakeDeps(() => ({ stdout: JSON.stringify(STATUS) }));
    mkdirSync(join(deps.home, 'work'));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/solenta', headers: H })).json()).toEqual(STATUS);
    expect(calls.at(-1)!.argv).toEqual([PAIR, 'status']);
    await app.inject({ url: `/api/solenta?path=${encodeURIComponent(join(deps.home, 'work'))}`, headers: H });
    expect(calls.at(-1)!.argv).toEqual([PAIR, 'status', '--', join(deps.home, 'work')]);
    expect((await app.inject({ url: '/api/solenta?path=/etc', headers: H })).statusCode).toBe(400);
  });

  it('clones through the sessions code: allowlisted URL, "--", ~/work/<name>, audited', async () => {
    const { deps, calls, audits } = fakeDeps((a) => {
      if (a[0] === 'git') mkdirSync(a[4], { recursive: true });
      return {};
    });
    const app = await buildApp(deps);
    const post = (payload: object) => app.inject({ method: 'POST', url: '/api/solenta/clone', headers: HM, payload });
    for (const repo of ['file:///etc', '--upload-pack=x', 'ext::sh -c id']) expect((await post({ repo, name: 'x' })).json().field).toBe('repo');
    expect((await post({ repo: 'https://example.com/a.git', name: '../x' })).json().field).toBe('name');
    expect(calls).toEqual([]);
    const r = await post({ repo: 'https://example.com/a.git', name: 'app' });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ path: join(deps.home, 'work/app') });
    expect(calls[0].argv).toEqual(['git', 'clone', '--', 'https://example.com/a.git', join(deps.home, 'work/app')]);
    expect(audits).toEqual([`${LOGIN} repo-clone ${join(deps.home, 'work/app')}`]);
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `chmod 755 test/solenta_pair_test.sh && .superpowers/sdd/devvm.sh sh 'test/solenta_pair_test.sh'`
Expected: exit 127, `solenta-pair: No such file or directory`.

Run: `cd web/server && npx vitest run test/solenta.test.ts`
Expected: FAIL. `/api/solenta` returns 404 (no route yet).

- [ ] **Step 3: Write `solenta-pair`**

`mkosi.extra/usr/local/lib/agentos/solenta-pair`:
```bash
#!/bin/bash
# Solenta pairing facts, for the web UI's Solenta card and `agentos-config solenta`. Runs as agent.
#   solenta-pair status [-- PATH]   JSON: host, remoteHost, Tailscale SSH, host key fingerprints,
#                                   the Mac's ssh-keyscan line, Mode A state, preflight (for PATH)
#   solenta-pair clone URL NAME     git clone URL into ~/work/NAME (https://, ssh:// or git@ only)
# Never prints a secret: Solenta's web token is only tested for existence.
set -euo pipefail
H=${HOME:-/home/agent}
SSH_DIR=${AGENTOS_SSH_DIR:-/etc/ssh}
WRAPPER=${AGENTOS_WRAPPER:-/usr/local/lib/agentos/cli-wrapper}
PF_PATH=${AGENTOS_PREFLIGHT_PATH:-/usr/local/bin:/usr/bin:/bin}
REPO_RE='^(https://[^[:space:]]+|git@[^[:space:]:]+:[^[:space:]]+|ssh://[^[:space:]]+)$'

item() { jq -cn --arg item "$1" --argjson ok "$2" --arg detail "$3" '{item: $item, ok: $ok, detail: $detail}'; }

# Solenta's remote command line, reproduced: non-login, non-interactive, nothing but HOME and PATH.
preflight() {
  local c out
  for c in git bash node claude codex opencode grok; do
    # shellcheck disable=SC2016 # $1/$2 expand in the inner shell
    if out=$(env -i HOME="$H" PATH="$PF_PATH" AGENTOS_WHICH=1 bash -c '
        p=$(command -v "$1") || { echo "not on PATH"; exit 1; }
        if [ "$(readlink -f "$p")" = "$2" ]; then "$1"; else echo "$p"; fi' _ "$c" "$WRAPPER" 2>&1); then
      item "$c" true "$out"
    else
      item "$c" false "$out"
    fi
  done
  if mkdir -p "$H/.solenta" 2>/dev/null && [ -w "$H/.solenta" ]; then item ".solenta writable" true "$H/.solenta"
  else item ".solenta writable" false "$H/.solenta is not writable"; fi
  if [ -n "${1:-}" ]; then
    if out=$(env -i HOME="$H" PATH="$PF_PATH" git -C "$1" rev-parse --show-toplevel 2>&1); then item "git checkout" true "$out"
    else item "git checkout" false "$out"; fi
  fi
}

status() {
  local path=${1:-} ts dns ip host tsssh keys ver token
  ts=$("${TAILSCALE:-tailscale}" status --json 2>/dev/null) || ts='{}'
  dns=$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<< "$ts" 2>/dev/null) || dns=
  ip=$(jq -r '.Self.TailscaleIPs[0] // ""' <<< "$ts" 2>/dev/null) || ip=
  host=${dns:-${ip:-$(hostname)}}
  # tailscaled lists SSH host keys for a node only while Tailscale SSH serves it.
  tsssh=$(jq '(.Self.sshHostKeys // .Self.SSH_HostKeys // []) | length > 0' <<< "$ts" 2>/dev/null) || tsssh=false
  keys=$(for f in "$SSH_DIR"/ssh_host_*_key.pub; do
           [ -r "$f" ] || continue
           read -r t _ < "$f"
           jq -cn --arg type "$t" --arg fp "$(ssh-keygen -l -f "$f" | awk '{print $2}')" '{type: $type, fingerprint: $fp}'
         done | jq -cs .)
  ver=$(jq -r '.version // ""' "$H/solenta/resources/app/package.json" 2>/dev/null) || ver=
  token=false; [ -f "${XDG_CONFIG_HOME:-$H/.config}/Solenta/web-token" ] && token=true
  jq -n --arg host "$host" --argjson tsssh "$tsssh" --argjson keys "$keys" --arg path "$path" \
        --arg enabled "$(systemctl is-enabled agentos-solenta.path 2>/dev/null || true)" \
        --arg service "$(systemctl is-active agentos-solenta.service 2>/dev/null || true)" \
        --arg ver "$ver" --argjson token "$token" --argjson preflight "$(preflight "$path" | jq -cs .)" '{
      host: $host,
      remoteHost: "agent@\($host)",
      remotePath: (if $path == "" then null else $path end),
      tailscaleSsh: $tsssh,
      hostKeys: $keys,
      keyscan: "ssh-keyscan -t ed25519 \($host) >> ~/.ssh/known_hosts",
      modeA: {enabled: ($enabled == "enabled"), service: $service, version: (if $ver == "" then null else $ver end), webToken: $token},
      preflight: $preflight
    }'
}

case "${1:-}" in
  status) shift; [ "${1:-}" = -- ] && shift; status "${1:-}" ;;
  clone)  [ $# -eq 3 ] || { echo "usage: solenta-pair clone URL NAME" >&2; exit 2; }
          [[ $2 =~ $REPO_RE ]] || { echo "repo must be an https://, ssh:// or git@ URL" >&2; exit 2; }
          [[ $3 =~ ^[a-z0-9-]{1,32}$ ]] || { echo "name must match [a-z0-9-]{1,32}" >&2; exit 2; }
          mkdir -p "$H/work"
          GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git clone -- "$2" "$H/work/$3"
          echo "$H/work/$3" ;;
  *)      sed -n 3,6p "$0" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: `agentos-config solenta`**

In `mkosi.extra/usr/local/bin/agentos-config`, find:
```bash
# Run as its own unit: firstboot ends with agentos-console-apply, which restarts getty@tty1 and
```
Insert before it:
```bash
# Solenta pairing (the same facts as the web UI's Solenta card), computed as agent by solenta-pair.
cmd_solenta() {
  local out
  out=$(runuser -u agent -- env -i HOME=/home/agent PATH=/usr/local/bin:/usr/bin:/bin \
          /usr/local/lib/agentos/solenta-pair status ${1:+-- "$1"}) || exit 1
  # shellcheck disable=SC2016 # jq program, not shell
  jq -r '
    "Solenta and \(.host)",
    "",
    "Mode A (recommended): in Solenta, Settings > Connections > Remote Connections, add \(.remoteHost).",
    "  agentos-solenta: \(.modeA.service) (\(if .modeA.enabled then "enabled" else "disabled: AGENTOS_SOLENTA=0" end)), Solenta \(.modeA.version // "not installed yet"), web token \(if .modeA.webToken then "present" else "absent" end)",
    "",
    "1. SSH access: " + (if .tailscaleSsh then "Tailscale SSH is on; your tailnet policy decides who may connect."
                         else "add the Mac'"'"'s public key: sudo agentos-config add-ssh-key \"ssh-ed25519 AAAA... you@mac\"" end),
    "   Host key fingerprints: compare them with what ssh shows on the Mac, then add the key there:",
    (.hostKeys[] | "     \(.type) \(.fingerprint)"),
    "     \(.keyscan)",
    "2. Repo: sudo agentos-config solenta clone <git URL> <name>, or use any checkout under /home/agent.",
    "3. Mode B values for the Solenta project: remoteHost = \(.remoteHost), remotePath = \(.remotePath // "/home/agent/work/<name>")",
    "4. Preflight (as Solenta runs commands: non-login, non-interactive):",
    (.preflight[] | "   \(if .ok then "PASS" else "FAIL" end)  \(.item): \(.detail)")' <<< "$out"
}

```

In the menu, find:
```bash
      mcptoken  "Show MCP HTTP bearer token" \
```
Replace with:
```bash
      mcptoken  "Show MCP HTTP bearer token" \
      solenta   "Solenta: pairing values and preflight" \
```
Then find:
```bash
      mcptoken)  whiptail --msgbox
```
Insert this line before it:
```bash
      solenta)   whiptail --scrolltext --title Solenta --msgbox "$(cmd_solenta 2>&1)" 24 76 ;;
```
At the end of the file, find:
```bash
  show-mcp-token)  cat /etc/agentos/mcp-token ;;
  *)               echo "usage: agentos-config [set KEY VALUE|-|get KEY|add-ssh-key KEY|-|remove-ssh-key FINGERPRINT|github-keys USER|password|apply|show-mcp-token]" >&2; exit 2 ;;
```
Replace with:
```bash
  show-mcp-token)  cat /etc/agentos/mcp-token ;;
  solenta)         if [ "${2:-}" = clone ]; then
                     [ $# -eq 4 ] || { echo "usage: agentos-config solenta clone URL NAME" >&2; exit 2; }
                     runuser -u agent -- env -i HOME=/home/agent PATH=/usr/local/bin:/usr/bin:/bin \
                       /usr/local/lib/agentos/solenta-pair clone "$3" "$4"
                   else
                     cmd_solenta "${2:-}"
                   fi ;;
  *)               echo "usage: agentos-config [set KEY VALUE|-|get KEY|add-ssh-key KEY|-|remove-ssh-key FINGERPRINT|github-keys USER|password|apply|show-mcp-token|solenta [PATH]|solenta clone URL NAME]" >&2; exit 2 ;;
```

- [ ] **Step 5: The web API**

`web/server/src/actions.ts` (whole file: adds `SOLENTA_PAIR`, `ABS_PATH_RE` and the `solenta-status` action):
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
export const SOLENTA_PAIR = '/usr/local/lib/agentos/solenta-pair';
const ABS_PATH_RE = /^\/[^\0\n]*$/;

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
  | { name: 'desktop-stop'; n: number }
  | { name: 'solenta-status'; path?: string };          // runs as agent (this service's user): no sudo

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
    case 'solenta-status': if (a.path !== undefined) need(ABS_PATH_RE.test(a.path), 'path');
      return [SOLENTA_PAIR, 'status', ...(a.path ? ['--', a.path] : [])];
  }
}

export async function runAction(run: Runner, a: Action, opts?: RunOpts): Promise<RunResult> {
  return run(argv(a), opts);
}
```

In `web/server/src/sessions.ts`, find:
```ts
export interface CreateBody { cli?: string; dir?: string; repo?: string; name?: string }
```
Replace with:
```ts
export interface CreateBody { cli?: string; dir?: string; repo?: string; name?: string }

// Clone an allowlisted git URL into ~/work/<name> ("--": the URL is never an option). Shared by
// new sessions and the Solenta card. Returns the checkout's real path.
export async function cloneRepo(deps: Deps, repo: string, name: string, login: string): Promise<string> {
  if (!REPO_RE.test(repo)) throw new HttpError(400, 'repo must be an https://, ssh:// or git@ URL', 'repo');
  if (!NAME_RE.test(name)) throw new HttpError(400, 'name must match [a-z0-9-]{1,32}', 'name');
  const dest = join(deps.home, 'work', name);
  await mkdir(dirname(dest), { recursive: true });
  const r = await deps.run(['git', 'clone', '--', repo, dest], {
    timeoutMs: 300_000, env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: 'ssh -o BatchMode=yes' },
  });
  if (r.code !== 0) throw new HttpError(400, `git clone failed: ${r.stderr.trim()}`);
  deps.audit(login, 'repo-clone', dest);
  return resolveDir(dest, deps.home);
}
```
Then, in `createSession`, find:
```ts
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
```
Replace with:
```ts
  if (body.repo) {
    dir = await cloneRepo(deps, body.repo, name, login);
  } else {
```

`web/server/src/solenta.ts`:
```ts
// The Solenta card: pairing facts and preflight (solenta-pair, as agent) and a repo clone through
// the sessions code. Nothing here reads a Solenta token.
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { cloneRepo, resolveDir } from './sessions.js';

export function solentaRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Querystring: { path?: string } }>('/api/solenta', async (req) => {
    const path = req.query.path ? await resolveDir(req.query.path, deps.home) : undefined;
    const r = await runAction(deps.run, { name: 'solenta-status', path }, { timeoutMs: 30_000 });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim() || 'solenta-pair failed');
    return JSON.parse(r.stdout);
  });
  app.post<{ Body: { repo?: string; name?: string } }>('/api/solenta/clone', async (req, reply) =>
    reply.code(201).send({ path: await cloneRepo(deps, String(req.body?.repo ?? ''), String(req.body?.name ?? ''), req.login) }));
}
```

In `web/server/src/app.ts`, add `import { solentaRoutes } from './solenta.js';` after `import { systemRoutes } from './system.js';`, and add `solentaRoutes(app, deps);` after `systemRoutes(app, deps);`.

- [ ] **Step 6: Run the tests, typecheck and shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'test/solenta_pair_test.sh && shellcheck -S warning mkosi.extra/usr/local/lib/agentos/solenta-pair mkosi.extra/usr/local/bin/agentos-config test/solenta_pair_test.sh && echo SC-OK'`
Expected: `solenta-pair OK`, `SC-OK`. The test prints the status JSON first.

Run: `cd web/server && npx tsc -p tsconfig.json --noEmit && npx vitest run`
Expected: `Tests  90 passed | 1 skipped (91)`. The existing session tests still pass through `cloneRepo`.

- [ ] **Step 7: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/solenta-pair mkosi.extra/usr/local/bin/agentos-config test/solenta_pair_test.sh \
  web/server/src/actions.ts web/server/src/sessions.ts web/server/src/solenta.ts web/server/src/app.ts web/server/test/solenta.test.ts
git commit -m "feat(solenta): pairing facts and preflight (solenta-pair), agentos-config solenta, /api/solenta"
```

---

### Task 4: The Mac-side bridge, its launchd agent and its download

**Files:**
- Create: `tools/solenta-bridge` (mode 755)
- Modify: `mkosi.prepare.chroot` (install a copy for download), `web/server/src/solenta.ts` (whole file), `web/server/src/app.ts` (`Deps.bridgePath`), `web/server/test/helpers.ts`
- Test: `test/bridge_test.sh` (new, mode 755), `web/server/test/solenta.test.ts` (whole file)

**Interfaces:**
- Consumes: Solenta's `orch-server.json` and `memory-server.json` (the `port` fields only).
- Produces:
  - the commands `solenta-bridge install user@box…`, `uninstall`, `run` and `ports`;
  - the functions `port_of FILE`, `ports` and `ssh_argv BOX PORT…` (sourced by the test);
  - test overrides `SOLENTA_DIR`, `SOLENTA_BRIDGE_CONF`, `SOLENTA_BRIDGE_PLIST` and `LAUNCHCTL`;
  - in the image, `/usr/local/share/agentos/solenta-bridge`;
  - `Deps.bridgePath: string` and `GET /api/solenta/bridge` (an attachment).

- [ ] **Step 1: Write the failing tests**

`test/bridge_test.sh`:
```bash
#!/bin/bash
# Unit test for tools/solenta-bridge: port parsing from sample Solenta JSON (tokens never read
# out or printed), the tunnel argv, and install/uninstall with a fake launchctl. Runs on Linux
# and on macOS's bash 3.2.
set -euo pipefail
B=$(cd "$(dirname "$0")/.." && pwd)/tools/solenta-bridge
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
TOKEN=tok-SUPERSECRET-0123456789abcdef
mkdir -p "$d/sol"
printf '{\n  "port": 53121,\n  "token": "%s"\n}\n' "$TOKEN" > "$d/sol/orch-server.json"
printf '{"dbPath":"/x/port\\"s.db","token":"%s","port":61002}' "$TOKEN" > "$d/sol/memory-server.json"
export SOLENTA_DIR=$d/sol SOLENTA_BRIDGE_CONF=$d/conf SOLENTA_BRIDGE_PLIST=$d/la/x.plist HOME=$d/home LAUNCHCTL=$d/launchctl
mkdir -p "$HOME"
printf '#!/bin/sh\necho "$*" >> %s/launchctl.log\n' "$d" > "$d/launchctl"; chmod +x "$d/launchctl"

out=$(bash -x "$B" ports 2>"$d/trace")
[ "$out" = $'53121\n61002' ] || fail "ports: $out"
if grep -q SUPERSECRET "$d/trace"; then fail "token visible in the shell trace"; fi
# shellcheck source=../tools/solenta-bridge
. "$B"
[ "$(port_of /nonexistent)" = "" ] || fail missing
printf '{"port": 99999, "token": "x"}' > "$d/big.json"; [ "$(port_of "$d/big.json")" = "" ] || fail range
printf '{"token": "x"}' > "$d/none.json"; [ "$(port_of "$d/none.json")" = "" ] || fail none
[ "$(ssh_argv agent@box.ts.net 53121 61002 | tr '\n' ' ')" = \
  "ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:53121:127.0.0.1:53121 -R 127.0.0.1:61002:127.0.0.1:61002 -- agent@box.ts.net " ] || fail argv

if bash "$B" install 'agent@box;rm -rf /' 2>/dev/null; then fail "accepted a bad box"; fi
if bash "$B" install '-oProxyCommand=x@y' 2>/dev/null; then fail "accepted an option as a box"; fi
if bash "$B" install '-x@y' 2>/dev/null; then fail "accepted a leading dash"; fi
bash "$B" install agent@box1.ts.net agent@100.64.0.2 >/dev/null
[ "$(cat "$d/conf")" = $'agent@box1.ts.net\nagent@100.64.0.2' ] || fail conf
grep -q "<string>$B</string><string>run</string>" "$d/la/x.plist" || fail plist
grep -q "bootstrap gui/$(id -u) $d/la/x.plist" "$d/launchctl.log" || fail bootstrap
if grep -rq SUPERSECRET "$d/conf" "$d/la" "$d/launchctl.log"; then fail "token written out"; fi
# The loop: one ssh per box with both forwards, retried after a drop.
mkdir -p "$d/fakebin"; : > "$d/ssh.log"
printf '#!/bin/sh\necho "$*" >> %s/ssh.log\nexit 1\n' "$d" > "$d/fakebin/ssh"; chmod +x "$d/fakebin/ssh"
PATH="$d/fakebin:$PATH" bash "$B" run 2>/dev/null & rp=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ "$(grep -c 'agent@box1.ts.net' "$d/ssh.log" || true)" -ge 2 ] && break; sleep 0.25
done
kill "$rp"; wait "$rp" 2>/dev/null || true
grep -qx -- "-N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:53121:127.0.0.1:53121 -R 127.0.0.1:61002:127.0.0.1:61002 -- agent@100.64.0.2" "$d/ssh.log" || fail "run argv: $(cat "$d/ssh.log")"
[ "$(grep -c 'agent@box1.ts.net' "$d/ssh.log")" -ge 2 ] || fail "no retry"
bash "$B" uninstall >/dev/null
[ ! -e "$d/la/x.plist" ] && grep -q "bootout gui/$(id -u)/os.agent.solenta-bridge" "$d/launchctl.log" || fail uninstall
echo "solenta-bridge OK"
```

`web/server/test/solenta.test.ts` (whole file: Task 3's tests plus the download):
```ts
import { mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const PAIR = '/usr/local/lib/agentos/solenta-pair';
const STATUS = { host: 'box.ts.net', remoteHost: 'agent@box.ts.net', remotePath: null, tailscaleSsh: true, hostKeys: [],
  keyscan: 'ssh-keyscan -t ed25519 box.ts.net >> ~/.ssh/known_hosts', modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] };

describe('solenta', () => {
  it('returns solenta-pair status, with a path confined to home', async () => {
    const { deps, calls } = fakeDeps(() => ({ stdout: JSON.stringify(STATUS) }));
    mkdirSync(join(deps.home, 'work'));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/solenta', headers: H })).json()).toEqual(STATUS);
    expect(calls.at(-1)!.argv).toEqual([PAIR, 'status']);
    await app.inject({ url: `/api/solenta?path=${encodeURIComponent(join(deps.home, 'work'))}`, headers: H });
    expect(calls.at(-1)!.argv).toEqual([PAIR, 'status', '--', join(deps.home, 'work')]);
    expect((await app.inject({ url: '/api/solenta?path=/etc', headers: H })).statusCode).toBe(400);
  });

  it('clones through the sessions code: allowlisted URL, "--", ~/work/<name>, audited', async () => {
    const { deps, calls, audits } = fakeDeps((a) => {
      if (a[0] === 'git') mkdirSync(a[4], { recursive: true });
      return {};
    });
    const app = await buildApp(deps);
    const post = (payload: object) => app.inject({ method: 'POST', url: '/api/solenta/clone', headers: HM, payload });
    for (const repo of ['file:///etc', '--upload-pack=x', 'ext::sh -c id']) expect((await post({ repo, name: 'x' })).json().field).toBe('repo');
    expect((await post({ repo: 'https://example.com/a.git', name: '../x' })).json().field).toBe('name');
    expect(calls).toEqual([]);
    const r = await post({ repo: 'https://example.com/a.git', name: 'app' });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ path: join(deps.home, 'work/app') });
    expect(calls[0].argv).toEqual(['git', 'clone', '--', 'https://example.com/a.git', join(deps.home, 'work/app')]);
    expect(audits).toEqual([`${LOGIN} repo-clone ${join(deps.home, 'work/app')}`]);
  });

  it('serves the bridge script as a download', async () => {
    const { deps } = fakeDeps();
    const app = await buildApp(deps);
    const r = await app.inject({ url: '/api/solenta/bridge', headers: H });
    expect(r.statusCode).toBe(200);
    expect(r.headers['content-disposition']).toBe('attachment; filename="solenta-bridge"');
    expect(r.body).toBe(readFileSync(deps.bridgePath, 'utf8'));
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `chmod 755 test/bridge_test.sh && bash test/bridge_test.sh`
Expected: `bash: …/tools/solenta-bridge: No such file or directory`, non-zero exit.

- [ ] **Step 3: Write the bridge**

`tools/solenta-bridge`:
```bash
#!/bin/bash
# solenta-bridge (runs on the Mac, Mode B only): makes Solenta's MCP servers (coder-threads,
# coder-memory) reachable on each paired AgentOS box's loopback, through `ssh -R`.
#
#   solenta-bridge install user@box...   save the boxes, install and start the launchd agent
#   solenta-bridge uninstall              stop and remove the launchd agent
#   solenta-bridge run                    the loop launchd runs: one tunnel per box, kept open
#   solenta-bridge ports                  print the two ports it would forward
#
# It reads ONLY the "port" fields of Solenta's orch-server.json and memory-server.json: the bearer
# tokens in those files are never read into this script, printed or sent anywhere. The box still
# needs that token, which Solenta hands to the agents it runs there.
# macOS ships bash 3.2: no associative arrays, mapfile or ${x,,} here.
set -euo pipefail
SOLENTA_DIR=${SOLENTA_DIR:-"$HOME/Library/Application Support/Solenta"}
CONF=${SOLENTA_BRIDGE_CONF:-"$HOME/.config/agentos/solenta-bridge.conf"}
PLIST=${SOLENTA_BRIDGE_PLIST:-"$HOME/Library/LaunchAgents/os.agent.solenta-bridge.plist"}
LABEL=os.agent.solenta-bridge
LAUNCHCTL=${LAUNCHCTL:-launchctl}
BOX_RE='^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.:_-]*$'   # never starts with "-"

# port_of FILE: the number in the file's top-level "port" field, else nothing. grep -o prints only
# the matched `"port": N` text, so no other byte of the file (the token) reaches this shell.
port_of() {
  local p
  p=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]{1,5}' "$1" 2>/dev/null | head -n 1 | grep -oE '[0-9]+$') || return 0
  if [ -n "$p" ] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then echo "$p"; fi
}

ports() {
  local f
  for f in orch-server.json memory-server.json; do port_of "$SOLENTA_DIR/$f"; done
}

# ssh_argv BOX PORT...: the tunnel command, one word per line.
ssh_argv() {
  local box=$1 p; shift
  printf '%s\n' ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3
  for p in "$@"; do printf '%s\n' -R "127.0.0.1:$p:127.0.0.1:$p"; done
  printf '%s\n' -- "$box"
}

mtime() { date -r "$1" +%s 2>/dev/null || echo 0; }
stamp() { echo "$(ports | tr '\n' ' ')$(mtime "$CONF")"; }
boxes() { [ -f "$CONF" ] && grep -E "$BOX_RE" "$CONF" || true; }

# One tunnel per box, each restarted with backoff (1 s doubling to 60 s) when it drops. When the
# ports or the box list change, every tunnel is restarted with the new values.
run() {
  local pids=() box st
  # ${pids[@]+...}: bash 3.2 treats an empty array as unset under set -u.
  trap 'kill ${pids[@]+"${pids[@]}"} 2>/dev/null; exit 0' TERM INT
  while true; do
    st=$(stamp)
    local ps; ps=$(ports | tr '\n' ' ')
    if [ -z "$ps" ]; then echo "solenta-bridge: Solenta is not running (no ports in $SOLENTA_DIR); waiting" >&2; fi
    pids=()
    if [ -n "$ps" ]; then
      for box in $(boxes); do
        # shellcheck disable=SC2086 # $ps is a list of validated port numbers
        ( delay=1
          while true; do
            argv=(); while IFS= read -r w; do argv+=("$w"); done < <(ssh_argv "$box" $ps)
            start=$(date +%s)
            "${argv[@]}" || true
            [ $(( $(date +%s) - start )) -ge 60 ] && delay=1
            echo "solenta-bridge: tunnel to $box dropped; retrying in ${delay}s" >&2
            sleep "$delay"; delay=$(( delay * 2 > 60 ? 60 : delay * 2 ))
          done ) &
        pids+=($!)
      done
    fi
    while [ "$(stamp)" = "$st" ]; do sleep 5; done
    echo "solenta-bridge: Solenta ports or boxes changed; reconnecting" >&2
    if [ ${#pids[@]} -gt 0 ]; then pkill -P "$(echo "${pids[@]}" | tr ' ' ',')" 2>/dev/null || true; kill "${pids[@]}" 2>/dev/null || true; fi
  done
}

install_agent() {
  local b self
  [ $# -gt 0 ] || { echo "usage: solenta-bridge install user@box..." >&2; exit 2; }
  for b in "$@"; do [[ $b =~ $BOX_RE ]] || { echo "not user@host: $b" >&2; exit 2; }; done
  mkdir -p "$(dirname "$CONF")" "$(dirname "$PLIST")"
  printf '%s\n' "$@" > "$CONF"
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$self</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/solenta-bridge.log</string>
</dict>
</plist>
PLIST
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST"
  echo "solenta-bridge: forwarding Solenta's MCP ports to: $*"
  echo "Log: ~/Library/Logs/solenta-bridge.log"
}

uninstall_agent() {
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "solenta-bridge: removed (kept $CONF)"
}

main() {
  case "${1:-}" in
    install)   shift; install_agent "$@" ;;
    uninstall) uninstall_agent ;;
    run)       run ;;
    ports)     ports ;;
    *)         sed -n 5,9p "$0" >&2; exit 2 ;;
  esac
}

# Sourced by test/bridge_test.sh for its functions; executed otherwise.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
```

- [ ] **Step 4: Ship it in the image and serve it**

In `mkosi.prepare.chroot`, find:
```bash
# AgentOS web UI (web/): built here because prepare scripts have network access. Only the build
```
Insert before it:
```bash
# The Mac-side Solenta bridge (Mode B), served for download by the web UI's Solenta card.
install -D -m 755 "$SRCDIR/tools/solenta-bridge" /usr/local/share/agentos/solenta-bridge

```

`web/server/src/solenta.ts` (whole file):
```ts
// The Solenta card: pairing facts and preflight (solenta-pair, as agent), a repo clone through the
// sessions code, and the Mac-side bridge script for download. Nothing here reads a Solenta token.
import { readFile } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { cloneRepo, resolveDir } from './sessions.js';

export function solentaRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Querystring: { path?: string } }>('/api/solenta', async (req) => {
    const path = req.query.path ? await resolveDir(req.query.path, deps.home) : undefined;
    const r = await runAction(deps.run, { name: 'solenta-status', path }, { timeoutMs: 30_000 });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim() || 'solenta-pair failed');
    return JSON.parse(r.stdout);
  });
  app.post<{ Body: { repo?: string; name?: string } }>('/api/solenta/clone', async (req, reply) =>
    reply.code(201).send({ path: await cloneRepo(deps, String(req.body?.repo ?? ''), String(req.body?.name ?? ''), req.login) }));
  app.get('/api/solenta/bridge', async (_req, reply) =>
    reply.type('text/x-shellscript; charset=utf-8').header('Content-Disposition', 'attachment; filename="solenta-bridge"')
      .send(await readFile(deps.bridgePath)));
}
```

In `web/server/src/app.ts`, find:
```ts
  vncTokenDir: string;
}
```
Replace with:
```ts
  vncTokenDir: string;
  bridgePath: string;     // tools/solenta-bridge, served for download by the Solenta card
}
```
Then find:
```ts
    vncTokenDir: TOKEN_DIR,
  };
```
Replace with:
```ts
    vncTokenDir: TOKEN_DIR,
    bridgePath: '/usr/local/share/agentos/solenta-bridge',
  };
```

In `web/server/test/helpers.ts`, add `import { fileURLToPath } from 'node:url';` after the `node:path` import. In `fakeDeps`, find `    ...over,` and insert before it:
```ts
    bridgePath: fileURLToPath(new URL('../../../tools/solenta-bridge', import.meta.url)),
```

- [ ] **Step 5: Run the tests**

Run: `bash test/bridge_test.sh` (macOS bash 3.2) and `.superpowers/sdd/devvm.sh sh 'test/bridge_test.sh && shellcheck -S warning tools/solenta-bridge test/bridge_test.sh mkosi.prepare.chroot && echo SC-OK'`
Expected: `solenta-bridge OK` on both, then `SC-OK`.

Run: `cd web/server && npx tsc -p tsconfig.json --noEmit && npx vitest run`
Expected: `Tests  91 passed | 1 skipped (92)`.

- [ ] **Step 6: Commit**

```bash
git add tools/solenta-bridge test/bridge_test.sh mkosi.prepare.chroot web/server/src/solenta.ts web/server/src/app.ts \
  web/server/test/helpers.ts web/server/test/solenta.test.ts
git commit -m "feat(solenta): Mac-side solenta-bridge (ssh -R, launchd, ports only), downloadable from the box"
```

---

### Task 5: The `agentos-ci` engine: pipeline selection, runs, queue, cancel, retention

**Files:**
- Create under `mkosi.extra/usr/local/lib/agentos/ci/`: `main.py`, `agentos_ci/__init__.py` (empty), `agentos_ci/pipeline.py`, `agentos_ci/runs.py`, `agentos_ci/cli.py`
- Create: `mkosi.extra/usr/local/bin/agentos-ci` (mode 755)
- Modify: `mkosi.extra/usr/local/lib/agentos/env.sh`, `mkosi.extra/usr/local/sbin/agentos-firstboot`, `mkosi.prepare.chroot` (pyyaml), `mkosi.finalize.chroot` (invariants)
- Test: `test/ci/conftest.py`, `test/ci/test_pipeline.py`, `test/ci/test_runs.py`, `test/ci/test_cli.py` (new), `test/env_test.sh` (one line)

**Interfaces:**
- Consumes:
  - `~/.config/agentos/secrets.env`;
  - `/etc/agentos/ci.conf` (`MAX_PARALLEL=N`), with `AGENTOS_CI_MAX_PARALLEL` in the environment winning (tests);
  - `HOME` (every path derives from it).
- Produces, in `pipeline`:
  - `select(work: Path) -> Pipeline`;
  - `Pipeline(kind: "ci.yml"|"act"|"auto", steps: list[Step], image: str|None, timeout_s: int, secrets: list[str])`;
  - `Step(name, run)`;
  - `ConfigError`, `parse_ci_yml(text)`, `parse_timeout(v)`, `workflow_events(text)`;
  - `ACT_PLATFORMS`, `STEP_RE`.
- Produces, in `runs`:
  - `start(path, ref="HEAD", source="cli") -> run_id`, `status(id) -> dict`, `list_runs(repo=None, limit=20)`;
  - `logs(id, step=None, n=200) -> {step, text}`, `follow(id, step, out)`;
  - `wait(id, timeout_s) -> summary`, `summary(run) -> {run_id, status, failed_step, log_tail}`;
  - `cancel(id) -> dict`, `prune(keep=200)`;
  - `git(*args, cwd, check)`, `home()`, `alive(pid)`, `killpg(pgid, sig)`;
  - `CIError`, `FINAL`, `ID_RE`, `REF_RE`;
  - `worker(id)` and `spawn(id)`, reached through `main.py _spawn|_worker`.
- `run.json` keys: `id repo ref commit source status created started finished pipeline image secrets missing_secrets steps[] error`. Each `steps[]` entry has `name status exit_code started finished`.
- `agentos-ci run|status|logs|list|cancel` (Tasks 6 and 7 add `remote`, `mcp` and `install-skill`). Exit 2 means a bad request, with the message on stderr; `run --wait` exits 0 only on `passed`.

- [ ] **Step 1: Write the failing tests**

`test/ci/conftest.py`:
```python
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

CI_DIR = Path(__file__).resolve().parents[2] / "mkosi.extra/usr/local/lib/agentos/ci"
sys.path.insert(0, str(CI_DIR))


@pytest.fixture
def home(tmp_path, monkeypatch):
    h = (tmp_path / "home").resolve()
    h.mkdir()
    monkeypatch.setenv("HOME", str(h))
    monkeypatch.setenv("AGENTOS_CI_MAX_PARALLEL", "2")
    return h


def sh(*args, cwd=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@x")
    return subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def make_repo(path: Path, files: dict) -> Path:
    path.mkdir(parents=True)
    sh("git", "init", "-q", "-b", "main", cwd=path)
    for name, text in files.items():
        f = path / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    sh("git", "add", "-A", cwd=path)
    sh("git", "commit", "-qm", "init", cwd=path)
    return path


def wait_final(run_id, timeout=60):
    from agentos_ci import runs
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        run = runs.status(run_id)
        if run["status"] in runs.FINAL:
            return run
        time.sleep(0.2)
    raise AssertionError(f"run {run_id} still {runs.status(run_id)['status']}")


def ci_yml(*steps, extra=""):
    body = "".join(f"  - name: {n}\n    run: {r!r}\n" for n, r in steps)
    return f"{extra}steps:\n{body}"
```

`test/ci/test_pipeline.py`:
```python
import pytest
from conftest import ci_yml
from agentos_ci.pipeline import ConfigError, parse_ci_yml, parse_timeout, select, workflow_events


def tree(tmp_path, files):
    for name, text in files.items():
        f = tmp_path / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    return tmp_path


WF = "on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"


def test_selection_order_ci_yml_then_workflows_then_auto(tmp_path):
    t = tree(tmp_path, {".agentos/ci.yml": ci_yml(("t", "true")), ".github/workflows/ci.yml": WF,
                        "package.json": '{"scripts":{"test":"x"}}'})
    assert select(t).kind == "ci.yml"
    (t / ".agentos/ci.yml").unlink()
    p = select(t)
    assert p.kind == "act" and p.steps[0].name == "act-ci.yml"
    assert p.steps[0].run.startswith("act push -W .github/workflows/ci.yml -P ubuntu-latest=catthehacker/ubuntu:act-24.04")
    assert "--pull=false" in p.steps[0].run
    (t / ".github/workflows/ci.yml").unlink()
    assert select(t).kind == "auto"


def test_workflow_events_and_dispatch_only(tmp_path):
    assert workflow_events("on: [push, pull_request]") == {"push", "pull_request"}
    assert workflow_events("on:\n  workflow_dispatch:\n  schedule: []\n") == {"workflow_dispatch", "schedule"}
    assert workflow_events("'on': push") == {"push"}
    assert workflow_events(": not yaml [") == set()
    t = tree(tmp_path, {".github/workflows/d.yaml": "on: workflow_dispatch\njobs: {}\n",
                        ".github/workflows/pr.yml": "on: pull_request\njobs: {}\n", "go.mod": "module x\n"})
    p = select(t)
    assert [s.name for s in p.steps] == ["act-d.yaml"] and p.steps[0].run.startswith("act workflow_dispatch ")
    (t / ".github/workflows/d.yaml").unlink()
    assert select(t).kind == "auto"     # no push/dispatch workflow: fall through


@pytest.mark.parametrize("files,cmd", [
    ({"package.json": '{"scripts":{"test":"node t.js"}}'}, "npm ci && npm test"),
    ({"pyproject.toml": ""}, "pytest"),
    ({"pytest.ini": ""}, "pytest"),
    ({"tests/test_x.py": ""}, "pytest"),
    ({"Cargo.toml": ""}, "cargo test"),
    ({"go.mod": "module x\n"}, "go test ./..."),
    ({"Makefile": "build:\n\ttrue\ntest: build\n\ttrue\n"}, "make test"),
    ({"package.json": '{"scripts":{"build":"x"}}', "go.mod": ""}, "go test ./..."),   # no test script: next rule
])
def test_auto_detect(tmp_path, files, cmd):
    assert [s.run for s in select(tree(tmp_path, files)).steps] == [cmd]


@pytest.mark.parametrize("files", [{}, {"Makefile": "build:\n\ttrue\n"}, {"package.json": "[1]"}])
def test_nothing_found(tmp_path, files):
    with pytest.raises(ConfigError, match="no CI configuration found"):
        select(tree(tmp_path, files))


def test_ci_yml_full():
    p = parse_ci_yml("image: node:24\ntimeout: 5m\nsecrets: [NPM_TOKEN, NPM_TOKEN]\n" + ci_yml(("install", "npm ci"), ("test", "npm test")))
    assert (p.kind, p.image, p.timeout_s, p.secrets) == ("ci.yml", "node:24", 300, ["NPM_TOKEN"])
    assert [(s.name, s.run) for s in p.steps] == [("install", "npm ci"), ("test", "npm test")]
    assert parse_ci_yml("steps:\n  - run: make\n").steps[0].name == "step-1"
    assert parse_ci_yml("steps:\n  - run: make\n").timeout_s == 1800


@pytest.mark.parametrize("text,why", [
    ("steps: [", "not valid YAML"),
    ("- a\n", "mapping"),
    ("stages: []\nsteps:\n  - run: x\n", "unknown keys: stages"),
    ("steps: []\n", "non-empty"),
    ("steps:\n  - name: a\n", "needs run"),
    ("steps:\n  - run: x\n    env: {}\n", "needs run"),
    ("steps:\n  - {name: a, run: x}\n  - {name: a, run: y}\n", "unique"),
    ("steps:\n  - {name: ../etc, run: x}\n", "name must match"),
    ("steps:\n  - {name: -rf, run: x}\n", "name must match"),
    ("image: --privileged\nsteps:\n  - run: x\n", "image"),
    ("image: Node\nsteps:\n  - run: x\n", "image"),
    ("secrets: [lower]\nsteps:\n  - run: x\n", "secrets"),
    ("secrets: NPM_TOKEN\nsteps:\n  - run: x\n", "secrets"),
    ("timeout: forever\nsteps:\n  - run: x\n", "timeout"),
    ("timeout: 25h\nsteps:\n  - run: x\n", "between"),
])
def test_ci_yml_rejects(text, why):
    with pytest.raises(ConfigError, match=why):
        parse_ci_yml(text)


def test_timeout_units():
    assert [parse_timeout(v) for v in ("90", "90s", "30m", "2h")] == [90, 90, 1800, 7200]
```

`test/ci/test_runs.py`:
```python
import json
import os
import re
import time

import pytest
from conftest import ci_yml, make_repo, sh, wait_final
from agentos_ci import runs
from agentos_ci.runs import CIError


def test_ids_are_monotonic_and_well_formed(home):
    ids = [runs.new_id() for _ in range(50)]
    assert ids == sorted(ids) and len(set(ids)) == 50
    assert all(re.fullmatch(r"\d{8}-\d{6}-[0-9a-f]{4}", i) for i in ids)


def test_paths_must_be_repos_inside_home(home, tmp_path):
    outside = make_repo(tmp_path / "outside", {"a": "1"})
    (home / "link").symlink_to(outside)
    (home / "plain").mkdir()
    for bad, why in [(outside, "inside"), (home / "link", "inside"), (home / "nope", "no such"),
                     (home / "plain", "not a git repository")]:
        with pytest.raises(CIError, match=why):
            runs.start(bad)
    repo = make_repo(home / "r", {"a": "1"})
    for ref in ("-x", "--output=/tmp/x", "a b", "HEAD;id", ""):
        with pytest.raises(CIError, match="invalid ref"):
            runs.start(repo, ref)
    with pytest.raises(CIError, match="unknown ref"):
        runs.start(repo, "no-such-branch")
    for bad in ("../x", "20260101-000000-zzzz", "x" * 30):
        with pytest.raises(CIError, match="invalid run id"):
            runs.status(bad)


def test_passing_run_states_and_logs(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("one", "echo first"), ("two", "echo second; pwd"))})
    rid = runs.start(repo / ".agentos")          # a subdirectory resolves to the repo
    first = runs.status(rid)
    assert first["status"] in ("queued", "running", "passed") and first["repo"] == str(repo)
    run = wait_final(rid)
    assert run["status"] == "passed" and run["pipeline"] == "ci.yml"
    assert [(s["name"], s["status"], s["exit_code"]) for s in run["steps"]] == [("one", "passed", 0), ("two", "passed", 0)]
    assert run["started"] and run["finished"] and run["commit"] == runs.git("rev-parse", "HEAD", cwd=repo)
    assert runs.logs(rid, "one")["text"] == "first\n"
    assert str(home / ".cache/agentos-ci/work" / rid) in runs.logs(rid, "two")["text"]
    assert not (home / ".cache/agentos-ci/work" / rid).exists()          # checkout removed
    assert runs.summary(run) == {"run_id": rid, "status": "passed", "failed_step": None, "log_tail": ""}


def test_failing_step_skips_the_rest_and_reports_its_tail(home):
    lines = "; ".join(f"echo line{i}" for i in range(300))
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("ok", "true"), ("bad", lines + "; false"), ("never", "touch /tmp/x"))})
    run = wait_final(runs.start(repo))
    assert run["status"] == "failed"
    assert [s["status"] for s in run["steps"]] == ["passed", "failed", "skipped"]
    s = runs.summary(run)
    assert s["failed_step"] == "bad" and s["log_tail"].splitlines() == [f"line{i}" for i in range(100, 300)]


def test_pipefail_and_exact_commit(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("p", "false | true"))})
    first = runs.git("rev-parse", "HEAD", cwd=repo)
    (repo / ".agentos/ci.yml").write_text(ci_yml(("p", "true")))
    sh("git", "commit", "-qam", "fix", cwd=repo)
    old = wait_final(runs.start(repo, first))
    assert old["status"] == "failed" and old["commit"] == first     # -o pipefail, and the old tree
    assert wait_final(runs.start(repo))["status"] == "passed"


def test_no_config_is_an_error_with_a_hint(home):
    run = wait_final(runs.start(make_repo(home / "r", {"README": "x"})))
    assert run["status"] == "error" and "no CI configuration found" in run["error"]
    assert runs.summary(run)["log_tail"].startswith("no CI configuration found")


def test_bare_repo(home):
    src = make_repo(home / "src", {".agentos/ci.yml": ci_yml(("t", "test -f .agentos/ci.yml"))})
    runs.git("clone", "-q", "--bare", str(src), str(home / "b.git"))
    assert wait_final(runs.start(home / "b.git", "main"))["status"] == "passed"


def test_clean_env_and_secrets_only_when_listed(home):
    (home / ".config/agentos").mkdir(parents=True)
    (home / ".config/agentos/secrets.env").write_text("ANTHROPIC_API_KEY=sk-secret-1\nNPM_TOKEN=npm-2==\n")
    os.environ["LEAKY_VAR"] = "leak"
    try:
        script = "env | sort; test \"$NPM_TOKEN\" = npm-2=="
        listed = make_repo(home / "a", {".agentos/ci.yml": "secrets: [NPM_TOKEN, MISSING_TOKEN]\n" + ci_yml(("e", script))})
        unlisted = make_repo(home / "b", {".agentos/ci.yml": ci_yml(("e", "env | sort"))})
        run = wait_final(runs.start(listed))
        env = runs.logs(run["id"], "e")["text"]
        assert run["status"] == "passed" and run["secrets"] == ["MISSING_TOKEN", "NPM_TOKEN"]
        assert run["missing_secrets"] == ["MISSING_TOKEN"]
        assert "sk-secret-1" not in env and "LEAKY_VAR" not in env
        assert f"AGENTOS_CI_RUN={run['id']}" in env and "CI=true" in env
        assert "npm-2==" not in (home / ".local/share/agentos-ci/runs" / run["id"] / "run.json").read_text()
        env2 = runs.logs(wait_final(runs.start(unlisted))["id"], "e")["text"]
        assert "NPM_TOKEN" not in env2 and "ANTHROPIC_API_KEY" not in env2
        keys = {line.split("=", 1)[0] for line in env2.splitlines() if "=" in line}
        assert keys <= {"PATH", "HOME", "LANG", "CI", "AGENTOS_CI_RUN", "PWD", "SHLVL", "_", "OLDPWD"}
    finally:
        del os.environ["LEAKY_VAR"]


def test_queue_respects_max_parallel(home, monkeypatch):
    monkeypatch.setenv("AGENTOS_CI_MAX_PARALLEL", "1")
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "sleep 2"))})
    a = runs.start(repo)
    b = runs.start(repo)
    deadline = time.monotonic() + 10
    while runs.status(a)["status"] != "running" and time.monotonic() < deadline:
        time.sleep(0.1)
    assert runs.status(a)["status"] == "running" and runs.status(b)["status"] == "queued"
    ra, rb = wait_final(a), wait_final(b)
    assert ra["status"] == rb["status"] == "passed" and rb["started"] >= ra["finished"]


def test_cancel_kills_the_process_group(home):
    pidfile = home / "child.pid"
    # The step starts a background grandchild in its own group, then waits.
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", f"sleep 300 & echo $! > {pidfile}; wait"), ("after", "true"))})
    rid = runs.start(repo)
    deadline = time.monotonic() + 15
    while not pidfile.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    child = int(pidfile.read_text())
    run = runs.cancel(rid)
    assert run["status"] == "cancelled"
    assert [s["status"] for s in run["steps"]] == ["cancelled", "skipped"]
    time.sleep(0.5)
    assert not runs.alive(child)
    assert runs.cancel(rid)["status"] == "cancelled"                 # idempotent


def test_cancel_escalates_to_sigkill(home, monkeypatch):
    monkeypatch.setattr(runs, "KILL_GRACE", 1)
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "trap '' TERM; echo ready; while :; do sleep 0.1; done"))})
    rid = runs.start(repo)
    deadline = time.monotonic() + 15
    while "ready" not in runs.logs(rid, None)["text"] and time.monotonic() < deadline:
        time.sleep(0.1)
    t = time.monotonic()
    assert runs.cancel(rid)["status"] == "cancelled"
    assert time.monotonic() - t < 14          # the worker's 10 s grace, not cancel's own fallback


def test_cancel_a_queued_run(home, monkeypatch):
    monkeypatch.setenv("AGENTOS_CI_MAX_PARALLEL", "1")
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "sleep 3"))})
    a, b = runs.start(repo), runs.start(repo)
    assert runs.cancel(b)["status"] == "cancelled" and runs.status(b)["steps"] == []
    assert wait_final(a)["status"] == "passed"


def test_timeout_kills_the_step(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": "timeout: 1s\n" + ci_yml(("s", "sleep 30"))})
    t = time.monotonic()
    run = wait_final(runs.start(repo), timeout=20)
    assert run["status"] == "failed" and time.monotonic() - t < 15
    assert "timed out after 1s" in runs.logs(run["id"], "s")["text"]


def test_dead_worker_is_an_error(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "sleep 30"))})
    rid = runs.start(repo)
    pid = int((home / ".local/share/agentos-ci/runs" / rid / "pid").read_text())
    time.sleep(0.5)
    os.kill(pid, 9)
    time.sleep(0.3)
    run = runs.status(rid)
    assert run["status"] == "error" and "exited unexpectedly" in run["error"]
    runs.killpg(int((home / ".local/share/agentos-ci/runs" / rid / "pgid").read_text()), 9)


def test_retention_keeps_the_newest_200_final_runs(home):
    rd = home / ".local/share/agentos-ci/runs"
    for i in range(205):
        d = rd / f"20260101-000000-{i:04x}"
        d.mkdir(parents=True)
        (d / "run.json").write_text(json.dumps({"status": "running" if i == 0 else "passed"}))
    runs.prune()
    left = sorted(p.name for p in rd.iterdir())
    assert len(left) == 201 and left[0] == "20260101-000000-0000" and left[1] == "20260101-000000-0005"


def test_list_filters_by_repo(home):
    a = make_repo(home / "a", {".agentos/ci.yml": ci_yml(("t", "true"))})
    b = make_repo(home / "b", {".agentos/ci.yml": ci_yml(("t", "true"))})
    ra, rb = runs.start(a), runs.start(b)
    wait_final(ra), wait_final(rb)
    assert [r["id"] for r in runs.list_runs()] == [rb, ra]
    assert [r["id"] for r in runs.list_runs(a)] == [ra]
    assert [r["id"] for r in runs.list_runs(limit=1)] == [rb]
```

`test/ci/test_cli.py`:
```python
import json
import subprocess
import sys

from conftest import CI_DIR, ci_yml, make_repo


def cli(*args, home):
    return subprocess.run([sys.executable, str(CI_DIR / "main.py"), *args], capture_output=True, text=True,
                          env={"HOME": str(home), "PATH": "/usr/local/bin:/usr/bin:/bin", "AGENTOS_CI_MAX_PARALLEL": "2"})


def test_cli_json_and_exit_codes(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("t", "echo hi"))})
    r = cli("run", str(repo), "--wait", "--json", home=home)
    assert r.returncode == 0, r.stderr
    s = json.loads(r.stdout)
    assert s["status"] == "passed"
    st = json.loads(cli("status", s["run_id"], "--json", home=home).stdout)
    assert st["steps"][0]["name"] == "t"
    assert cli("logs", s["run_id"], "--follow", home=home).stdout == "hi\n"
    assert json.loads(cli("list", "--json", "--limit", "5", home=home).stdout)[0]["id"] == s["run_id"]
    bad = make_repo(home / "b", {".agentos/ci.yml": ci_yml(("t", "exit 3"))})
    assert cli("run", str(bad), "--wait", home=home).returncode == 1
    err = cli("status", "nope", "--json", home=home)
    assert err.returncode == 2 and "invalid run id" in err.stderr
```

In `test/env_test.sh`, find:
```bash
ok SOME_OTHER_KEY anything
```
Replace with:
```bash
ok AGENTOS_CI_MAX_PARALLEL 1; ok AGENTOS_CI_MAX_PARALLEL 16; bad AGENTOS_CI_MAX_PARALLEL 0; bad AGENTOS_CI_MAX_PARALLEL 17
ok SOME_OTHER_KEY anything
```

- [ ] **Step 2: Run them to see them fail**

Run: `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci`
Expected: collection errors, `ModuleNotFoundError: No module named 'agentos_ci'`.

- [ ] **Step 3: Write the engine**

`mkosi.extra/usr/local/lib/agentos/ci/main.py`:
```python
"""agentos-ci entry point (/usr/local/bin/agentos-ci runs this with the AgentOS venv's python)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agentos_ci.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
```

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/__init__.py`: an empty file.

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/pipeline.py`:
```python
"""Pick a repo's pipeline, first match wins: .agentos/ci.yml, .github/workflows via act, auto-detect."""
import json
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path

import yaml

STEP_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")    # also the log file name: no "/"
SECRET_RE = re.compile(r"^[A-Z_][A-Z0-9_]{0,63}$")
IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9._/:@-]{0,254}$")       # never starts with "-": not a docker flag
DEFAULT_TIMEOUT = 30 * 60
MAX_TIMEOUT = 24 * 3600
# act's runner images (catthehacker "medium", ~570 MB compressed). Docker pulls them on first use
# (--pull=false only skips re-pulling); they are never baked into the AgentOS image.
ACT_PLATFORMS = (
    "ubuntu-latest=catthehacker/ubuntu:act-24.04",
    "ubuntu-24.04=catthehacker/ubuntu:act-24.04",
    "ubuntu-22.04=catthehacker/ubuntu:act-22.04",
)


class ConfigError(Exception):
    pass


@dataclass
class Step:
    name: str
    run: str          # a bash script: bash -eo pipefail -c <run>


@dataclass
class Pipeline:
    kind: str         # "ci.yml" | "act" | "auto"
    steps: list
    image: str | None = None
    timeout_s: int = DEFAULT_TIMEOUT
    secrets: list = field(default_factory=list)


def parse_timeout(value) -> int:
    m = re.fullmatch(r"(\d{1,6})([smh]?)", str(value).strip())
    if not m:
        raise ConfigError(f"timeout must look like 90s, 30m or 2h, not {value!r}")
    seconds = int(m[1]) * {"": 1, "s": 1, "m": 60, "h": 3600}[m[2]]
    if not 1 <= seconds <= MAX_TIMEOUT:
        raise ConfigError("timeout must be between 1s and 24h")
    return seconds


def parse_ci_yml(text: str) -> Pipeline:
    try:
        d = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise ConfigError(f".agentos/ci.yml is not valid YAML: {e}")
    if not isinstance(d, dict):
        raise ConfigError(".agentos/ci.yml must be a mapping with a steps: list")
    unknown = sorted(str(k) for k in set(d) - {"image", "timeout", "secrets", "steps"})
    if unknown:
        raise ConfigError(f".agentos/ci.yml: unknown keys: {', '.join(unknown)}")
    image = d.get("image")
    if image is not None and not (isinstance(image, str) and IMAGE_RE.match(image)):
        raise ConfigError(f"image: not a Docker image reference: {image!r}")
    secrets = d.get("secrets") or []
    if not isinstance(secrets, list) or not all(isinstance(s, str) and SECRET_RE.match(s) for s in secrets):
        raise ConfigError("secrets: must be a list of names such as NPM_TOKEN")
    raw = d.get("steps")
    if not isinstance(raw, list) or not raw:
        raise ConfigError("steps: must be a non-empty list")
    steps, seen = [], set()
    for i, s in enumerate(raw, 1):
        if not isinstance(s, dict) or set(s) - {"name", "run"} or not isinstance(s.get("run"), str) or not s["run"].strip():
            raise ConfigError(f"step {i}: needs run: (a string) and optionally name:")
        name = s.get("name", f"step-{i}")
        if not isinstance(name, str) or not STEP_RE.match(name) or name in seen:
            raise ConfigError(f"step {i}: name must match [A-Za-z0-9][A-Za-z0-9_.-]{{0,63}} and be unique")
        seen.add(name)
        steps.append(Step(name, s["run"]))
    return Pipeline("ci.yml", steps, image, parse_timeout(d.get("timeout", "30m")), sorted(set(secrets)))


def workflow_events(text: str) -> set:
    try:
        d = yaml.safe_load(text)
    except yaml.YAMLError:
        return set()
    if not isinstance(d, dict):
        return set()
    on = d.get("on", d.get(True))     # YAML 1.1 reads a bare `on:` key as the boolean True
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return {str(e) for e in on}
    return set()


def act_steps(work: Path) -> list:
    wf = work / ".github" / "workflows"
    files = sorted(p for p in wf.iterdir() if p.suffix in (".yml", ".yaml") and p.is_file()) if wf.is_dir() else []
    platforms = " ".join(f"-P {p}" for p in ACT_PLATFORMS)
    steps = []
    for f in files:
        events = workflow_events(f.read_text(errors="replace"))
        event = "push" if "push" in events else "workflow_dispatch" if "workflow_dispatch" in events else None
        if event:
            name = "act-" + re.sub(r"[^A-Za-z0-9_.-]", "-", f.name)[:60]
            rel = shlex.quote(str(f.relative_to(work)))
            steps.append(Step(name, f"act {event} -W {rel} {platforms} --pull=false --rm"))
    return steps


def auto_steps(work: Path) -> list:
    pj = work / "package.json"
    if pj.is_file():
        try:
            scripts = json.loads(pj.read_text()).get("scripts") or {}
        except (ValueError, AttributeError):
            scripts = {}
        if isinstance(scripts, dict) and "test" in scripts:
            return [Step("npm-test", "npm ci && npm test")]
    if any((work / f).exists() for f in ("pyproject.toml", "pytest.ini", "tests")):
        return [Step("pytest", "pytest")]
    if (work / "Cargo.toml").is_file():
        return [Step("cargo-test", "cargo test")]
    if (work / "go.mod").is_file():
        return [Step("go-test", "go test ./...")]
    mk = work / "Makefile"
    if mk.is_file() and re.search(r"^test\s*:", mk.read_text(errors="replace"), re.M):
        return [Step("make-test", "make test")]
    return []


NO_CONFIG = ("no CI configuration found. Add .agentos/ci.yml (steps: [{name: test, run: npm test}]), "
             "a .github/workflows/*.yml with an on: push trigger, or a test entry point agentos-ci detects: "
             "package.json test script, pyproject.toml/pytest.ini/tests/, Cargo.toml, go.mod, Makefile test target.")


def select(work: Path) -> Pipeline:
    ci = work / ".agentos" / "ci.yml"
    if ci.is_file():
        return parse_ci_yml(ci.read_text(errors="replace"))
    steps = act_steps(work)
    if steps:
        return Pipeline("act", steps)
    steps = auto_steps(work)
    if steps:
        return Pipeline("auto", steps)
    raise ConfigError(NO_CONFIG)
```

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/runs.py`:
```python
"""agentos-ci runs: ids, run.json state, queue slots, the worker, cancel, logs and retention.

A run lives in ~/.local/share/agentos-ci/runs/<id>/ (run.json, pid, pgid, <step>.log). `start` spawns
a detached worker (its own session) that waits for a slot, checks the commit out into
~/.cache/agentos-ci/work/<id>, runs the steps and removes the checkout.
"""
import collections
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import pipeline

FINAL = ("passed", "failed", "cancelled", "error")
ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{4}$")
REF_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./@^~{}-]{0,254}$")   # never starts with "-"
KEEP = 200
KILL_GRACE = 10
BASE_PATH = "/usr/local/bin:/usr/bin:/bin"
MAIN = str(Path(__file__).resolve().parent.parent / "main.py")


class CIError(Exception):
    pass


def home() -> Path:
    return Path(os.environ.get("HOME") or "/home/agent").resolve()


def state_dir() -> Path:
    return home() / ".local/share/agentos-ci"


def runs_dir() -> Path:
    return state_dir() / "runs"


def work_root() -> Path:
    return home() / ".cache/agentos-ci/work"


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def max_parallel() -> int:
    v = os.environ.get("AGENTOS_CI_MAX_PARALLEL")
    if v is None:
        try:
            m = re.search(r"^MAX_PARALLEL=(\d+)$", Path("/etc/agentos/ci.conf").read_text(), re.M)
            v = m[1] if m else None
        except OSError:
            v = None
    try:
        n = int(v)
    except (TypeError, ValueError):
        return 2
    return n if 1 <= n <= 16 else 2


def git(*args, cwd=None, check=True) -> str:
    # GIT_DIR and friends (set when a hook calls us) must not redirect these commands.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    r = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode:
        raise CIError(f"git {args[0]} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def inside_home(path) -> Path:
    try:
        real = Path(path).expanduser().resolve(strict=True)
    except (OSError, RuntimeError):
        raise CIError(f"no such directory: {path}")
    h = home()
    if real != h and h not in real.parents:
        raise CIError(f"path must be inside {h}")
    if not real.is_dir():
        raise CIError(f"not a directory: {path}")
    return real


def repo_root(path) -> Path:
    """The repository a path belongs to: the bare repo itself, or the work tree's top level."""
    p = inside_home(path)
    bare = git("rev-parse", "--is-bare-repository", cwd=p, check=False)
    if bare not in ("true", "false"):
        raise CIError(f"not a git repository: {p}")
    return p if bare == "true" else inside_home(git("rev-parse", "--show-toplevel", cwd=p))


def resolve(path, ref) -> tuple:
    if not isinstance(ref, str) or not REF_RE.match(ref):
        raise CIError(f"invalid ref: {ref!r}")
    repo = repo_root(path)
    commit = git("rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}", cwd=repo, check=False)
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
        raise CIError(f"unknown ref {ref!r} in {repo}")
    return repo, commit


def new_id() -> str:
    """YYYYMMDD-HHMMSS-<4 hex>, strictly increasing: the hex counts runs started within one second."""
    state_dir().mkdir(parents=True, exist_ok=True)
    with open(state_dir() / "last-id", "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        last = f.read().strip()
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        n = int(last[16:], 16) + 1 if last[:15] >= stamp and ID_RE.match(last) else 0
        if last[:15] > stamp:            # clock went back: keep counting on the last stamp
            stamp = last[:15]
        if n > 0xFFFF:
            raise CIError("too many runs started this second")
        run_id = f"{stamp}-{n:04x}"
        f.seek(0)
        f.truncate()
        f.write(run_id)
    return run_id


def run_dir(run_id) -> Path:
    if not isinstance(run_id, str) or not ID_RE.match(run_id):
        raise CIError(f"invalid run id: {run_id!r}")
    d = runs_dir() / run_id
    if not (d / "run.json").is_file():
        raise CIError(f"no run {run_id}")
    return d


def load(run_id) -> dict:
    return json.loads((run_dir(run_id) / "run.json").read_text())


def save(run: dict) -> None:
    d = runs_dir() / run["id"]
    tmp = d / f"run.json.{os.getpid()}.tmp"
    tmp.write_text(json.dumps(run, indent=2) + "\n")
    os.replace(tmp, d / "run.json")


def read_int(path: Path):
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def alive(pid) -> bool:
    """True while pid runs. A zombie (exited, not yet reaped by its parent) counts as gone."""
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True                        # no /proc (macOS): kill(0) is all we have


def refresh(run: dict) -> dict:
    """A queued or running run whose worker is gone ended badly: record that."""
    if run["status"] not in FINAL:
        pid = read_int(runs_dir() / run["id"] / "pid")
        if pid is not None and not alive(pid):
            run = load(run["id"])          # the worker may have finished between the two reads
            if run["status"] not in FINAL:
                run.update(status="error", error="the run's worker exited unexpectedly", finished=now())
                save(run)
    return run


def start(path, ref="HEAD", source="cli") -> str:
    if source not in ("cli", "push", "web", "mcp"):
        raise CIError(f"invalid source {source!r}")
    repo, commit = resolve(path, ref)
    run_id = new_id()
    d = runs_dir() / run_id
    d.mkdir(parents=True)
    save({"id": run_id, "repo": str(repo), "ref": ref, "commit": commit, "source": source, "status": "queued",
          "created": now(), "started": None, "finished": None, "pipeline": None, "image": None,
          "secrets": [], "missing_secrets": [], "steps": [], "error": None})
    # Double fork through `_spawn`, so the worker is nobody's child here: no zombie in a long-lived
    # caller (the MCP server, the web UI), and the worker outlives the push, the CLI and the session.
    env = {"HOME": str(home()), "PATH": BASE_PATH, "LANG": "C.UTF-8"}
    if "AGENTOS_CI_MAX_PARALLEL" in os.environ:
        env["AGENTOS_CI_MAX_PARALLEL"] = os.environ["AGENTOS_CI_MAX_PARALLEL"]
    subprocess.run([sys.executable, MAIN, "_spawn", run_id], env=env, cwd=str(home()),
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    prune()
    return run_id


def spawn(run_id) -> None:
    d = run_dir(run_id)
    with open(d / "worker.log", "ab") as log:
        p = subprocess.Popen([sys.executable, MAIN, "_worker", run_id], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    (d / "pid").write_text(f"{p.pid}\n")


def prune(keep=KEEP) -> None:
    if not runs_dir().is_dir():
        return
    ids = sorted((p.name for p in runs_dir().iterdir() if ID_RE.match(p.name)), reverse=True)
    for rid in ids[keep:]:
        try:
            status = json.loads((runs_dir() / rid / "run.json").read_text())["status"]
        except (OSError, ValueError, KeyError):
            status = "error"
        if status in FINAL:
            shutil.rmtree(runs_dir() / rid, ignore_errors=True)


def acquire_slot(stop):
    slots = state_dir() / "slots"
    slots.mkdir(parents=True, exist_ok=True)
    # ponytail: no strict FIFO; queued runs race for a free slot every 0.5 s.
    while not stop["why"]:
        for i in range(max_parallel()):
            f = open(slots / f"{i}.lock", "w")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return f                   # held until the worker exits
            except BlockingIOError:
                f.close()
        time.sleep(0.5)
    return None


def read_secrets(names) -> dict:
    """Values of the listed names only, parsed like /usr/local/lib/agentos/load-secrets.sh."""
    try:
        text = (home() / ".config/agentos/secrets.env").read_text()
    except OSError:
        return {}
    out = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep and k in names:
            out[k] = v
    return out


def step_env(run_id, names) -> dict:
    h = str(home())
    env = {"PATH": f"{h}/.local/bin:{h}/.cargo/bin:{h}/.bun/bin:{BASE_PATH}", "HOME": h, "LANG": "C.UTF-8",
           "CI": "true", "AGENTOS_CI_RUN": run_id}
    env.update(read_secrets(set(names)))
    return env


def command(p, step, work, run_id, n) -> tuple:
    if not p.image:
        return ["bash", "-eo", "pipefail", "-c", step.run], None
    name = f"agentos-ci-{run_id}-{n}"
    argv = ["docker", "run", "--rm", "--name", name, "-v", f"{work}:/w", "-w", "/w",
            "-e", "CI", "-e", "AGENTOS_CI_RUN"]
    for s in p.secrets:
        argv += ["-e", s]                  # value from the environment: never on a command line
    return argv + [p.image, "bash", "-eo", "pipefail", "-c", step.run], name


def killpg(pgid, sig) -> None:
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def run_step(argv, env, cwd, logf, deadline, stop, pgid_file) -> tuple:
    """Run one step in its own process group. Returns (exit code, None | "cancelled" | "timeout")."""
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT,
                         start_new_session=True)
    pgid_file.write_text(f"{p.pid}\n")
    reason, termed_at = None, None
    while True:
        try:
            code = p.wait(timeout=0.2)
            break
        except subprocess.TimeoutExpired:
            pass
        t = time.monotonic()
        if reason is None and (stop["why"] or t > deadline):
            reason = stop["why"] or "timeout"
            killpg(p.pid, signal.SIGTERM)
            termed_at = t
        elif termed_at is not None and t - termed_at > KILL_GRACE:
            killpg(p.pid, signal.SIGKILL)
            termed_at = float("inf")
    killpg(p.pid, signal.SIGKILL)          # whatever the step left behind in its group
    pgid_file.unlink(missing_ok=True)
    return code, reason


def checkout(repo, commit, work) -> None:
    shutil.rmtree(work, ignore_errors=True)
    work.parent.mkdir(parents=True, exist_ok=True)
    # --shared works for bare repos and work trees alike, and never touches the source repo.
    git("clone", "--quiet", "--shared", "--no-checkout", "--", repo, str(work))
    git("checkout", "--quiet", "--detach", commit, cwd=work)


def finish(run, status) -> None:
    run.update(status=status, finished=now())
    save(run)


def worker(run_id) -> None:
    run = load(run_id)
    d = run_dir(run_id)
    stop = {"why": None}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(why="cancelled"))
    slot = acquire_slot(stop)
    if slot is None:
        return finish(run, "cancelled")
    run.update(status="running", started=now())
    save(run)
    work = work_root() / run_id
    image = None
    try:
        checkout(run["repo"], run["commit"], work)
        try:
            p = pipeline.select(work)
        except pipeline.ConfigError as e:
            run["error"] = str(e)
            return finish(run, "error")
        image = p.image
        found = read_secrets(set(p.secrets))
        run.update(pipeline=p.kind, image=p.image, secrets=p.secrets,
                   missing_secrets=[s for s in p.secrets if s not in found],
                   steps=[{"name": s.name, "status": "pending", "exit_code": None, "started": None, "finished": None}
                          for s in p.steps])
        save(run)
        env = step_env(run_id, p.secrets)
        deadline = time.monotonic() + p.timeout_s
        status = "passed"
        for n, (step, st) in enumerate(zip(p.steps, run["steps"])):
            if stop["why"] and status == "passed":
                status = "cancelled"
            if status != "passed":
                st["status"] = "skipped"
                continue
            st.update(status="running", started=now())
            save(run)
            argv, container = command(p, step, work, run_id, n)
            with open(d / f"{step.name}.log", "ab") as logf:
                code, reason = run_step(argv, env, work, logf, deadline, stop, d / "pgid")
                if reason == "timeout":
                    logf.write(f"\n[agentos-ci: run timed out after {p.timeout_s}s]\n".encode())
            if container and reason:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            st.update(exit_code=code, finished=now(),
                      status="passed" if code == 0 and not reason else "cancelled" if reason == "cancelled" else "failed")
            if st["status"] != "passed":
                status = "cancelled" if reason == "cancelled" else "failed"
            save(run)
        finish(run, status)
    except CIError as e:
        run["error"] = str(e)
        finish(run, "error")
    finally:
        if image and work.exists():
            # Container steps ran as root: their files in the checkout are root-owned. ponytail: clean
            # up with the run's own image instead of a --user mapping that breaks images expecting root.
            subprocess.run(["docker", "run", "--rm", "-v", f"{work}:/w", image, "find", "/w", "-mindepth", "1", "-delete"],
                           capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


def status(run_id) -> dict:
    return refresh(load(run_id))


def list_runs(repo=None, limit=20) -> list:
    want = str(repo_root(repo)) if repo else None
    if not runs_dir().is_dir():
        return []
    out = []
    for rid in sorted((p.name for p in runs_dir().iterdir() if ID_RE.match(p.name)), reverse=True):
        try:
            run = refresh(load(rid))
        except (CIError, OSError, ValueError):
            continue
        if want is None or run["repo"] == want:
            out.append(run)
            if len(out) >= limit:
                break
    return out


def cancel(run_id) -> dict:
    run = load(run_id)
    if run["status"] in FINAL:
        return run
    d = run_dir(run_id)
    pid = read_int(d / "pid")
    if alive(pid):
        os.kill(pid, signal.SIGTERM)       # the worker TERMs its step's group, KILLs it 10 s later
    deadline = time.monotonic() + KILL_GRACE + 5
    while time.monotonic() < deadline:
        run = load(run_id)
        if run["status"] in FINAL:
            return run
        time.sleep(0.2)
    # The worker is stuck or gone: kill what is left and record the cancel here.
    for f in ("pgid", "pid"):
        g = read_int(d / f)
        if g:
            killpg(g, signal.SIGKILL)
    run = load(run_id)
    if run["status"] not in FINAL:
        run["error"] = "the worker did not stop; killed"
        finish(run, "cancelled")
    return run


def default_step(run) -> str | None:
    steps = run["steps"]
    for st in steps:
        if st["status"] in ("failed", "cancelled"):
            return st["name"]
    started = [st["name"] for st in steps if st["status"] != "pending" and st["status"] != "skipped"]
    return started[-1] if started else None


def log_path(run, step) -> Path:
    names = [st["name"] for st in run["steps"]]
    if step not in names:
        raise CIError(f"run {run['id']} has no step {step!r}" + (f"; steps: {', '.join(names)}" if names else ""))
    return runs_dir() / run["id"] / f"{step}.log"


def tail(path: Path, n: int) -> str:
    try:
        with open(path, errors="replace") as f:
            return "".join(collections.deque(f, maxlen=max(0, n)))
    except FileNotFoundError:
        return ""


def logs(run_id, step=None, n=200) -> dict:
    run = status(run_id)
    step = step or default_step(run)
    if step is None:
        return {"step": None, "text": run["error"] or ""}
    return {"step": step, "text": tail(log_path(run, step), n)}


def follow(run_id, step, out) -> None:
    """Write the step's log to out as it grows; return once the run is final and the log drained."""
    run = status(run_id)
    step = step or default_step(run)
    while step is None and run["status"] not in FINAL:
        time.sleep(0.5)
        run = status(run_id)
        step = default_step(run)
    if step is None:
        out.write(run["error"] or "")
        out.flush()
        return
    path = log_path(run, step)
    pos = 0
    while True:
        final = status(run_id)["status"] in FINAL
        try:
            with open(path, "rb") as f:
                f.seek(pos)
                chunk = f.read()
        except FileNotFoundError:
            chunk = b""
        if chunk:
            pos += len(chunk)
            out.write(chunk.decode("utf-8", "replace"))
            out.flush()
        elif final:
            return
        else:
            time.sleep(0.3)


def wait(run_id, timeout_s=1800) -> dict:
    deadline = time.monotonic() + max(0, timeout_s)
    run = status(run_id)
    while run["status"] not in FINAL and time.monotonic() < deadline:
        time.sleep(1)
        run = status(run_id)
    return summary(run)


def summary(run) -> dict:
    failed = next((st["name"] for st in run["steps"] if st["status"] in ("failed", "cancelled")), None)
    text = tail(log_path(run, failed), 200) if failed else (run["error"] or "") if run["status"] == "error" else ""
    return {"run_id": run["id"], "status": run["status"], "failed_step": failed, "log_tail": text}
```

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/cli.py`:
```python
"""agentos-ci command line. Every command takes --json; errors exit 2 with the reason on stderr."""
import argparse
import json
import sys

from . import pipeline, runs


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    p = argparse.ArgumentParser(prog="agentos-ci", description="Built-in CI for AgentOS.")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", parents=[common], help="start a run")
    r.add_argument("path", nargs="?", default=".")
    r.add_argument("--ref", default="HEAD")
    r.add_argument("--wait", action="store_true", help="wait; exit 0 only if the run passed")
    r.add_argument("--source", default="cli", choices=["cli", "push", "web", "mcp"], help=argparse.SUPPRESS)
    s = sub.add_parser("status", parents=[common], help="show a run")
    s.add_argument("id")
    lg = sub.add_parser("logs", parents=[common], help="print a step's log")
    lg.add_argument("id")
    lg.add_argument("--step")
    lg.add_argument("--tail", type=int, default=200)
    lg.add_argument("--follow", action="store_true")
    ls = sub.add_parser("list", parents=[common], help="list runs, newest first")
    ls.add_argument("--repo")
    ls.add_argument("--limit", type=int, default=20)
    c = sub.add_parser("cancel", parents=[common], help="cancel a run")
    c.add_argument("id")
    for hidden in ("_spawn", "_worker"):
        sub.add_parser(hidden).add_argument("id")
    return p


def out(args, data, text) -> None:
    print(json.dumps(data, indent=2) if args.json else text)


def fmt_run(run) -> str:
    lines = [f"{run['id']}  {run['status']}  {run['repo']}  {run['ref']}  {run['commit'][:12]}"]
    lines += [f"  {st['status']:<9} {st['name']}" + (f" (exit {st['exit_code']})" if st["exit_code"] not in (None, 0) else "")
              for st in run["steps"]]
    if run.get("error"):
        lines.append(f"  error: {run['error']}")
    return "\n".join(lines)


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.cmd == "run":
            run_id = runs.start(args.path, args.ref, args.source)
            if not args.wait:
                out(args, {"run_id": run_id}, run_id)
                return 0
            s = runs.wait(run_id, 10 ** 9)
            out(args, s, f"{run_id} {s['status']}" + (f"\n--- {s['failed_step']} ---\n{s['log_tail']}" if s["log_tail"] else ""))
            return 0 if s["status"] == "passed" else 1
        if args.cmd == "status":
            run = runs.status(args.id)
            out(args, run, fmt_run(run))
        elif args.cmd == "logs":
            if args.follow:
                runs.follow(args.id, args.step, sys.stdout)
            else:
                lg = runs.logs(args.id, args.step, args.tail)
                if args.json:
                    out(args, lg, "")
                else:
                    sys.stdout.write(lg["text"])
        elif args.cmd == "list":
            rs = runs.list_runs(args.repo, max(1, min(args.limit, 1000)))
            out(args, rs, "\n".join(f"{r['id']}  {r['status']:<9}  {r['repo']}  {r['ref']}" for r in rs))
        elif args.cmd == "cancel":
            run = runs.cancel(args.id)
            out(args, run, f"{run['id']} {run['status']}")
        elif args.cmd == "_spawn":
            runs.spawn(args.id)
        elif args.cmd == "_worker":
            runs.worker(args.id)
    except (runs.CIError, pipeline.ConfigError) as e:
        print(f"agentos-ci: {e}", file=sys.stderr)
        return 2
    return 0
```

`mkosi.extra/usr/local/bin/agentos-ci`:
```bash
#!/bin/bash
# AgentOS built-in CI. See `agentos-ci --help`.
set -euo pipefail
exec /usr/local/lib/agentos/venv/bin/python /usr/local/lib/agentos/ci/main.py "$@"
```

- [ ] **Step 4: Settings, deps, invariants**

In `mkosi.extra/usr/local/lib/agentos/env.sh`, find:
```bash
    AGENTOS_MAX_DESKTOPS)         re='^([1-9]|1[0-6])$'; want='a number from 1 to 16' ;;
```
Replace with:
```bash
    AGENTOS_MAX_DESKTOPS|AGENTOS_CI_MAX_PARALLEL) re='^([1-9]|1[0-6])$'; want='a number from 1 to 16' ;;
```

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, find:
```bash
# 6. Console lockout prevention last, so it sees Tailscale. It restarts getty@tty1, which is
```
Insert before it:
```bash
# 5d. CI settings for agentos-ci (runs as agent; agentos.env is root-only). Invalid -> default.
cp=$(env_get "$AGENTOS_ENV" AGENTOS_CI_MAX_PARALLEL | grep -xE '[1-9]|1[0-6]' || echo 2)
printf 'MAX_PARALLEL=%s\n' "$cp" > /etc/agentos/ci.conf
chmod 644 /etc/agentos/ci.conf

```

In `mkosi.prepare.chroot`, find:
```bash
# agentos-computer MCP server deps, isolated from the system and the agent's own Python.
python3 -m venv /usr/local/lib/agentos/venv
/usr/local/lib/agentos/venv/bin/pip install --no-cache-dir --disable-pip-version-check 'mcp>=1.28,<2' 'pillow>=10'
```
Replace with:
```bash
# agentos-computer and agentos-ci deps, isolated from the system and the agent's own Python.
python3 -m venv /usr/local/lib/agentos/venv
/usr/local/lib/agentos/venv/bin/pip install --no-cache-dir --disable-pip-version-check 'mcp>=1.28,<2' 'pillow>=10' 'pyyaml>=6,<7'
```

In `mkosi.finalize.chroot`, find:
```bash
{ echo "# agentos-computer python"; /usr/local/lib/agentos/venv/bin/pip freeze --disable-pip-version-check; } >> /var/lib/agentos-manifest.txt
```
Replace with (`check_computer_manifest` greps the `^# agentos-computer python` prefix, which still matches):
```bash
{ echo "# agentos-computer python (venv shared with agentos-ci)"; /usr/local/lib/agentos/venv/bin/pip freeze --disable-pip-version-check; } >> /var/lib/agentos-manifest.txt
```
Then find the Task 1 wrapper loop (`for c in claude codex opencode grok; do` … `is not the CLI wrapper"` … `done`) and insert before it:
```bash
# CI and Solenta state, and the skill files register-mcp installs at boot, are per-install.
for f in "$A/.local/share/agentos-ci" "$A/.cache/agentos-ci" "$A/git" "$A/solenta" "$A/.config/Solenta" "$A/.solenta" \
         "$A/.codex/AGENTS.md" "$A/.config/opencode/AGENTS.md" "$A/.grok/skills"; do
  if [ -e "$f" ]; then fail "per-install state baked into image: $f"; fi
done
/usr/local/lib/agentos/venv/bin/python -c 'import yaml, mcp' || fail "agentos-ci python deps missing"
```

- [ ] **Step 5: Run the tests**

Run: `chmod 755 mkosi.extra/usr/local/bin/agentos-ci && /tmp/agentos-ci-venv/bin/python -m pytest -q test/ci`
Expected: `47 passed` (about 35 s: the queue, cancel and timeout tests wait on real processes).

Run: `.superpowers/sdd/devvm.sh sh 'test/env_test.sh && shellcheck -S warning mkosi.extra/usr/local/bin/agentos-ci mkosi.extra/usr/local/sbin/agentos-firstboot mkosi.prepare.chroot mkosi.finalize.chroot && echo SC-OK'`
Expected: `validate_setting OK`, `SC-OK`.

- [ ] **Step 6: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/ci mkosi.extra/usr/local/bin/agentos-ci mkosi.extra/usr/local/lib/agentos/env.sh \
  mkosi.extra/usr/local/sbin/agentos-firstboot mkosi.prepare.chroot mkosi.finalize.chroot test/ci test/env_test.sh
git commit -m "feat(ci): agentos-ci engine: pipeline selection, isolated runs, flock queue, cancel, retention"
```

---

### Task 6: Push remotes, the `post-receive` hook, and `act`

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/remotes.py`, `mkosi.extra/usr/local/lib/agentos/ci/post-receive` (mode 755)
- Modify: `mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/cli.py`, `mkosi.prepare.chroot` (act), `mkosi.finalize.chroot` (manifest)
- Test: `test/ci/test_remotes_hook.py` (new)

**Interfaces:**
- Consumes: `runs.git`, `runs.home`, `CIError` (Task 5); `pipeline.ACT_PLATFORMS` (Task 5 already selects workflows and builds the `act` command).
- Produces:
  - `remotes.create(name) -> {name, path, remote_add}`, `remotes.list_remotes() -> [same]`, `NAME_RE`, `box_host()`;
  - `agentos-ci remote create NAME` / `remote list`;
  - the shared hook at `/usr/local/lib/agentos/ci/post-receive`, symlinked into each remote. It honors `AGENTOS_CI` (tests) and calls `agentos-ci run --source push --ref refs/heads/<branch> -- <repo>`;
  - `/usr/local/bin/act` 0.2.89 and the manifest line `act 0.2.89 <sha256>`.

- [ ] **Step 1: Write the failing test**

`test/ci/test_remotes_hook.py`:
```python
import os
import stat
import sys

import pytest
from conftest import CI_DIR, ci_yml, make_repo, sh, wait_final
from agentos_ci import remotes, runs
from agentos_ci.runs import CIError


@pytest.mark.parametrize("bad", ["", "-x", "A", "a_b", "a.b", "../x", "a" * 64, "x/y", "a b"])
def test_remote_names(home, bad):
    with pytest.raises(CIError, match="name must match"):
        remotes.create(bad)


def test_create_and_list(home, monkeypatch):
    monkeypatch.setattr(remotes, "box_host", lambda: "box.tail.ts.net")
    r = remotes.create("demo-1")
    assert r == {"name": "demo-1", "path": str(home / "git/demo-1.git"),
                 "remote_add": "git remote add agentos agent@box.tail.ts.net:git/demo-1.git"}
    hook = home / "git/demo-1.git/hooks/post-receive"
    assert hook.is_symlink() and os.readlink(hook) == str(CI_DIR / "post-receive")
    assert os.stat(CI_DIR / "post-receive").st_mode & stat.S_IXUSR
    with pytest.raises(CIError, match="already exists"):
        remotes.create("demo-1")
    (home / "git/Bad.git").mkdir()
    assert [x["name"] for x in remotes.list_remotes()] == ["demo-1"]


def launcher(tmp_path, record=None):
    """An agentos-ci for the hook: the real CLI, or a recorder that prints a fake id."""
    f = tmp_path / "agentos-ci"
    if record:
        f.write_text(f'#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done >> {record}\necho 20260101-000000-0000\n')
    else:
        f.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{CI_DIR / "main.py"}" "$@"\n')
    f.chmod(0o755)
    return f


def test_hook_runs_ci_per_branch_and_reports_the_id(home, tmp_path, monkeypatch):
    monkeypatch.setattr(remotes, "box_host", lambda: "box")
    remote = remotes.create("app")["path"]
    src = make_repo(tmp_path / "src", {".agentos/ci.yml": ci_yml(("t", "test -f .agentos/ci.yml"))})
    import subprocess
    sh("env", f"AGENTOS_CI={launcher(tmp_path)}", f"HOME={home}", "git", "push", remote, "main",
       "main:refs/heads/feature/x", cwd=src)
    r = subprocess.run(["env", f"AGENTOS_CI={launcher(tmp_path)}", f"HOME={home}", "git", "push", "--force", remote,
                        "main:refs/heads/again"], cwd=src, capture_output=True, text=True)
    assert "agentos-ci: run " in r.stderr and "for again" in r.stderr
    ids = [r["id"] for r in runs.list_runs()]
    assert len(ids) == 3
    for rid in ids:
        run = wait_final(rid)
        assert run["status"] == "passed" and run["source"] == "push" and run["repo"] == remote
    assert sorted(runs.status(i)["ref"] for i in ids) == ["refs/heads/again", "refs/heads/feature/x", "refs/heads/main"]


def test_hook_never_evaluates_ref_names(home, tmp_path):
    rec = tmp_path / "argv"
    remote = remotes.create("evil")["path"]
    src = make_repo(tmp_path / "src", {"a": "1"})
    import subprocess
    # Legal git branch names that a shell would execute: the hook runs in the bare repo, so a
    # successful injection would leave a "pwned" file there.
    r = subprocess.run(["env", f"AGENTOS_CI={launcher(tmp_path, rec)}", "git", "push", remote,
                        "main:refs/heads/$(id>pwned)", "main:refs/heads/`id>pwned`", "main:refs/heads/ok;id>pwned",
                        "main:refs/heads/fine", "main:refs/tags/v1"], cwd=src, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert not (tmp_path / "home/git/evil.git/pwned").exists()
    assert r.stderr.count("agentos-ci: skipped") == 4
    assert rec.read_text().splitlines() == ["run", "--source", "push", "--ref", "refs/heads/fine", "--", remote]
    # deleting a branch starts nothing
    rec.unlink()
    subprocess.run(["env", f"AGENTOS_CI={launcher(tmp_path, rec)}", "git", "push", remote, ":refs/heads/fine"],
                   cwd=src, capture_output=True, check=True)
    assert not rec.exists()
```

- [ ] **Step 2: Run it to see it fail**

Run: `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci/test_remotes_hook.py`
Expected: `ImportError: cannot import name 'remotes' from 'agentos_ci'`.

- [ ] **Step 3: Write the remotes module and the hook**

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/remotes.py`:
```python
"""Push remotes: bare repos in ~/git/<name>.git whose post-receive hook starts a run per pushed branch."""
import json
import re
import socket
import subprocess
from pathlib import Path

from .runs import CIError, git, home

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
HOOK = Path(__file__).resolve().parent.parent / "post-receive"


def git_root() -> Path:
    return home() / "git"


def box_host() -> str:
    """The tailnet DNS name when Tailscale is up, else the hostname."""
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5).stdout
        name = (json.loads(out).get("Self") or {}).get("DNSName") or ""
    except (OSError, ValueError, subprocess.TimeoutExpired):
        name = ""
    return name.rstrip(".") or socket.gethostname()


def remote_add(name, host) -> str:
    return f"git remote add agentos agent@{host}:git/{name}.git"


def create(name) -> dict:
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise CIError("name must match [a-z0-9][a-z0-9-]{0,62}")
    path = git_root() / f"{name}.git"
    if path.exists():
        raise CIError(f"{path} already exists")
    git_root().mkdir(parents=True, exist_ok=True)
    git("init", "--quiet", "--bare", str(path))
    hook = path / "hooks" / "post-receive"
    hook.unlink(missing_ok=True)
    hook.symlink_to(HOOK)                  # shared hook: image updates reach every remote
    return {"name": name, "path": str(path), "remote_add": remote_add(name, box_host())}


def list_remotes() -> list:
    if not git_root().is_dir():
        return []
    host = box_host()
    return [{"name": p.name[:-4], "path": str(p), "remote_add": remote_add(p.name[:-4], host)}
            for p in sorted(git_root().glob("*.git")) if p.is_dir() and NAME_RE.match(p.name[:-4])]
```

`mkosi.extra/usr/local/lib/agentos/ci/post-receive` (`chmod 755`):
```bash
#!/bin/bash
# agentos-ci post-receive hook, symlinked into ~/git/<name>.git/hooks/ by `agentos-ci remote create`.
# Starts one CI run per updated branch and tells the pusher the run id. Nothing from the push is
# ever evaluated: ref names must match a strict pattern, and every value reaches agentos-ci as its
# own argv word.
set -uo pipefail
repo=$(pwd -P)                          # git runs hooks inside the bare repository
while read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)
CI=${AGENTOS_CI:-/usr/local/bin/agentos-ci}
while read -r _old new ref; do
  [[ $new =~ ^0+$ ]] && continue        # branch deleted
  if ! [[ $ref =~ ^refs/heads/[A-Za-z0-9._/-]{1,200}$ ]] || ! git check-ref-format "$ref"; then
    printf 'agentos-ci: skipped %q: only branches named [A-Za-z0-9._/-] are built\n' "$ref"
    continue
  fi
  branch=${ref#refs/heads/}
  if id=$("$CI" run --source push --ref "$ref" -- "$repo"); then
    echo "agentos-ci: run $id for $branch (agentos-ci logs $id --follow)"
  else
    echo "agentos-ci: could not start a run for $branch"
  fi
done
exit 0
```

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/cli.py` (whole file; it adds the `remote` subcommands):
```python
"""agentos-ci command line. Every command takes --json; errors exit 2 with the reason on stderr."""
import argparse
import json
import sys

from . import pipeline, remotes, runs


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    p = argparse.ArgumentParser(prog="agentos-ci", description="Built-in CI for AgentOS.")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", parents=[common], help="start a run")
    r.add_argument("path", nargs="?", default=".")
    r.add_argument("--ref", default="HEAD")
    r.add_argument("--wait", action="store_true", help="wait; exit 0 only if the run passed")
    r.add_argument("--source", default="cli", choices=["cli", "push", "web", "mcp"], help=argparse.SUPPRESS)
    s = sub.add_parser("status", parents=[common], help="show a run")
    s.add_argument("id")
    lg = sub.add_parser("logs", parents=[common], help="print a step's log")
    lg.add_argument("id")
    lg.add_argument("--step")
    lg.add_argument("--tail", type=int, default=200)
    lg.add_argument("--follow", action="store_true")
    ls = sub.add_parser("list", parents=[common], help="list runs, newest first")
    ls.add_argument("--repo")
    ls.add_argument("--limit", type=int, default=20)
    c = sub.add_parser("cancel", parents=[common], help="cancel a run")
    c.add_argument("id")
    rm = sub.add_parser("remote", help="push remotes in ~/git")
    rsub = rm.add_subparsers(dest="rcmd", required=True)
    rc = rsub.add_parser("create", parents=[common])
    rc.add_argument("name")
    rsub.add_parser("list", parents=[common])
    for hidden in ("_spawn", "_worker"):
        sub.add_parser(hidden).add_argument("id")
    return p


def out(args, data, text) -> None:
    print(json.dumps(data, indent=2) if args.json else text)


def fmt_run(run) -> str:
    lines = [f"{run['id']}  {run['status']}  {run['repo']}  {run['ref']}  {run['commit'][:12]}"]
    lines += [f"  {st['status']:<9} {st['name']}" + (f" (exit {st['exit_code']})" if st["exit_code"] not in (None, 0) else "")
              for st in run["steps"]]
    if run.get("error"):
        lines.append(f"  error: {run['error']}")
    return "\n".join(lines)


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.cmd == "run":
            run_id = runs.start(args.path, args.ref, args.source)
            if not args.wait:
                out(args, {"run_id": run_id}, run_id)
                return 0
            s = runs.wait(run_id, 10 ** 9)
            out(args, s, f"{run_id} {s['status']}" + (f"\n--- {s['failed_step']} ---\n{s['log_tail']}" if s["log_tail"] else ""))
            return 0 if s["status"] == "passed" else 1
        if args.cmd == "status":
            run = runs.status(args.id)
            out(args, run, fmt_run(run))
        elif args.cmd == "logs":
            if args.follow:
                runs.follow(args.id, args.step, sys.stdout)
            else:
                lg = runs.logs(args.id, args.step, args.tail)
                if args.json:
                    out(args, lg, "")
                else:
                    sys.stdout.write(lg["text"])
        elif args.cmd == "list":
            rs = runs.list_runs(args.repo, max(1, min(args.limit, 1000)))
            out(args, rs, "\n".join(f"{r['id']}  {r['status']:<9}  {r['repo']}  {r['ref']}" for r in rs))
        elif args.cmd == "cancel":
            run = runs.cancel(args.id)
            out(args, run, f"{run['id']} {run['status']}")
        elif args.cmd == "remote" and args.rcmd == "create":
            r = remotes.create(args.name)
            out(args, r, f"created {r['path']}\nOn your machine: {r['remote_add']}")
        elif args.cmd == "remote":
            rs = remotes.list_remotes()
            out(args, rs, "\n".join(f"{r['name']}  {r['remote_add']}" for r in rs))
        elif args.cmd == "_spawn":
            runs.spawn(args.id)
        elif args.cmd == "_worker":
            runs.worker(args.id)
    except (runs.CIError, pipeline.ConfigError) as e:
        print(f"agentos-ci: {e}", file=sys.stderr)
        return 2
    return 0
```

- [ ] **Step 4: Install `act`, pinned**

In `mkosi.prepare.chroot`, find:
```bash
# The Mac-side Solenta bridge (Mode B), served for download by the web UI's Solenta card.
```
Insert before it:
```bash
# act runs .github/workflows for agentos-ci. Pinned by version and sha256 (the release's
# checksums.txt); Docker pulls its runner images on first use, they are never baked in.
ACT_VERSION=0.2.89
ACT_SHA256=0191d6f1f3b716b5c55820032605d05fc3c1cdbf581ebeff655019e5dd1524c0
at=$(mktemp -d)
curl -fsSL -o "$at/act.tgz" "https://github.com/nektos/act/releases/download/v$ACT_VERSION/act_Linux_x86_64.tar.gz"
echo "$ACT_SHA256  $at/act.tgz" | sha256sum -c --quiet -
tar -xzf "$at/act.tgz" -C "$at" act
install -m 755 "$at/act" /usr/local/bin/act
rm -rf "$at"

```

In `mkosi.finalize.chroot`, find:
```bash
{ echo "# agentos-computer python (venv shared with agentos-ci)"; /usr/local/lib/agentos/venv/bin/pip freeze --disable-pip-version-check; } >> /var/lib/agentos-manifest.txt
```
Add a line after it:
```bash
{ echo "# agentos-ci"; echo "act $(/usr/local/bin/act --version | awk '{print $3}') $(sha256sum /usr/local/bin/act | cut -d' ' -f1)"; } >> /var/lib/agentos-manifest.txt
```

- [ ] **Step 5: Run the tests**

Run: `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci`
Expected: `59 passed`.

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning mkosi.extra/usr/local/lib/agentos/ci/post-receive mkosi.prepare.chroot mkosi.finalize.chroot && echo SC-OK'`
Expected: `SC-OK`.

- [ ] **Step 6: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/ci mkosi.prepare.chroot mkosi.finalize.chroot test/ci/test_remotes_hook.py
git commit -m "feat(ci): push remotes with a validated post-receive hook; act 0.2.89 pinned by checksum"
```

---

### Task 7: The `agentos-ci` MCP server, registration, and the skill

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/mcp_server.py`, `mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/skill.py`, `mkosi.extra/usr/local/lib/agentos/ci/skill.md`, `mkosi.extra/usr/local/bin/agentos-ci-mcp` (mode 755)
- Modify: `mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/cli.py` (whole file), `mkosi.extra/usr/local/lib/agentos/register-mcp` (whole file), `mkosi.extra/usr/local/sbin/agentos-firstboot` (warning text)
- Test: `test/ci/test_skill_mcp.py` (new)

**Interfaces:**
- Consumes: `runs.start/status/summary/logs/list_runs/cancel`, `runs.FINAL`, `runs.home` (Task 5).
- Produces:
  - the MCP tools `ci_run(path, ref="HEAD") -> {run_id}`, `ci_wait(run_id, timeout_s=1800) -> {run_id, status, failed_step, log_tail}`, `ci_status(run_id) -> run.json`, `ci_logs(run_id, step=None, tail=200) -> {step, text}`, `ci_list(path=None, limit=20) -> [run.json]` and `ci_cancel(run_id) -> run.json`;
  - `/usr/local/bin/agentos-ci-mcp`;
  - `agentos-ci mcp` and `agentos-ci install-skill [--json]`;
  - `skill.install() -> {relpath: created|updated|unchanged|kept}`, `BEGIN`/`END` markers;
  - `register-mcp` registers `agentos-computer` and `agentos-ci` (Codex with `tool_timeout_sec = 1800`), then installs the skill.

- [ ] **Step 1: Write the failing test**

`test/ci/test_skill_mcp.py`:
```python
import asyncio

from conftest import ci_yml, make_repo
from agentos_ci import skill
from agentos_ci.skill import BEGIN, END


def test_skill_install_is_idempotent_and_keeps_user_content(home):
    assert set(skill.install().values()) == {"created"}
    claude = home / ".claude/skills/agentos-ci/SKILL.md"
    text = claude.read_text()
    assert text.startswith("---\nname: agentos-ci\ndescription: ") and BEGIN in text and "ci_wait" in text
    assert (home / ".grok/skills/agentos-ci/SKILL.md").read_text() == text
    assert set(skill.install().values()) == {"unchanged"}

    codex = home / ".codex/AGENTS.md"
    codex.write_text("# mine\nkeep me\n\n" + codex.read_text().replace("ci_wait", "OLD") + "\n# after\n")
    claude.write_text("my own skill\n")                                  # user replaced it: hands off
    oc = home / ".config/opencode/AGENTS.md"
    oc.write_text("user rules\n")
    res = skill.install()
    assert res[".codex/AGENTS.md"] == "updated" and res[".claude/skills/agentos-ci/SKILL.md"] == "kept"
    assert res[".config/opencode/AGENTS.md"] == "updated"
    c = codex.read_text()
    assert c.startswith("# mine\nkeep me\n\n") and c.rstrip().endswith("# after") and "OLD" not in c
    assert c.count(BEGIN) == 1 and c.count(END) == 1
    assert claude.read_text() == "my own skill\n"
    o = oc.read_text()
    assert o.startswith("user rules\n\n" + BEGIN) and o.count(BEGIN) == 1
    assert set(skill.install().values()) <= {"unchanged", "kept"}


def test_mcp_tools(home):
    from agentos_ci import mcp_server
    tools = {t.name for t in asyncio.run(mcp_server.mcp.list_tools())}
    assert tools == {"ci_run", "ci_wait", "ci_status", "ci_logs", "ci_list", "ci_cancel"}
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("t", "echo out; exit 1"))})
    rid = mcp_server.ci_run(str(repo))["run_id"]
    res = asyncio.run(mcp_server.ci_wait(rid, 60))
    assert res == {"run_id": rid, "status": "failed", "failed_step": "t", "log_tail": "out\n"}
```

- [ ] **Step 2: Run it to see it fail**

Run: `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci/test_skill_mcp.py`
Expected: `ImportError: cannot import name 'skill' from 'agentos_ci'`.

- [ ] **Step 3: Write the server, the skill and its installer**

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/mcp_server.py`:
```python
"""agentos-ci MCP server (stdio): lets agents start CI, wait for it and read failures."""
import asyncio

from mcp.server.fastmcp import FastMCP

from . import runs

mcp = FastMCP("agentos-ci", log_level="WARNING")


@mcp.tool()
def ci_run(path: str, ref: str = "HEAD") -> dict:
    """Start a CI run of the committed tree at `ref` in the git repository at `path` (inside
    /home/agent). Returns {run_id}. Commit first: uncommitted edits are not part of the run."""
    return {"run_id": runs.start(path, ref, source="mcp")}


@mcp.tool()
async def ci_wait(run_id: str, timeout_s: int = 1800) -> dict:
    """Wait until the run finishes (or timeout_s passes). Returns {run_id, status, failed_step,
    log_tail}: log_tail is the last 200 lines of the failing step. Still queued or running when it
    returns: call ci_wait again."""
    deadline = asyncio.get_running_loop().time() + max(0, timeout_s)
    run = runs.status(run_id)
    while run["status"] not in runs.FINAL and asyncio.get_running_loop().time() < deadline:
        await asyncio.sleep(1)
        run = runs.status(run_id)
    return runs.summary(run)


@mcp.tool()
def ci_status(run_id: str) -> dict:
    """The run's state: status, repo, ref, commit, pipeline, and per-step status and exit codes."""
    return runs.status(run_id)


@mcp.tool()
def ci_logs(run_id: str, step: str | None = None, tail: int = 200) -> dict:
    """The last `tail` lines of a step's log (default: the failing step, else the latest one)."""
    return runs.logs(run_id, step, min(max(int(tail), 1), 5000))


@mcp.tool()
def ci_list(path: str | None = None, limit: int = 20) -> list[dict]:
    """Recent runs, newest first; only the repository at `path` when given."""
    return runs.list_runs(path, min(max(int(limit), 1), 200))


@mcp.tool()
def ci_cancel(run_id: str) -> dict:
    """Cancel a queued or running run (SIGTERM to its step, SIGKILL after 10 s)."""
    return runs.cancel(run_id)


def main() -> None:
    mcp.run()
```

`mkosi.extra/usr/local/lib/agentos/ci/skill.md` (the spec's `agentos-ci.md`; one source for all four CLIs):
```markdown
# AgentOS CI

This machine runs CI for any git repository under /home/agent. Use the `agentos-ci` MCP tools
(`ci_run`, `ci_wait`, `ci_logs`, `ci_status`, `ci_list`, `ci_cancel`), or the `agentos-ci` command.

Before you declare a task in a repository done, and the repository has CI (`.agentos/ci.yml`,
`.github/workflows/`, or a test entry point such as an npm `test` script, pytest, `cargo test`,
`go test` or a Makefile `test` target):

1. Commit your work. CI runs the committed tree, never uncommitted edits.
2. Call `ci_run(path=<repository>, ref="HEAD")`, then `ci_wait(run_id)`. If `ci_wait` comes back
   while the run is still `queued` or `running` (your client cut the call short), call it again.
3. On `failed`: read `log_tail`, or `ci_logs(run_id, step)` for more, fix the root cause, commit,
   and run CI again.
4. On `error`: the message says why (for example, no CI configuration found). Fix it, or tell the user.

Never weaken, skip or delete tests or CI configuration to get a pass.

When you report back, give the run id and its result.
```

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/skill.py`:
```python
"""Install the agentos-ci skill text into each agent CLI's skill or global-instructions file.

Idempotent. Only the marked block is ever replaced; a skill file the user rewrote without the
markers is left alone, and other content in a shared AGENTS.md is never touched.
"""
import os
import re
from pathlib import Path

from .runs import home

SOURCE = Path(__file__).resolve().parent.parent / "skill.md"
BEGIN = "<!-- agentos-ci:begin (managed by AgentOS; this block is rewritten at boot, edit outside it) -->"
END = "<!-- agentos-ci:end -->"
BLOCK_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", re.S)
FRONT = ("---\nname: agentos-ci\ndescription: Run this box's built-in CI with the agentos-ci MCP tools before "
         "declaring work in a repo done; read failures, fix the root cause, re-run.\n---\n\n")
# (path under $HOME, is a whole skill file)
TARGETS = [
    (".claude/skills/agentos-ci/SKILL.md", True),     # Claude Code; opencode also reads ~/.claude/skills
    (".grok/skills/agentos-ci/SKILL.md", True),       # Grok Build user skills
    (".codex/AGENTS.md", False),                      # Codex global instructions
    (".config/opencode/AGENTS.md", False),            # opencode global rules
]


def block() -> str:
    return f"{BEGIN}\n{SOURCE.read_text().strip()}\n{END}\n"


def write_atomic(path: Path, text: str) -> None:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text)
    if path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o7777)
    os.replace(tmp, path)


def upsert(path: Path, is_skill: bool) -> str:
    b = block()
    if not path.exists():
        write_atomic(path, (FRONT if is_skill else "") + b)
        return "created"
    text = path.read_text()
    if BLOCK_RE.search(text):
        new = BLOCK_RE.sub(lambda _: b, text, count=1)
    elif is_skill:
        return "kept"                      # the user replaced our skill file: theirs now
    else:
        new = text + ("" if text.endswith("\n\n") or not text else "\n" if text.endswith("\n") else "\n\n") + b
    if new == text:
        return "unchanged"
    write_atomic(path, new)
    return "updated"


def install() -> dict:
    return {rel: upsert(home() / rel, is_skill) for rel, is_skill in TARGETS}
```

`mkosi.extra/usr/local/lib/agentos/ci/agentos_ci/cli.py` (whole file; it adds `mcp` and `install-skill`):
```python
"""agentos-ci command line. Every command takes --json; errors exit 2 with the reason on stderr."""
import argparse
import json
import sys

from . import pipeline, remotes, runs, skill


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    p = argparse.ArgumentParser(prog="agentos-ci", description="Built-in CI for AgentOS.")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", parents=[common], help="start a run")
    r.add_argument("path", nargs="?", default=".")
    r.add_argument("--ref", default="HEAD")
    r.add_argument("--wait", action="store_true", help="wait; exit 0 only if the run passed")
    r.add_argument("--source", default="cli", choices=["cli", "push", "web", "mcp"], help=argparse.SUPPRESS)
    s = sub.add_parser("status", parents=[common], help="show a run")
    s.add_argument("id")
    lg = sub.add_parser("logs", parents=[common], help="print a step's log")
    lg.add_argument("id")
    lg.add_argument("--step")
    lg.add_argument("--tail", type=int, default=200)
    lg.add_argument("--follow", action="store_true")
    ls = sub.add_parser("list", parents=[common], help="list runs, newest first")
    ls.add_argument("--repo")
    ls.add_argument("--limit", type=int, default=20)
    c = sub.add_parser("cancel", parents=[common], help="cancel a run")
    c.add_argument("id")
    rm = sub.add_parser("remote", help="push remotes in ~/git")
    rsub = rm.add_subparsers(dest="rcmd", required=True)
    rc = rsub.add_parser("create", parents=[common])
    rc.add_argument("name")
    rsub.add_parser("list", parents=[common])
    sub.add_parser("mcp", help="run the MCP server on stdio")
    sub.add_parser("install-skill", parents=[common], help="install the agent skill (register-mcp runs this)")
    for hidden in ("_spawn", "_worker"):
        sub.add_parser(hidden).add_argument("id")
    return p


def out(args, data, text) -> None:
    print(json.dumps(data, indent=2) if args.json else text)


def fmt_run(run) -> str:
    lines = [f"{run['id']}  {run['status']}  {run['repo']}  {run['ref']}  {run['commit'][:12]}"]
    lines += [f"  {st['status']:<9} {st['name']}" + (f" (exit {st['exit_code']})" if st["exit_code"] not in (None, 0) else "")
              for st in run["steps"]]
    if run.get("error"):
        lines.append(f"  error: {run['error']}")
    return "\n".join(lines)


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.cmd == "run":
            run_id = runs.start(args.path, args.ref, args.source)
            if not args.wait:
                out(args, {"run_id": run_id}, run_id)
                return 0
            s = runs.wait(run_id, 10 ** 9)
            out(args, s, f"{run_id} {s['status']}" + (f"\n--- {s['failed_step']} ---\n{s['log_tail']}" if s["log_tail"] else ""))
            return 0 if s["status"] == "passed" else 1
        if args.cmd == "status":
            run = runs.status(args.id)
            out(args, run, fmt_run(run))
        elif args.cmd == "logs":
            if args.follow:
                runs.follow(args.id, args.step, sys.stdout)
            else:
                lg = runs.logs(args.id, args.step, args.tail)
                if args.json:
                    out(args, lg, "")
                else:
                    sys.stdout.write(lg["text"])
        elif args.cmd == "list":
            rs = runs.list_runs(args.repo, max(1, min(args.limit, 1000)))
            out(args, rs, "\n".join(f"{r['id']}  {r['status']:<9}  {r['repo']}  {r['ref']}" for r in rs))
        elif args.cmd == "cancel":
            run = runs.cancel(args.id)
            out(args, run, f"{run['id']} {run['status']}")
        elif args.cmd == "remote" and args.rcmd == "create":
            r = remotes.create(args.name)
            out(args, r, f"created {r['path']}\nOn your machine: {r['remote_add']}")
        elif args.cmd == "remote":
            rs = remotes.list_remotes()
            out(args, rs, "\n".join(f"{r['name']}  {r['remote_add']}" for r in rs))
        elif args.cmd == "mcp":
            from . import mcp_server
            mcp_server.main()
        elif args.cmd == "install-skill":
            res = skill.install()
            out(args, res, "\n".join(f"{v:<9} ~/{k}" for k, v in res.items()))
        elif args.cmd == "_spawn":
            runs.spawn(args.id)
        elif args.cmd == "_worker":
            runs.worker(args.id)
    except (runs.CIError, pipeline.ConfigError) as e:
        print(f"agentos-ci: {e}", file=sys.stderr)
        return 2
    return 0
```

`mkosi.extra/usr/local/bin/agentos-ci-mcp`:
```bash
#!/bin/bash
# agentos-ci MCP server on stdio (registered with every agent CLI by register-mcp).
set -euo pipefail
exec /usr/local/lib/agentos/venv/bin/python /usr/local/lib/agentos/ci/main.py mcp
```

- [ ] **Step 4: Register at boot**

`mkosi.extra/usr/local/lib/agentos/register-mcp` (whole file: the per-CLI code moves into `register()`, unchanged except for the optional Codex line):
```bash
#!/bin/bash
# Register AgentOS's MCP servers (agentos-computer, agentos-ci) with every agent CLI, and install
# the agentos-ci skill. Idempotent, runs as agent at every boot (from agentos-firstboot), never
# edits other entries. Done at boot, not build time, so no CLI state is baked into the image.
set -euo pipefail
rc=0

# Hold one lock for the whole run: a concurrent run (e.g. two boots racing, or a manual re-apply)
# must not interleave writes to the same config files.
LOCKDIR=$HOME/.config/agentos
mkdir -p "$LOCKDIR"
exec 9>"$LOCKDIR/register-mcp.lock"
flock 9

# append_atomically <file> <printf-fmt> [args...]: copy, append to the copy, then mv over the
# original (keeping its mode), so a reader never sees a half-written file.
append_atomically() {
  local f=$1; shift
  f=$(readlink -f "$f")
  local tmp; tmp=$(mktemp "$f.XXXXXX")
  # shellcheck disable=SC2059 # the format string is a fixed caller-supplied literal, not data
  cp -p "$f" "$tmp" && printf "$@" >>"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# register <name> <command> [codex-extra]: the command takes no arguments (a launcher per server),
# so every CLI's config shape stays the same. codex-extra is one more TOML line for Codex only.
register() {
  local name=$1 cmd=$2 extra=${3:-} f tmp x
  # Claude Code (user scope, ~/.claude.json)
  if ! claude mcp get "$name" >/dev/null 2>&1; then
    claude mcp add --scope user "$name" -- "$cmd" >/dev/null || { echo "claude: registering $name failed" >&2; rc=1; }
  fi
  # Codex and Grok share the TOML shape
  for f in "$HOME/.codex/config.toml" "$HOME/.grok/config.toml"; do
    mkdir -p "$(dirname "$f")"; touch "$f"
    [[ $f == */.codex/* && -n $extra ]] && x="$extra"$'\n' || x=
    grep -q "^\[mcp_servers\.$name\]" "$f" || append_atomically "$f" '\n[mcp_servers.%s]\ncommand = "%s"\n%s' "$name" "$cmd" "$x"
  done
  # opencode (JSON)
  f=$HOME/.config/opencode/opencode.json
  mkdir -p "$(dirname "$f")"
  [ -s "$f" ] || printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$f"
  tmp=$(mktemp "$f.XXXXXX")
  if jq --arg n "$name" --arg c "$cmd" '.mcp[$n] //= {type: "local", command: [$c], enabled: true}' "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; echo "opencode: $f is not valid JSON, left untouched" >&2; rc=1
  fi
}

register agentos-computer /usr/local/bin/agentos-computer
# ci_wait blocks until a run ends; Codex cuts an MCP tool call off after 300 s by default. (The
# skill tells agents of every CLI to call ci_wait again if it returns early.)
register agentos-ci /usr/local/bin/agentos-ci-mcp 'tool_timeout_sec = 1800'
grep -q '^\[mcp\]' "$HOME/.grok/config.toml" || append_atomically "$HOME/.grok/config.toml" '\n[mcp]\nmax_output_bytes = 4000000\n'

/usr/local/bin/agentos-ci install-skill >/dev/null || { echo "agentos-ci: skill install failed" >&2; rc=1; }
exit "$rc"
```

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, find:
```bash
  /usr/local/lib/agentos/register-mcp || echo "warning: agentos-computer MCP registration incomplete" >&2
```
Replace with:
```bash
  /usr/local/lib/agentos/register-mcp || echo "warning: MCP registration or agentos-ci skill install incomplete" >&2
```

- [ ] **Step 5: Run the tests**

Run: `chmod 755 mkosi.extra/usr/local/bin/agentos-ci-mcp && /tmp/agentos-ci-venv/bin/python -m pytest -q test/ci`
Expected: `61 passed`.

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning mkosi.extra/usr/local/lib/agentos/register-mcp mkosi.extra/usr/local/bin/agentos-ci-mcp mkosi.extra/usr/local/sbin/agentos-firstboot && echo SC-OK'`
Expected: `SC-OK`.

- [ ] **Step 6: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/ci mkosi.extra/usr/local/bin/agentos-ci-mcp mkosi.extra/usr/local/lib/agentos/register-mcp \
  mkosi.extra/usr/local/sbin/agentos-firstboot test/ci/test_skill_mcp.py
git commit -m "feat(ci): agentos-ci MCP server registered with every CLI; agentos-ci skill with managed blocks"
```

---

### Task 8: Web UI: the CI page, the Solenta card, the Overview status

**Files:**
- Create: `web/server/src/ci.ts`; `web/ui/src/pages/CI.tsx`, `web/ui/src/components/SolentaCard.tsx`, `web/ui/src/components/Copy.tsx`
- Modify: `web/server/src/actions.ts` (whole file), `web/server/src/app.ts` (whole file), `web/server/src/system.ts`, `web/server/src/settings.ts`
- Modify: `web/ui/src/App.tsx`, `web/ui/src/pages/Overview.tsx`, `web/ui/src/pages/Settings.tsx` (whole files), `web/ui/src/types.ts`, `web/ui/src/format.ts`, `web/ui/src/style.css` (appends)
- Test: `web/server/test/ci.test.ts` (new), `web/server/test/system.test.ts` (one test added), `web/ui/test/CI.test.tsx`, `web/ui/test/SolentaCard.test.tsx` (new), `web/ui/test/Settings.test.tsx` (mock extended)

**Interfaces:**
- Consumes:
  - the `agentos-ci … --json` outputs (Tasks 5–7) and their exit code 2 for a bad request;
  - `/api/solenta`, `/api/solenta/clone` and `/api/solenta/bridge` (Tasks 3–4);
  - `resolveDir` and `DirPicker`, `LogStream`, `usePoll`, `confirmAction`.
- Produces, on the server:
  - `GET /api/ci/runs?repo=&limit=`, `GET /api/ci/runs/:id`, `POST /api/ci/runs {path, ref?}` (201 `{run_id}`), `POST /api/ci/runs/:id/rerun` (201 `{run_id}`), `POST /api/ci/runs/:id/cancel`, `GET /api/ci/remotes`;
  - the WebSocket `GET /api/ci/runs/:id/log?step=`;
  - audits `ci-run <path>`, `ci-rerun <id>` and `ci-cancel <id>`;
  - `streamToSocket` gains backpressure (journal and update streams too);
  - `PLAIN_KEYS` gains `AGENTOS_SOLENTA` and `AGENTOS_CI_MAX_PARALLEL`;
  - `ciJson(deps, action)`.
- Produces, in the UI: the routes `/ci` and `/ci/<id>`; the types `CiRun`, `CiStep`, `CiRemote`, `SolentaStatus`, `PreflightItem`; `duration(start, end, now?)`, `FINAL_CI`; and the `<Copy text label?>` component.

- [ ] **Step 1: Write the failing tests**

`web/server/test/ci.test.ts`:
```ts
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { argv } from '../src/actions.js';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const CI = '/usr/local/bin/agentos-ci';
const ID = '20261027-101500-0001';
const RUN = { id: ID, repo: '/home/agent/work/app', ref: 'HEAD', commit: 'a'.repeat(40), status: 'failed', steps: [] };

describe('ci actions', () => {
  it('builds exact argv, values after "--" or as --opt=value', () => {
    expect(argv({ name: 'ci-run', path: '/home/agent/x', ref: 'main' })).toEqual([CI, 'run', '--json', '--source', 'web', '--ref', 'main', '--', '/home/agent/x']);
    expect(argv({ name: 'ci-status', id: ID })).toEqual([CI, 'status', '--json', ID]);
    expect(argv({ name: 'ci-list', limit: 5 })).toEqual([CI, 'list', '--json', '--limit', '5']);
    expect(argv({ name: 'ci-list', limit: 5, repo: '/home/agent/x' })).toEqual([CI, 'list', '--json', '--limit', '5', '--repo=/home/agent/x']);
    expect(argv({ name: 'ci-cancel', id: ID })).toEqual([CI, 'cancel', '--json', ID]);
    expect(argv({ name: 'ci-log', id: ID, step: 'test' })).toEqual([CI, 'logs', ID, '--follow', '--step=test']);
    expect(argv({ name: 'ci-log', id: ID, step: '' })).toEqual([CI, 'logs', ID, '--follow']);
    expect(argv({ name: 'ci-remotes' })).toEqual([CI, 'remote', 'list', '--json']);
    expect(argv({ name: 'solenta-status', path: '/home/agent/w' })).toEqual(['/usr/local/lib/agentos/solenta-pair', 'status', '--', '/home/agent/w']);
  });
  it('rejects bad ids, refs, steps, limits and relative paths', () => {
    for (const id of ['', '../x', '20261027-101500-zzzz', `${ID};id`]) expect(() => argv({ name: 'ci-status', id })).toThrow(/run id/);
    for (const ref of ['-x', '--upload-pack=x', 'a b', '']) expect(() => argv({ name: 'ci-run', path: '/home/agent', ref })).toThrow(/ref/);
    for (const step of ['../run.json', '-x', 'a/b']) expect(() => argv({ name: 'ci-log', id: ID, step })).toThrow(/step/);
    expect(() => argv({ name: 'ci-run', path: 'rel', ref: 'HEAD' })).toThrow(/path/);
    expect(() => argv({ name: 'ci-list', limit: 0 })).toThrow(/limit/);
    expect(() => argv({ name: 'ci-list', limit: 1.5 })).toThrow(/limit/);
  });
});

describe('ci routes', () => {
  it('lists, shows and maps agentos-ci errors to 400', async () => {
    const { deps, calls } = fakeDeps((a) => a[1] === 'status' && a[3] === '20261027-000000-0000'
      ? { code: 2, stderr: 'agentos-ci: no run 20261027-000000-0000\n' }
      : { stdout: JSON.stringify(a[1] === 'list' ? [RUN] : RUN) });
    const app = await buildApp(deps);
    const list = await app.inject({ url: '/api/ci/runs?limit=7', headers: H });
    expect(list.json()).toEqual([RUN]);
    expect(calls.at(-1)!.argv).toEqual([CI, 'list', '--json', '--limit', '7']);
    expect((await app.inject({ url: `/api/ci/runs/${ID}`, headers: H })).json()).toEqual(RUN);
    const missing = await app.inject({ url: '/api/ci/runs/20261027-000000-0000', headers: H });
    expect(missing.statusCode).toBe(400);
    expect(missing.json().error).toBe('no run 20261027-000000-0000');
    expect((await app.inject({ url: '/api/ci/runs/..%2Fx', headers: H })).statusCode).toBe(400);
  });

  it('runs a directory inside home only, audited; rerun pins the commit; cancel audited', async () => {
    const { deps, calls, audits } = fakeDeps((a) => ({ stdout: JSON.stringify(a[1] === 'run' ? { run_id: ID } : RUN) }));
    mkdirSync(join(deps.home, 'proj'));
    const app = await buildApp(deps);
    const post = (url: string, payload?: object) => app.inject({ method: 'POST', url, headers: HM, payload });
    expect((await post('/api/ci/runs', { path: '/etc' })).statusCode).toBe(400);
    expect((await post('/api/ci/runs', {})).statusCode).toBe(400);
    expect(calls).toEqual([]);
    const r = await post('/api/ci/runs', { path: join(deps.home, 'proj'), ref: 'main' });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ run_id: ID });
    expect(calls.at(-1)!.argv).toEqual([CI, 'run', '--json', '--source', 'web', '--ref', 'main', '--', join(deps.home, 'proj')]);
    expect((await post(`/api/ci/runs/${ID}/rerun`)).statusCode).toBe(201);
    expect(calls.at(-1)!.argv).toEqual([CI, 'run', '--json', '--source', 'web', '--ref', 'a'.repeat(40), '--', RUN.repo]);
    expect((await post(`/api/ci/runs/${ID}/cancel`)).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual([CI, 'cancel', '--json', ID]);
    expect(audits).toEqual([`${LOGIN} ci-run ${join(deps.home, 'proj')}`, `${LOGIN} ci-rerun ${ID}`, `${LOGIN} ci-cancel ${ID}`]);
  });

  it('mutations need the CSRF headers', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: `/api/ci/runs/${ID}/cancel`, headers: H })).statusCode).toBe(403);
    expect(calls).toEqual([]);
  });

  it('streams a step log over the WebSocket, and refuses a bad step', async () => {
    const { deps } = fakeDeps();
    const app = await buildApp(deps);
    await app.ready();
    const ws = await app.injectWS(`/api/ci/runs/${ID}/log?step=..%2Frun.json`, { headers: HM });
    const closed = await new Promise<number>((resolve) => ws.on('close', (code) => resolve(code)));
    expect(closed).toBe(1008);
  });
});
```

In `web/server/test/system.test.ts`, find:
```ts
  it('kills the journal stream on socket close, but leaves the update stream running', async () => {
```
Insert before it:
```ts
  it('pauses the command while the socket is backed up, resumes once it drains', async () => {
    const cbs: (() => void)[] = [];
    const sent: string[] = [];
    const s = Object.assign(new EventEmitter(), { OPEN: 1, readyState: 1, bufferedAmount: 0,
      send: (d: string, cb: () => void) => { sent.push(d); cbs.push(cb); }, close: () => {} });
    const child = streamToSocket(s as never, ['node', '-e', 'setInterval(()=>process.stdout.write("x".repeat(1000)),5)']);
    while (sent.length === 0) await delay(10);
    s.bufferedAmount = 2 * 1024 * 1024;
    while (!child.stdout!.isPaused()) await delay(10);
    s.bufferedAmount = 0;
    cbs.at(-1)!();
    expect(child.stdout!.isPaused()).toBe(false);
    child.kill();
  });
```

`web/ui/test/CI.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { duration } from '../src/format';
import { CI } from '../src/pages/CI';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
HTMLElement.prototype.scrollTo = () => {};   // jsdom has no layout

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const ID = '20261027-101500-0001';
const RUN = { id: ID, repo: '/home/agent/work/app', ref: 'refs/heads/main', commit: 'abcdef0123456789', source: 'push', status: 'failed',
  created: '2026-10-27T10:15:00Z', started: '2026-10-27T10:15:00Z', finished: '2026-10-27T10:16:05Z', pipeline: 'ci.yml', image: null,
  secrets: ['NPM_TOKEN'], missing_secrets: [], error: null,
  steps: [{ name: 'install', status: 'passed', exit_code: 0, started: null, finished: null },
          { name: 'test', status: 'failed', exit_code: 1, started: null, finished: null }] };

class FakeWS {
  static all: FakeWS[] = [];
  onmessage: ((e: { data: string }) => void) | null = null;
  onclose: ((e: { reason: string }) => void) | null = null;
  constructor(public url: string) { FakeWS.all.push(this); }
  close() {}
}

it('formats durations', () => {
  expect(duration('2026-10-27T10:15:00Z', '2026-10-27T10:16:05Z')).toBe('1m 05s');
  expect(duration('2026-10-27T10:15:00Z', '2026-10-27T10:15:09Z')).toBe('9s');
  expect(duration(null, null)).toBe('');
});

it('lists runs and push remotes, and starts a run for a picked directory', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === 'POST') return json({ run_id: ID }, 201);
    if (url.startsWith('/api/ci/runs')) return json([RUN]);
    if (url === '/api/ci/remotes') return json([{ name: 'app', path: '/home/agent/git/app.git', remote_add: 'git remote add agentos agent@box:git/app.git' }]);
    return json({ path: '/home/agent', parent: null, dirs: ['work'] });
  });
  vi.stubGlobal('fetch', fetch);
  render(<CI />);
  expect(await screen.findByText(ID)).toBeTruthy();
  expect(screen.getByText('~/work/app')).toBeTruthy();
  expect(screen.getByText('1m 05s')).toBeTruthy();
  expect(await screen.findByText('git remote add agentos agent@box:git/app.git')).toBeTruthy();
  const run = screen.getByText('Run CI', { selector: 'button' }) as HTMLButtonElement;
  expect(run.disabled).toBe(true);
  fireEvent.click(await screen.findByText('work/'));
  fireEvent.click(run);
  await vi.waitFor(() => expect(location.pathname).toBe(`/ci/${ID}`));
  const post = fetch.mock.calls.find(([, i]) => i?.method === 'POST')!;
  expect(post[0]).toBe('/api/ci/runs');
  expect(JSON.parse(post[1]!.body as string)).toEqual({ path: '/home/agent/work', ref: 'HEAD' });
});

it('shows a run, streams the failing step log by default, switches steps, re-runs and cancels', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) =>
    init?.method === 'POST' ? json(url.endsWith('/rerun') ? { run_id: '20261027-101600-0000' } : RUN) : json({ ...RUN, status: 'running' }));
  vi.stubGlobal('fetch', fetch);
  vi.stubGlobal('WebSocket', FakeWS);
  vi.stubGlobal('confirm', () => true);
  render(<CI id={ID} />);
  expect(await screen.findByText('Secrets exposed: NPM_TOKEN')).toBeTruthy();
  await vi.waitFor(() => expect(FakeWS.all.at(-1)!.url).toMatch(new RegExp(`/api/ci/runs/${ID}/log\\?step=test$`)));
  FakeWS.all.at(-1)!.onmessage!({ data: 'npm ERR! 1 failing\n' });
  expect(await screen.findByText(/1 failing/)).toBeTruthy();
  fireEvent.click(screen.getByText('install'));
  await vi.waitFor(() => expect(FakeWS.all.at(-1)!.url).toMatch(/step=install$/));
  fireEvent.click(screen.getByText('Cancel'));
  await vi.waitFor(() => expect(fetch.mock.calls.some(([u, i]) => u === `/api/ci/runs/${ID}/cancel` && i?.method === 'POST')).toBe(true));
  fireEvent.click(screen.getByText('Re-run'));
  await vi.waitFor(() => expect(location.pathname).toBe('/ci/20261027-101600-0000'));
});
```

`web/ui/test/SolentaCard.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { SolentaCard } from '../src/components/SolentaCard';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const FP = 'SHA256:' + 'k'.repeat(43);
const status = (path: string | null) => ({
  host: 'box.tail.ts.net', remoteHost: 'agent@box.tail.ts.net', remotePath: path, tailscaleSsh: false,
  hostKeys: [{ type: 'ssh-ed25519', fingerprint: FP }],
  keyscan: 'ssh-keyscan -t ed25519 box.tail.ts.net >> ~/.ssh/known_hosts',
  modeA: { enabled: true, service: 'active', version: '0.26.0', webToken: true },
  preflight: [{ item: 'claude', ok: true, detail: '/home/agent/.local/bin/claude' }, { item: 'grok', ok: false, detail: 'agentos: grok is not installed for user agent' }],
});

it('shows Mode A first, fingerprints and the keyscan line, then clones and re-runs the preflight for the checkout', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/api/solenta/clone') return json({ path: '/home/agent/work/app' }, 201);
    if (url.startsWith('/api/solenta')) return json(status(url.includes('path=') ? decodeURIComponent(url.split('path=')[1]) : null));
    return json({ path: '/home/agent', parent: null, dirs: [] });
  });
  vi.stubGlobal('fetch', fetch);
  render(<SolentaCard />);
  const modeA = await screen.findByText('Mode A: Solenta on this box (recommended)');
  expect(modeA.compareDocumentPosition(screen.getByText('Mode B: Solenta on the Mac, agents here')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(screen.getByText(`ssh-ed25519 ${FP}`)).toBeTruthy();
  expect(screen.getByText('ssh-keyscan -t ed25519 box.tail.ts.net >> ~/.ssh/known_hosts')).toBeTruthy();
  expect(screen.getByText('FAIL')).toBeTruthy();
  expect(document.body.textContent).toContain('web token present');
  fireEvent.change(screen.getByLabelText('Git URL'), { target: { value: 'https://example.com/app.git' } });
  fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'app' } });
  fireEvent.click(screen.getByText('Clone into ~/work'));
  expect(await screen.findByText('/home/agent/work/app')).toBeTruthy();
  expect(fetch.mock.calls.some(([u]) => u === `/api/solenta?path=${encodeURIComponent('/home/agent/work/app')}`)).toBe(true);
  expect(JSON.parse(fetch.mock.calls.find(([u]) => u === '/api/solenta/clone')![1]!.body as string)).toEqual({ repo: 'https://example.com/app.git', name: 'app' });
});
```

In `web/ui/test/Settings.test.tsx`, find:
```tsx
    if (url === '/api/settings') return json({ values: {}, secrets: { ANTHROPIC_API_KEY: false } });
```
Replace with (Settings now renders the Solenta card, which fetches these):
```tsx
    if (url === '/api/settings') return json({ values: {}, secrets: { ANTHROPIC_API_KEY: false } });
    if (url.startsWith('/api/solenta')) return json({ host: 'b', remoteHost: 'agent@b', remotePath: null, tailscaleSsh: true, hostKeys: [], keyscan: '',
      modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] });
    if (url.startsWith('/api/dirs')) return json({ path: '/home/agent', parent: null, dirs: [] });
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd web/server && npx vitest run test/ci.test.ts test/system.test.ts`
Expected: FAIL. `argv` throws on `ci-run` (unknown action), and the backpressure test times out waiting for `isPaused()`.

Run: `cd web/ui && npx vitest run`
Expected: FAIL. `Failed to resolve import "../src/pages/CI"` and `"../src/components/SolentaCard"`.

- [ ] **Step 3: Server**

`web/server/src/actions.ts` (whole file):
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
export const CI = '/usr/local/bin/agentos-ci';
export const SOLENTA_PAIR = '/usr/local/lib/agentos/solenta-pair';
export const CI_ID_RE = /^\d{8}-\d{6}-[0-9a-f]{4}$/;
export const STEP_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
export const GIT_REF_RE = /^[A-Za-z0-9_][A-Za-z0-9_./@^~{}-]{0,254}$/;   // agentos-ci's REF_RE
const ABS_PATH_RE = /^\/[^\0\n]*$/;

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
  | { name: 'desktop-stop'; n: number }
  // agentos-ci and solenta-pair run as agent (this service's user): no sudo.
  | { name: 'ci-run'; path: string; ref: string }
  | { name: 'ci-status'; id: string }
  | { name: 'ci-list'; repo?: string; limit: number }
  | { name: 'ci-cancel'; id: string }
  | { name: 'ci-log'; id: string; step: string }       // streamed: logs --follow
  | { name: 'ci-remotes' }
  | { name: 'solenta-status'; path?: string };

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
    case 'ci-run': need(ABS_PATH_RE.test(a.path), 'path'); need(GIT_REF_RE.test(a.ref), 'ref');
      return [CI, 'run', '--json', '--source', 'web', '--ref', a.ref, '--', a.path];
    case 'ci-status': need(CI_ID_RE.test(a.id), 'run id'); return [CI, 'status', '--json', a.id];
    case 'ci-list': need(Number.isInteger(a.limit) && a.limit >= 1 && a.limit <= 200, 'limit');
      if (a.repo !== undefined) need(ABS_PATH_RE.test(a.repo), 'repo');
      return [CI, 'list', '--json', '--limit', String(a.limit), ...(a.repo ? [`--repo=${a.repo}`] : [])];
    case 'ci-cancel': need(CI_ID_RE.test(a.id), 'run id'); return [CI, 'cancel', '--json', a.id];
    case 'ci-log': need(CI_ID_RE.test(a.id), 'run id'); need(a.step === '' || STEP_RE.test(a.step), 'step');
      return [CI, 'logs', a.id, '--follow', ...(a.step ? [`--step=${a.step}`] : [])];
    case 'ci-remotes': return [CI, 'remote', 'list', '--json'];
    case 'solenta-status': if (a.path !== undefined) need(ABS_PATH_RE.test(a.path), 'path');
      return [SOLENTA_PAIR, 'status', ...(a.path ? ['--', a.path] : [])];
  }
}

export async function runAction(run: Runner, a: Action, opts?: RunOpts): Promise<RunResult> {
  return run(argv(a), opts);
}
```

`web/server/src/ci.ts`:
```ts
// Built-in CI: every call runs `agentos-ci … --json` as agent (this service's user), never sudo.
// agentos-ci validates again; the actions table validates first.
import type { FastifyInstance } from 'fastify';
import { type Action, argv, runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { resolveDir } from './sessions.js';
import { streamToSocket } from './system.js';

// agentos-ci exits 2 for a bad request (unknown run, bad ref, no repository): the user's error.
export async function ciJson<T = unknown>(deps: Deps, a: Action): Promise<T> {
  const r = await runAction(deps.run, a, { timeoutMs: 60_000 });
  if (r.code !== 0) throw new HttpError(r.code === 2 ? 400 : 500, r.stderr.replace(/^agentos-ci: /, '').trim() || 'agentos-ci failed');
  return JSON.parse(r.stdout) as T;
}

interface RunInfo { id: string; repo: string; commit: string }

export function ciRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Querystring: { repo?: string; limit?: string } }>('/api/ci/runs', async (req) => {
    const limit = /^\d{1,3}$/.test(req.query.limit ?? '') ? Math.min(Math.max(Number(req.query.limit), 1), 200) : 50;
    const repo = req.query.repo ? await resolveDir(req.query.repo, deps.home) : undefined;
    return ciJson(deps, { name: 'ci-list', repo, limit });
  });
  app.get<{ Params: { id: string } }>('/api/ci/runs/:id', async (req) => ciJson(deps, { name: 'ci-status', id: req.params.id }));
  app.post<{ Body: { path?: string; ref?: string } }>('/api/ci/runs', async (req, reply) => {
    const path = await resolveDir(String(req.body?.path ?? ''), deps.home);
    const out = await ciJson(deps, { name: 'ci-run', path, ref: String(req.body?.ref || 'HEAD') });
    deps.audit(req.login, 'ci-run', path);
    return reply.code(201).send(out);
  });
  app.post<{ Params: { id: string } }>('/api/ci/runs/:id/rerun', async (req, reply) => {
    const run = await ciJson<RunInfo>(deps, { name: 'ci-status', id: req.params.id });
    const out = await ciJson(deps, { name: 'ci-run', path: run.repo, ref: run.commit });
    deps.audit(req.login, 'ci-rerun', req.params.id);
    return reply.code(201).send(out);
  });
  app.post<{ Params: { id: string } }>('/api/ci/runs/:id/cancel', async (req) => {
    const out = await ciJson(deps, { name: 'ci-cancel', id: req.params.id });
    deps.audit(req.login, 'ci-cancel', req.params.id);
    return out;
  });
  app.get('/api/ci/remotes', async () => ciJson(deps, { name: 'ci-remotes' }));
  app.get<{ Params: { id: string }; Querystring: { step?: string } }>('/api/ci/runs/:id/log', { websocket: true }, (socket, req) => {
    try {
      streamToSocket(socket, argv({ name: 'ci-log', id: req.params.id, step: req.query.step ?? '' }));
    } catch (e) {
      socket.close(1008, (e as Error).message);
    }
  });
}
```

`web/server/src/app.ts` (whole file):
```ts
// Fastify app: the auth hook first, then the API, then the static UI with an SPA fallback.
import { existsSync } from 'node:fs';
import { join } from 'node:path';
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
import { TOKEN_DIR, vncRoutes } from './vnc.js';
import { systemRoutes } from './system.js';
import { ciRoutes } from './ci.js';
import { solentaRoutes } from './solenta.js';

export interface Deps {
  run: Runner;
  webConf: () => WebConf;
  tsName: () => Promise<string | null>;
  audit: Audit;
  home: string;
  uiRoot: string | null;
  novncRoot: string | null;
  vncTokenDir: string;
  bridgePath: string;     // tools/solenta-bridge, served for download by the Solenta card
}

export function cachedTailnetName(run: Runner, ttlMs = 60_000): () => Promise<string | null> {
  let value: string | null = null;
  let at = 0;
  let inflight: Promise<string | null> | null = null;   // single-flight: share one call on expiry
  return async () => {
    if (Date.now() - at <= ttlMs) return value;
    inflight ??= run(['tailscale', 'status', '--json'], { timeoutMs: 5000 })
      .then((r) => parseTailnetName(r.stdout))
      .finally(() => { inflight = null; });
    const v = await inflight;
    // Cache only a real name: a failed lookup (tailscaled starting, logged out) is retried next time.
    if (v !== null) { value = v; at = Date.now(); }
    return v;
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
    vncTokenDir: TOKEN_DIR,
    bridgePath: '/usr/local/share/agentos/solenta-bridge',
  };
}

export async function buildApp(deps: Deps): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: 'warn' }, bodyLimit: 1024 * 1024 });
  // A bodyless mutating action (stop, create-with-no-fields) still gets `Content-Type:
  // application/json` from some clients (the smoke checks' CSRF-header helper, among others).
  // Fastify's default parser treats that as an error; treat an empty body as {} instead.
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    if (body === '') return done(null, {});
    try {
      done(null, JSON.parse(body as string));
    } catch (err) {
      (err as Error & { statusCode?: number }).statusCode = 400;
      done(err as Error, undefined);
    }
  });
  app.decorateRequest('login', '');
  // Anti-clickjacking headers on every response, including 401/403 and static files.
  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Content-Security-Policy', "frame-ancestors 'none'");
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('Referrer-Policy', 'no-referrer');
    return payload;
  });
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
  vncRoutes(app, deps, undefined, deps.vncTokenDir);
  systemRoutes(app, deps);
  ciRoutes(app, deps);
  solentaRoutes(app, deps);

  // Only what DesktopView imports (core/rfb.js and the vendor/ modules it loads), not noVNC's own
  // app (vnc.html and friends). Separate roots, so "core/../vnc.html" can't climb out.
  for (const dir of ['core', 'vendor']) {
    const root = deps.novncRoot && join(deps.novncRoot, dir);
    if (root && existsSync(root)) await app.register(fastifyStatic, { root, prefix: `/novnc/${dir}/`, decorateReply: false });
  }
  if (deps.uiRoot && existsSync(deps.uiRoot)) {
    await app.register(fastifyStatic, { root: deps.uiRoot, prefix: '/' });
    app.setNotFoundHandler((req, reply) =>
      req.url.startsWith('/api/') ? reply.code(404).send({ error: 'not found' }) : reply.sendFile('index.html'));
  }
  return app;
}
```

In `web/server/src/system.ts`, find:
```ts
// Stream a command's output to a WebSocket. killOnClose=false for agentos-update: closing the
// tab must not kill apt mid-upgrade.
export function streamToSocket(socket: WebSocket, args: string[], killOnClose = true): ChildProcess {
  const child = spawn(args[0], args.slice(1), { stdio: ['ignore', 'pipe', 'pipe'] });
  const send = (b: Buffer) => socket.readyState === socket.OPEN && socket.send(b.toString('utf8'));
```
Replace with:
```ts
const HIGH_WATER = 1024 * 1024;
const LOW_WATER = 256 * 1024;

// Stream a command's output to a WebSocket. killOnClose=false for agentos-update: closing the
// tab must not kill apt mid-upgrade. Backpressure as in terminal.ts: a slow browser pauses the
// command's pipes (so a big CI log or journal can't grow the socket buffer without bound).
export function streamToSocket(socket: WebSocket, args: string[], killOnClose = true): ChildProcess {
  const child = spawn(args[0], args.slice(1), { stdio: ['ignore', 'pipe', 'pipe'] });
  let paused = false;
  const send = (b: Buffer) => {
    if (socket.readyState !== socket.OPEN) return;
    socket.send(b.toString('utf8'), () => {
      if (paused && socket.bufferedAmount < LOW_WATER) { paused = false; child.stdout.resume(); child.stderr.resume(); }
    });
    if (!paused && socket.bufferedAmount > HIGH_WATER) { paused = true; child.stdout.pause(); child.stderr.pause(); }
  };
```

In `web/server/src/settings.ts`, find:
```ts
  'AGENTOS_SCREENSHOT_WIDTH', 'AGENTOS_DESKTOP_IDLE_MINUTES', 'AGENTOS_WEB_USERS', 'AGENTOS_WEB'];
```
Replace with:
```ts
  'AGENTOS_SCREENSHOT_WIDTH', 'AGENTOS_DESKTOP_IDLE_MINUTES', 'AGENTOS_WEB_USERS', 'AGENTOS_WEB',
  'AGENTOS_SOLENTA', 'AGENTOS_CI_MAX_PARALLEL'];
```

- [ ] **Step 4: UI**

Append to `web/ui/src/types.ts`:
```ts
export type CiStatus = 'queued' | 'running' | 'passed' | 'failed' | 'cancelled' | 'error';
export interface CiStep { name: string; status: string; exit_code: number | null; started: string | null; finished: string | null }
export interface CiRun {
  id: string; repo: string; ref: string; commit: string; source: string; status: CiStatus;
  created: string; started: string | null; finished: string | null; pipeline: string | null; image: string | null;
  secrets: string[]; missing_secrets: string[]; steps: CiStep[]; error: string | null;
}
export interface CiRemote { name: string; path: string; remote_add: string }
export interface PreflightItem { item: string; ok: boolean; detail: string }
export interface SolentaStatus {
  host: string; remoteHost: string; remotePath: string | null; tailscaleSsh: boolean;
  hostKeys: { type: string; fingerprint: string }[]; keyscan: string;
  modeA: { enabled: boolean; service: string; version: string | null; webToken: boolean };
  preflight: PreflightItem[];
}
```

Append to `web/ui/src/format.ts`:
```ts
// "1m 05s" between two ISO times (end defaults to now), '' before the start.
export function duration(start: string | null, end: string | null, now = Date.now()): string {
  if (!start) return '';
  const s = Math.max(0, Math.round(((end ? Date.parse(end) : now) - Date.parse(start)) / 1000));
  return s >= 60 ? `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s` : `${s}s`;
}
export const FINAL_CI = ['passed', 'failed', 'cancelled', 'error'];
```

Append to `web/ui/src/style.css`:
```css
.ci-passed { color: var(--ok); }
.ci-failed, .ci-error { color: var(--bad); }
.ci-queued, .ci-running, .ci-cancelled, .ci-skipped, .ci-pending { color: var(--muted); }
.copy { display: flex; gap: 8px; align-items: center; margin: 4px 0; }
.copy code { overflow-wrap: anywhere; }
```

`web/ui/src/components/Copy.tsx`:
```tsx
// A value to paste somewhere else, with a Copy button.
export function Copy({ text, label }: { text: string; label?: string }) {
  return (
    <div className="copy">
      {label && <span>{label}</span>}
      <code>{text}</code>
      <button type="button" onClick={() => void navigator.clipboard?.writeText(text)}>Copy</button>
    </div>
  );
}
```

`web/ui/src/components/SolentaCard.tsx`:
```tsx
import { type FormEvent, useState } from 'react';
import { api } from '../api';
import type { SolentaStatus } from '../types';
import { usePoll } from '../usePoll';
import { Copy } from './Copy';
import { DirPicker } from './DirPicker';
import { ErrorText } from './ErrorText';

// Solenta pairing: Mode A (Solenta on this box, recommended) first, then Mode B (Solenta on the
// Mac, agents here). Facts come from solenta-pair; nothing here ever shows a Solenta token.
export function SolentaCard() {
  const [path, setPath] = useState('');
  const [repo, setRepo] = useState('');
  const [name, setName] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const st = usePoll(() => api<SolentaStatus>(`/api/solenta${path ? `?path=${encodeURIComponent(path)}` : ''}`), 0, [path]);
  const s = st.data;

  async function clone(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    try {
      setPath((await api<{ path: string }>('/api/solenta/clone', 'POST', { repo, name })).path);
      setRepo('');
    } catch (e2) {
      setErr((e2 as Error).message);
    }
    setBusy(false);
  }

  return (
    <div className="panel">
      <h2>Solenta</h2>
      <ErrorText error={st.error} />
      {s && (
        <>
          <h3>Mode A: Solenta on this box (recommended)</h3>
          <p className="hint">In Solenta, open Settings, Connections, Remote Connections, and add <code>{s.remoteHost}</code>. Solenta installs itself here over SSH; AgentOS keeps it running.</p>
          <p>agentos-solenta: <span className={s.modeA.service === 'active' ? 'ok' : ''}>{s.modeA.service}</span>
            {s.modeA.enabled ? '' : ' (turned off below)'} · Solenta {s.modeA.version ?? 'not installed yet'} ·
            web token {s.modeA.webToken ? 'present' : 'absent'}</p>

          <h3>SSH from the Mac</h3>
          <p>{s.tailscaleSsh ? 'Tailscale SSH is on: your tailnet policy decides who may connect.'
            : 'Add the Mac’s public key under SSH keys above.'}</p>
          <p className="hint">Solenta refuses hosts that aren't in the Mac's known_hosts. Compare these fingerprints with what <code>ssh {s.remoteHost}</code> shows, then run the line below on the Mac.</p>
          <ul className="keys">{s.hostKeys.map((k) => <li key={k.fingerprint}><code>{k.type} {k.fingerprint}</code></li>)}</ul>
          <Copy text={s.keyscan} />

          <h3>Mode B: Solenta on the Mac, agents here</h3>
          <form className="field" onSubmit={clone}>
            <input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="https://github.com/org/repo.git" aria-label="Git URL" required />
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder="name" aria-label="Name" pattern="[a-z0-9-]{1,32}" required />
            <button disabled={busy}>{busy ? 'Cloning…' : 'Clone into ~/work'}</button>
          </form>
          <ErrorText error={err} />
          <p className="hint">Or pick an existing checkout:</p>
          <DirPicker value={path} onChange={setPath} />
          <Copy label="remoteHost" text={s.remoteHost} />
          {s.remotePath && <Copy label="remotePath" text={s.remotePath} />}
          <h3>Preflight</h3>
          <table><tbody>
            {s.preflight.map((p) => (
              <tr key={p.item}><td className={p.ok ? 'ok' : 'bad'}>{p.ok ? 'PASS' : 'FAIL'}</td><td>{p.item}</td><td><code>{p.detail}</code></td></tr>
            ))}
          </tbody></table>
          <p>For Solenta's thread and memory tools, run the <a href="/api/solenta/bridge" download>solenta-bridge</a> on the Mac:
            {' '}<code>bash solenta-bridge install {s.remoteHost}</code></p>
          <p className="hint">Security: the bridge exposes Solenta's MCP ports only on this box's loopback, and they still need Solenta's bearer token. Solenta gives that token to the agents it runs here, so they get the same power over Solenta on the Mac that a local Solenta run has.</p>
        </>
      )}
    </div>
  );
}
```

`web/ui/src/pages/CI.tsx`:
```tsx
import { type FormEvent, useState } from 'react';
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { Copy } from '../components/Copy';
import { DirPicker } from '../components/DirPicker';
import { ErrorText } from '../components/ErrorText';
import { LogStream } from '../components/LogStream';
import { duration, FINAL_CI } from '../format';
import { Link, navigate } from '../router';
import type { CiRemote, CiRun } from '../types';
import { usePoll } from '../usePoll';

export function CI({ id }: { id?: string }) {
  return id ? <RunView id={id} /> : <Runs />;
}

function Runs() {
  const runs = usePoll(() => api<CiRun[]>('/api/ci/runs?limit=50'), 5000);
  const remotes = usePoll(() => api<CiRemote[]>('/api/ci/remotes'));
  const [path, setPath] = useState('');
  const [ref, setRef] = useState('HEAD');
  const [err, setErr] = useState<string | null>(null);

  async function run(e: FormEvent) {
    e.preventDefault();
    setErr(null);
    try {
      navigate(`/ci/${(await api<{ run_id: string }>('/api/ci/runs', 'POST', { path, ref })).run_id}`);
    } catch (e2) {
      setErr((e2 as Error).message);
    }
  }

  return (
    <section>
      <h1>CI</h1>
      <ErrorText error={runs.error} />
      <table>
        <thead><tr><th>Run</th><th>Repo</th><th>Ref</th><th>Commit</th><th>Status</th><th>Duration</th></tr></thead>
        <tbody>
          {runs.data?.map((r) => (
            <tr key={r.id}>
              <td><Link to={`/ci/${r.id}`}>{r.id}</Link></td>
              <td>{r.repo.replace(/^\/home\/agent\//, '~/')}</td>
              <td>{r.ref}</td>
              <td><code>{r.commit.slice(0, 10)}</code></td>
              <td className={`ci-${r.status}`}>{r.status}</td>
              <td>{duration(r.started, r.finished)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {runs.data?.length === 0 && <p className="hint">No runs yet.</p>}
      <form className="panel" onSubmit={run}>
        <h2>Run CI</h2>
        <DirPicker value={path} onChange={setPath} />
        <label>Ref <input value={ref} onChange={(e) => setRef(e.target.value)} aria-label="Ref" /></label>
        <ErrorText error={err} />
        <button disabled={!path}>Run CI</button>
      </form>
      <div className="panel">
        <h2>Push remotes</h2>
        <p className="hint">Each push to one of these runs CI for every pushed branch. Create one with <code>agentos-ci remote create NAME</code>.</p>
        {remotes.data?.map((r) => <Copy key={r.name} label={r.name} text={r.remote_add} />)}
        {remotes.data?.length === 0 && <p className="hint">None yet.</p>}
      </div>
    </section>
  );
}

function RunView({ id }: { id: string }) {
  const { data: run, error, reload } = usePoll(() => api<CiRun>(`/api/ci/runs/${encodeURIComponent(id)}`), 2000, [id]);
  const [picked, setPicked] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const final = !!run && FINAL_CI.includes(run.status);
  const step = picked ?? run?.steps.find((s) => s.status === 'failed' || s.status === 'cancelled')?.name
    ?? run?.steps.filter((s) => s.status !== 'pending' && s.status !== 'skipped').at(-1)?.name ?? null;
  const act = (p: Promise<unknown>) => p.then(reload, (e: Error) => setErr(e.message));
  return (
    <section>
      <h1><Link to="/ci">CI</Link> / {id}</h1>
      <ErrorText error={error ?? err} />
      {run && (
        <>
          <p><span className={`ci-${run.status}`}>{run.status}</span> · {run.repo} · {run.ref} · <code>{run.commit.slice(0, 12)}</code> · {run.pipeline ?? '…'}
            {run.image && <> · image <code>{run.image}</code></>} · {duration(run.started, run.finished)}</p>
          {run.secrets.length > 0 && <p className="hint">Secrets exposed: {run.secrets.join(', ')}{run.missing_secrets.length > 0 && ` (not set: ${run.missing_secrets.join(', ')})`}</p>}
          {run.error && <p className="error">{run.error}</p>}
          <div className="actions">
            <button onClick={() => act(api<{ run_id: string }>(`/api/ci/runs/${id}/rerun`, 'POST').then((r) => navigate(`/ci/${r.run_id}`)))}>Re-run</button>
            <button disabled={final} onClick={() => confirmAction(`Cancel run ${id}?`) && act(api(`/api/ci/runs/${id}/cancel`, 'POST'))}>Cancel</button>
          </div>
          <table><tbody>
            {run.steps.map((s) => (
              <tr key={s.name}>
                <td><button className={s.name === step ? 'active' : ''} onClick={() => setPicked(s.name)}>{s.name}</button></td>
                <td className={`ci-${s.status}`}>{s.status}{s.exit_code ? ` (exit ${s.exit_code})` : ''}</td>
                <td>{duration(s.started, s.finished)}</td>
              </tr>
            ))}
          </tbody></table>
          {step && <LogStream key={`${step}:${final}`} path={`/api/ci/runs/${encodeURIComponent(id)}/log?step=${encodeURIComponent(step)}`} />}
        </>
      )}
    </section>
  );
}
```

`web/ui/src/App.tsx` (whole file):
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
import { CI } from './pages/CI';

const NAV = [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/ci', 'CI'], ['/settings', 'Settings'], ['/system', 'System']];

function page(path: string, me: Me | null) {
  const [, section, arg] = path.split('/');
  switch (section) {
    case 'settings': return <Settings me={me} />;
    case 'sessions': return arg ? <Terminal id={decodeURIComponent(arg)} /> : <Sessions />;
    case 'desktops': return arg ? <DesktopView n={Number(arg)} /> : <Desktops />;
    case 'system': return <System me={me} />;
    case 'ci': return <CI id={arg ? decodeURIComponent(arg) : undefined} />;
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

`web/ui/src/pages/Overview.tsx` (whole file):
```tsx
import { api } from '../api';
import { ErrorText } from '../components/ErrorText';
import { duration, gib, pct } from '../format';
import { newDesktop, openTerminal } from '../quick';
import { navigate } from '../router';
import { Link } from '../router';
import type { CiRun, Desktop, Health, Session, Tailscale } from '../types';
import { usePoll } from '../usePoll';

export function Overview() {
  const health = usePoll(() => api<Health>('/api/system/health'), 5000);
  const sessions = usePoll(() => api<Session[]>('/api/sessions'), 5000);
  const desktops = usePoll(() => api<{ desktops: Desktop[] }>('/api/desktops'), 5000);
  const ts = usePoll(() => api<Tailscale>('/api/system/tailscale'), 30000);
  const ci = usePoll(() => api<CiRun[]>('/api/ci/runs?limit=1'), 10000);
  const last = ci.data?.[0];
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
          <div className="card"><h3>CI</h3>
            {last ? <><p className={`ci-${last.status}`}><Link to={`/ci/${last.id}`}>{last.status}</Link></p>
              <small>{last.repo.split('/').pop()} {last.ref} · {duration(last.started, last.finished)}</small></>
              : <p>{ci.data ? 'no runs' : '…'}</p>}
          </div>
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

`web/ui/src/pages/Settings.tsx` (whole file):
```tsx
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { SecretField } from '../components/SecretField';
import { type FieldSpec, SettingsForm } from '../components/SettingsForm';
import { SolentaCard } from '../components/SolentaCard';
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
const SOLENTA_CI: FieldSpec[] = [
  { key: 'AGENTOS_SOLENTA', label: 'Keep Solenta (Mode A) running on this box', type: 'bool' },
  { key: 'AGENTOS_CI_MAX_PARALLEL', label: 'CI runs at once (1-16, default 2)', type: 'number' },
];
const WEB: FieldSpec[] = [
  { key: 'AGENTOS_WEB_USERS', label: 'Allowed tailnet logins (comma-separated)', type: 'text' },
  { key: 'AGENTOS_WEB', label: 'Web UI enabled', type: 'bool' },
];

// AGENTOS_AUTO_REBOOT, AGENTOS_WEB and AGENTOS_SOLENTA default to on when unset: show unset as '1'.
const withDefaults = (v: Record<string, string>) => ({ ...v, AGENTOS_AUTO_REBOOT: v.AGENTOS_AUTO_REBOOT || '1', AGENTOS_WEB: v.AGENTOS_WEB || '1',
  AGENTOS_SOLENTA: v.AGENTOS_SOLENTA || '1' });

export function Settings({ me }: { me: Me | null }) {
  const settings = usePoll(() => api<SettingsData>('/api/settings'));
  const ts = usePoll(() => api<Tailscale>('/api/system/tailscale'));
  const save = async (values: Record<string, string>) => {
    if (values.AGENTOS_WEB_USERS !== undefined) values = { ...values, AGENTOS_WEB_USERS: values.AGENTOS_WEB_USERS.replace(/\s+/g, '') };
    // Reload on failure too: keys saved before the failing one were written and applied.
    try {
      await api('/api/settings', 'PUT', { values });
    } finally {
      settings.reload();
    }
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
          <SolentaCard />
          <SettingsForm title="Solenta and CI" fields={SOLENTA_CI} values={withDefaults(s.values)} onSave={save} />
          <SettingsForm title="Access and console" fields={ACCESS} values={withDefaults(s.values)} onSave={save} />
          <SettingsForm title="Desktops" fields={DESKTOPS} values={s.values} onSave={save} />
          <SettingsForm title="Web UI" fields={WEB} values={withDefaults(s.values)} onSave={save} beforeSave={webGuard} />
        </>
      )}
    </section>
  );
}
```

- [ ] **Step 5: Run the tests, typecheck, build**

Run: `cd web/server && npx tsc -p tsconfig.json --noEmit && npx vitest run`
Expected: `Tests  98 passed | 1 skipped (99)`.

Run: `cd web/ui && npx tsc -p tsconfig.json && npx vitest run && npm run build`
Expected: `Tests  18 passed (18)`, then `✓ built in …`.

- [ ] **Step 6: Commit**

```bash
git add web/server/src/actions.ts web/server/src/ci.ts web/server/src/app.ts web/server/src/system.ts web/server/src/settings.ts \
  web/server/test/ci.test.ts web/server/test/system.test.ts \
  web/ui/src/App.tsx web/ui/src/types.ts web/ui/src/format.ts web/ui/src/style.css web/ui/src/pages/CI.tsx web/ui/src/pages/Overview.tsx \
  web/ui/src/pages/Settings.tsx web/ui/src/components/Copy.tsx web/ui/src/components/SolentaCard.tsx \
  web/ui/test/CI.test.tsx web/ui/test/SolentaCard.test.tsx web/ui/test/Settings.test.tsx
git commit -m "feat(web): CI page with live step logs, Solenta card (Mode A first), latest CI run on Overview"
```

---

### Task 9: In-VM checks, CI workflow, docs, size

**Files:**
- Modify: `test/checks/97-solenta.sh` (append the Mode B checks), `test/web_ws.mjs`, `test/web_e2e.mjs`, `.github/workflows/build.yml`
- Create: `test/checks/98-ci.sh`, `test/ci_mcp_client.py`, `docs/solenta-and-ci.md`

**Interfaces:**
- Consumes: everything above. From `smoke.sh`: `vm`, `vml`, `$WORK/key`, `$PORT`, `$HERE`. From `96-web.sh`: `$WEB` (with `w`, `wm`, `code`, `up`) and `web_users`.
- Produces: `node web_ws.mjs cilog <run-id> <step> <expected>`.

- [ ] **Step 1: Write the checks**

Append to `test/checks/97-solenta.sh`:
```bash

# --- Mode B: CLIs and keys over non-login SSH, preflight, reverse forwards ---------------------
check_clis_over_plain_ssh() {
  # `vm 'cmd'` is exactly Solenta's case: sshd runs a non-login, non-interactive bash -c.
  vm 'claude --version && codex --version && opencode --version && grok --version' >/dev/null &&
  vm 'env -i HOME=/home/agent PATH=/usr/local/bin:/usr/bin:/bin bash -c "claude --version"' >/dev/null
}
check_cli_wrapper_passes_api_key() {
  # Guest-side proof the key is in secrets.env, then that a non-login shell's CLI sees it. A fake
  # `claude` in a scratch HOME stands in for the real one, which would not print its environment.
  vm 'grep -qx ANTHROPIC_API_KEY=sk-test-dummy ~/.config/agentos/secrets.env' &&
  test "$(vm 'h=$(mktemp -d) && mkdir -p $h/.local/bin $h/.config/agentos && cp ~/.config/agentos/secrets.env $h/.config/agentos/ &&
      printf "#!/bin/sh\necho key=\$ANTHROPIC_API_KEY\n" > $h/.local/bin/claude && chmod +x $h/.local/bin/claude &&
      env -i HOME=$h PATH=/usr/local/bin:/usr/bin:/bin bash -c claude; rm -rf $h')" = key=sk-test-dummy
}
check_solenta_preflight_passes() {
  vm 'rm -rf ~/work/pf && mkdir -p ~/work/pf && git -C ~/work/pf init -q &&
      out=$(/usr/local/lib/agentos/solenta-pair status -- ~/work/pf) &&
      echo "$out" | jq -e "[.preflight[].ok] | all and length == 9" >/dev/null &&
      echo "$out" | jq -e --arg fp "$(ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub | cut -d " " -f 2)" \
        "any(.hostKeys[]; .fingerprint == \$fp) and (.keyscan | startswith(\"ssh-keyscan -t ed25519 \"))" >/dev/null &&
      sudo agentos-config solenta ~/work/pf | grep -q "PASS  grok:"; rc=$?; rm -rf ~/work/pf; exit $rc'
}
check_reverse_forward_loopback_only() {
  # The bridge's ssh -R from the host: the forward binds only on the VM's loopback (even when it
  # asks for 0.0.0.0) and reaches the host's server.
  local hp=47321 rc=0 srv
  vm 'sudo sshd -T | grep -qx "allowtcpforwarding yes" && sudo sshd -T | grep -qx "gatewayports no"' || return 1
  mkdir -p "$WORK/fwd" && echo bridge-ok > "$WORK/fwd/index.html"
  python3 -m http.server "$hp" --bind 127.0.0.1 --directory "$WORK/fwd" >/dev/null 2>&1 & srv=$!
  ssh -i "$WORK/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
      -o ExitOnForwardFailure=yes -f -N -R "127.0.0.1:47123:127.0.0.1:$hp" -R "0.0.0.0:47124:127.0.0.1:$hp" agent@127.0.0.1 || rc=1
  vm 'for _ in $(seq 1 20); do curl -fsS -m 2 http://127.0.0.1:47123/ | grep -qx bridge-ok && break; sleep 0.5; done &&
      curl -fsS -m 2 http://127.0.0.1:47123/ | grep -qx bridge-ok &&
      test "$(ss -Htln "sport = :47123" | awk "{print \$4}" | sort -u | tr "\n" " ")" = "127.0.0.1:47123 " &&
      test -z "$(ss -Htln "sport = :47124" | awk "{print \$4}" | grep -vE "^(127\.0\.0\.1|\[::1\]):47124$")"' || rc=1
  pkill -f "47123:127.0.0.1:$hp" || true
  kill "$srv" 2>/dev/null || true
  return "$rc"
}
```

`test/checks/98-ci.sh`:
```bash
# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

# ci_repo NAME FILE CONTENT...: a committed repo at ~/ci-smoke/NAME (pairs of path and content).
CI_REPO='ci_repo() {
  local d=~/ci-smoke/$1; shift; rm -rf "$d"; mkdir -p "$d"
  while [ $# -gt 0 ]; do mkdir -p "$d/$(dirname "$1")"; printf "%s\n" "$2" > "$d/$1"; shift 2; done
  git -C "$d" init -q -b main && git -C "$d" add -A && git -C "$d" -c user.name=s -c user.email=s@x commit -qm init && echo "$d"
}
ci_final() {  # ci_final ID: wait for a final status and print it
  for _ in $(seq 1 600); do s=$(agentos-ci status "$1" --json | jq -r .status)
    case $s in passed|failed|cancelled|error) echo "$s"; return 0 ;; esac; sleep 1; done; return 1
}
'
check_ci_installed() {
  vm 'test "$(act --version)" = "act version 0.2.89" && /usr/local/lib/agentos/venv/bin/python -c "import yaml, mcp" &&
      grep -qE "^act 0\.2\.89 [0-9a-f]{64}$" /var/lib/agentos-manifest.txt && grep -qi "^pyyaml==6\." /var/lib/agentos-manifest.txt &&
      test "$(cat /etc/agentos/ci.conf)" = MAX_PARALLEL=2 && agentos-ci --help >/dev/null'
}
check_ci_registered_with_every_cli() {
  vml 'claude mcp get agentos-ci 2>&1 | grep -q /usr/local/bin/agentos-ci-mcp && codex mcp list 2>&1 | grep -q agentos-ci &&
       grok mcp list 2>&1 | grep -q agentos-ci' &&
  vm 'grep -A2 "^\[mcp_servers\.agentos-ci\]$" ~/.codex/config.toml | grep -qx "tool_timeout_sec = 1800" &&
      jq -e ".mcp[\"agentos-ci\"].command == [\"/usr/local/bin/agentos-ci-mcp\"]" ~/.config/opencode/opencode.json >/dev/null'
}
check_ci_skill_files_present() {
  vm 'for f in ~/.claude/skills/agentos-ci/SKILL.md ~/.grok/skills/agentos-ci/SKILL.md ~/.codex/AGENTS.md ~/.config/opencode/AGENTS.md; do
        test "$(grep -c "agentos-ci:begin" "$f")" = 1 && grep -q "ci_wait" "$f" || { echo "bad $f"; exit 1; }
      done && head -2 ~/.claude/skills/agentos-ci/SKILL.md | grep -qx "name: agentos-ci" &&
      sudo agentos-config apply && test "$(grep -c "agentos-ci:begin" ~/.codex/AGENTS.md)" = 1'
}
check_ci_push_pass_then_fail() {
  # remote create -> push a passing repo from the host -> passed; push a failing step -> failed,
  # with that step's log tail. The pusher sees the run id.
  local src=$WORK/ci-push id1 id2 rc=0
  local -a gitssh=(env "GIT_SSH_COMMAND=ssh -i $WORK/key -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR")
  vm 'rm -rf ~/git/smoke.git && agentos-ci remote create smoke' | grep -qx 'On your machine: git remote add agentos agent@agentos-test:git/smoke.git' || return 1
  rm -rf "$src" && mkdir -p "$src/.agentos" && printf 'steps:\n  - name: test\n    run: echo smoke-pass-marker\n' > "$src/.agentos/ci.yml" &&
  git -C "$src" init -q -b main && git -C "$src" add -A && git -C "$src" -c user.name=s -c user.email=s@x commit -qm pass &&
  git -C "$src" remote add agentos agent@127.0.0.1:git/smoke.git || return 1
  id1=$("${gitssh[@]}" git -C "$src" push agentos main 2>&1 | sed -n 's/^remote: agentos-ci: run \([0-9a-f-]*\) for main.*/\1/p')
  [ -n "$id1" ] || return 1
  vm "$CI_REPO"'test "$(ci_final '"$id1"')" = passed && agentos-ci logs '"$id1"' | grep -qx smoke-pass-marker' || rc=1
  printf 'steps:\n  - name: test\n    run: echo smoke-failure-marker; exit 3\n  - name: after\n    run: "true"\n' > "$src/.agentos/ci.yml"
  git -C "$src" -c user.name=s -c user.email=s@x commit -qam fail || rc=1
  id2=$("${gitssh[@]}" git -C "$src" push agentos main 2>&1 | sed -n 's/^remote: agentos-ci: run \([0-9a-f-]*\) for main.*/\1/p')
  [ -n "$id2" ] && vm "$CI_REPO"'test "$(ci_final '"$id2"')" = failed &&
    agentos-ci status '"$id2"' --json | jq -e "[.steps[] | .status] == [\"failed\", \"skipped\"] and .steps[0].exit_code == 3 and .source == \"push\"" >/dev/null &&
    agentos-ci logs '"$id2"' | grep -qx smoke-failure-marker' || rc=1
  return "$rc"
}
check_ci_clean_env_and_secrets() {
  # secrets.env holds ANTHROPIC_API_KEY (smoke user-data): only a repo that lists it sees it.
  vm 'grep -q "^ANTHROPIC_API_KEY=" ~/.config/agentos/secrets.env' &&
  vm "$CI_REPO"'
    a=$(ci_repo env-plain .agentos/ci.yml "steps: [{name: env, run: env}]") &&
    b=$(ci_repo env-secret .agentos/ci.yml "secrets: [ANTHROPIC_API_KEY]
steps: [{name: env, run: test \"\$ANTHROPIC_API_KEY\" = sk-test-dummy}]") &&
    i=$(agentos-ci run "$a") && test "$(ci_final "$i")" = passed &&
    agentos-ci logs "$i" | grep -qx CI=true && agentos-ci logs "$i" | grep -qx "AGENTOS_CI_RUN=$i" &&
    ! agentos-ci logs "$i" | grep -q ANTHROPIC_API_KEY &&
    j=$(agentos-ci run "$b") && test "$(ci_final "$j")" = passed &&
    agentos-ci status "$j" --json | jq -e ".secrets == [\"ANTHROPIC_API_KEY\"]" >/dev/null &&
    ! grep -rq sk-test-dummy ~/.local/share/agentos-ci/runs/"$j"/run.json'
}
check_ci_cancel_kills_steps() {
  vm "$CI_REPO"'
    d=$(ci_repo cancel .agentos/ci.yml "steps: [{name: s, run: sleep 31337 & sleep 31338}]") &&
    i=$(agentos-ci run "$d") &&
    for _ in $(seq 1 30); do pgrep -f "sleep 3133[78]" >/dev/null && break; sleep 0.5; done && pgrep -f "sleep 31337" >/dev/null &&
    test "$(agentos-ci cancel "$i" --json | jq -r .status)" = cancelled && sleep 1 &&
    ! pgrep -f "sleep 3133[78]" >/dev/null'
}
check_ci_autodetect_npm() {
  vm "$CI_REPO"'
    d=$(ci_repo npm package.json "{\"name\":\"s\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"node -e \\\"console.log(42*2)\\\"\"}}" \
                    package-lock.json "{\"name\":\"s\",\"version\":\"1.0.0\",\"lockfileVersion\":3,\"requires\":true,\"packages\":{\"\":{\"name\":\"s\",\"version\":\"1.0.0\"}}}") &&
    i=$(agentos-ci run "$d") && test "$(ci_final "$i")" = passed &&
    agentos-ci status "$i" --json | jq -e ".pipeline == \"auto\" and .steps[0].name == \"npm-test\"" >/dev/null &&
    agentos-ci logs "$i" | grep -qx 84'
}
check_ci_act_runs_a_workflow() {
  # act pulls catthehacker/ubuntu:act-24.04 (~570 MB) on first use: needs the network.
  vm 'curl -s -o /dev/null -m 10 https://registry-1.docker.io/v2/' || { echo "SKIP: no network to Docker Hub"; return 0; }
  vm "$CI_REPO"'
    d=$(ci_repo act .github/workflows/t.yml "on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: echo act-smoke-\$((6*7))") &&
    i=$(agentos-ci run "$d") && test "$(ci_final "$i")" = passed &&
    agentos-ci status "$i" --json | jq -e ".pipeline == \"act\"" >/dev/null && agentos-ci logs "$i" | grep -q act-smoke-42'
}
check_ci_mcp_run_and_wait() {
  vm 'cat > /tmp/ci_mcp_client.py' < "$HERE/ci_mcp_client.py" &&
  vm "$CI_REPO"'
    g=$(ci_repo mcp-good .agentos/ci.yml "steps: [{name: test, run: \"true\"}]") &&
    b=$(ci_repo mcp-bad .agentos/ci.yml "steps: [{name: test, run: echo smoke-failure-marker; exit 1}]") &&
    /usr/local/lib/agentos/venv/bin/python /tmp/ci_mcp_client.py "$g" "$b"'
}
check_ci_web_api_lists_and_streams() {
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" && vm "$WEB$CI_REPO"'
    d=$(ci_repo web .agentos/ci.yml "steps: [{name: hello, run: echo web-ci-\$((40+2))}]") &&
    i=$(wm -X POST -d "{\"path\":\"$d\"}" $U/api/ci/runs | jq -r .run_id) && test -n "$i" &&
    node /tmp/web_ws.mjs cilog "$i" hello web-ci-42 &&
    test "$(ci_final "$i")" = passed &&
    w "$U/api/ci/runs?limit=5" | jq -e --arg i "$i" "any(.[]; .id == \$i and .status == \"passed\")" >/dev/null &&
    w "$U/api/ci/remotes" | jq -e "type == \"array\"" >/dev/null &&
    test "$(code -X POST -H "Tailscale-User-Login: smoke@example.com" "$U/api/ci/runs/$i/cancel")" = 403 &&
    for _ in 1 2 3 4 5; do
      sudo journalctl -b -t agentos-web -p notice --no-pager -o cat | grep -qx "smoke@example.com ci-run $d" && exit 0; sleep 1
    done; exit 1'
}
```

`test/ci_mcp_client.py`:
```python
#!/usr/bin/env python3
"""In-VM end-to-end test of the agentos-ci MCP server over stdio, as an agent CLI would use it.

  ci_mcp_client.py <passing-repo> <failing-repo>
Run with the AgentOS venv's python (it has the mcp package).
"""
import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

TOOLS = {"ci_run", "ci_wait", "ci_status", "ci_logs", "ci_list", "ci_cancel"}


def fail(msg):
    sys.exit(f"CI MCP FAIL: {msg}")


async def call(s, name, **args):
    r = await s.call_tool(name, args)
    if r.isError:
        fail(f"{name}({args}): {r.content}")
    return json.loads(r.content[0].text)


async def main(good, bad):
    async with stdio_client(StdioServerParameters(command="/usr/local/bin/agentos-ci-mcp")) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = {t.name for t in (await s.list_tools()).tools}
            if tools != TOOLS:
                fail(f"tools {sorted(tools)}")
            ok = await call(s, "ci_wait", run_id=(await call(s, "ci_run", path=good))["run_id"], timeout_s=300)
            if ok["status"] != "passed":
                fail(f"good repo: {ok}")
            res = await call(s, "ci_wait", run_id=(await call(s, "ci_run", path=bad))["run_id"], timeout_s=300)
            if res["status"] != "failed" or res["failed_step"] != "test" or "smoke-failure-marker" not in res["log_tail"]:
                fail(f"bad repo: {res}")
            if not (await s.call_tool("ci_run", {"path": "/etc"})).isError:
                fail("ci_run accepted a path outside /home/agent")
    print("CI MCP OK")


asyncio.run(main(sys.argv[1], sys.argv[2]))
```

In `test/web_ws.mjs`, find:
```js
//   node web_ws.mjs vnc <desktop-number>        (expects the VNC server's "RFB 003.008" banner)
```
Replace with:
```js
//   node web_ws.mjs vnc <desktop-number>        (expects the VNC server's "RFB 003.008" banner)
//   node web_ws.mjs cilog <run-id> <step> <expected-output>
```
Then find:
```js
const path = mode === 'term' ? `/api/sessions/${target}/terminal?cols=80&rows=24` : `/api/desktops/${target}/vnc`;
const want = mode === 'term' ? expected : 'RFB 003.008';
```
Replace with:
```js
const path = mode === 'term' ? `/api/sessions/${target}/terminal?cols=80&rows=24`
  : mode === 'cilog' ? `/api/ci/runs/${target}/log?step=${encodeURIComponent(typed)}` : `/api/desktops/${target}/vnc`;
const want = mode === 'vnc' ? 'RFB 003.008' : expected;
```

In `test/web_e2e.mjs`, find:
```js
for (const [path, heading] of [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/settings', 'Settings'], ['/system', 'System']]) {
```
Replace with:
```js
for (const [path, heading] of [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/ci', 'CI'], ['/settings', 'Settings'], ['/system', 'System']]) {
```
Then find:
```js
await page.goto(BASE + '/sessions');
await page.getByLabel('CLI').selectOption('shell');
```
Replace with:
```js
await page.goto(BASE + '/settings');
await page.getByRole('heading', { level: 2, name: 'Solenta' }).waitFor({ timeout: 15000 }).catch(() => fail('no Solenta card'));
await page.getByText('Mode A: Solenta on this box (recommended)').waitFor({ timeout: 15000 }).catch(() => fail('Solenta card has no Mode A'));
await page.goto(BASE + '/sessions');
await page.getByLabel('CLI').selectOption('shell');
```

- [ ] **Step 2: Lint the checks**

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning test/smoke.sh test/checks/*.sh && echo SC-OK'`
Expected: `SC-OK`.

- [ ] **Step 3: CI workflow**

In `.github/workflows/build.yml`, find:
```yaml
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils mtools pipx shellcheck zstd tmux
```
Replace with:
```yaml
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils mtools pipx shellcheck zstd tmux jq
```
Find:
```yaml
            mkosi.extra/usr/local/lib/agentos/web-serve test/web_serve_test.sh \
```
Replace with:
```yaml
            mkosi.extra/usr/local/lib/agentos/web-serve test/web_serve_test.sh \
            mkosi.extra/usr/local/lib/agentos/{cli-wrapper,register-mcp,solenta-pair,solenta-start} \
            mkosi.extra/usr/local/lib/agentos/ci/post-receive tools/solenta-bridge \
            test/wrapper_test.sh test/solenta_pair_test.sh test/bridge_test.sh \
```
Find:
```yaml
          test/web_serve_test.sh

```
Replace with:
```yaml
          test/web_serve_test.sh
          test/wrapper_test.sh
          test/solenta_pair_test.sh
          test/bridge_test.sh

      - name: agentos-ci unit tests
        run: |
          python3 -m venv "$RUNNER_TEMP/ci-venv"
          "$RUNNER_TEMP/ci-venv/bin/pip" install -q pytest 'pyyaml>=6,<7' 'mcp>=1.28,<2'
          "$RUNNER_TEMP/ci-venv/bin/python" -m pytest -q test/ci

```
The smoke step needs no change: `smoke.sh` picks up every `check_*` in `test/checks/`.

- [ ] **Step 4: Docs**

`docs/solenta-and-ci.md` (Mode A first, as the spec requires; it carries the Tailscale `-R` finding and the bridge security note):
````markdown
# Solenta and built-in CI on AgentOS

## Solenta

AgentOS works with an unmodified Solenta.app 0.26 in two modes. Use Mode A unless you have a reason not to.

### Mode A: Solenta on the box (recommended)

Solenta's own *Remote Connections* installs Solenta's Linux build on the box over SSH, runs it headless, and opens it on your Mac through an SSH tunnel. The agents, their CLIs, and Solenta's `coder-threads` and `coder-memory` all run on the box.

1. **SSH access.** Add your Mac's public key (`sudo agentos-config add-ssh-key "ssh-ed25519 AAAA… you@mac"`, or the web UI's SSH keys panel), or use Tailscale SSH, where your tailnet policy decides.
2. **Host key.** Solenta refuses a host that isn't in the Mac's `~/.ssh/known_hosts`. The Solenta card in the web UI (or `sudo agentos-config solenta`) shows the box's host key fingerprints and an `ssh-keyscan` line. Compare the fingerprints with what `ssh agent@<box>` shows on the Mac, then run the line on the Mac.
3. **Connect.** In Solenta, open Settings, Connections, Remote Connections, and add `agent@<box>`. Solenta installs itself into `~/solenta` on the box.

The box does the rest:
- The Electron runtime libraries Solenta's `ldd` check needs are in the image.
- `agentos-solenta.path` notices the install (and every upgrade) and starts `agentos-solenta.service`. The service runs `~/solenta/solenta --headless --serve-web=4620 --no-sandbox` as `agent`, keeps it running after your SSH session ends, and restarts it after Solenta's upgrade stops the old build.
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

**Secrets.** Steps get a clean environment: `PATH`, `HOME`, `LANG`, `CI=true` and `AGENTOS_CI_RUN`. API keys from `secrets.env` reach a step only if the repository lists their names under `secrets:`. The run records the names, never the values. CI runs repository code as `agent`, the same trust as an agent running it. `image:` and `act` use Docker, and the `docker` group was already root-equivalent on this box.

**Agents.** Every agent CLI gets the `agentos-ci` MCP server and a short skill: before declaring work in a repository done, commit, run CI, wait for it, fix real failures, and never weaken tests to get a pass.
````

- [ ] **Step 5: Build, run every check, and measure the size**

Size estimate: `act` 20.1 MiB, PyYAML about 2 MiB in the venv, the `ci` package and scripts under 0.2 MiB, and the Electron libraries 0 MiB (already present). The total is about **+23 MiB**: from the last measured 6247 MiB to about 6270 MiB of 7168. Runner images, Solenta itself and CI state land in `/var/lib/docker` and `/home/agent` after install, not in the image.

Run: `.superpowers/sdd/devvm.sh run 'mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed'`, then `.superpowers/sdd/devvm.sh wait <JOB>` until it isn't 124. It is about 10 minutes longer than before; `check_ci_act_runs_a_workflow` pulls about 570 MB the first time in each mode.
Expected: every earlier check still passes, and the new ones pass in `uefi` and `bios`:
```
PASS [uefi] check_ci_act_runs_a_workflow
PASS [uefi] check_ci_autodetect_npm
PASS [uefi] check_ci_cancel_kills_steps
PASS [uefi] check_ci_clean_env_and_secrets
PASS [uefi] check_ci_installed
PASS [uefi] check_ci_mcp_run_and_wait
PASS [uefi] check_ci_push_pass_then_fail
PASS [uefi] check_ci_registered_with_every_cli
PASS [uefi] check_ci_skill_files_present
PASS [uefi] check_ci_web_api_lists_and_streams
PASS [uefi] check_cli_wrapper_passes_api_key
PASS [uefi] check_clis_over_plain_ssh
PASS [uefi] check_reverse_forward_loopback_only
PASS [uefi] check_solenta_preflight_passes
… (the seven Mode A checks from Task 2)
PASS [uefi] check_web_e2e
root used: NNNN MiB (budget 7168)      ← from check_root_size_budget: record NNNN; expect about 6270
ALL CHECKS PASSED (N skipped)
```
Record the measured root size in the commit message. If it exceeds 6300 MiB, find the cause with `du -sm /usr/local/bin/act /usr/local/lib/agentos/venv` in the VM before going on.

- [ ] **Step 6: Manual checks (from the spec's testing section; not automatable)**

1. **Mode A:**
   - On the Mac, follow `docs/solenta-and-ci.md` Mode A: compare fingerprints, run the keyscan line, then Solenta 0.26 → Remote Connections → add `agent@<box>`.
   - Expect Solenta to install, show no `sudo apt install` hint (libraries present), and open.
   - Run a thread there. On the box, `systemctl status agentos-solenta` is active.
   - Close the SSH session; Solenta keeps working on the next connect.
2. **Mode B:**
   - Set a project's `remoteHost` and `remotePath` from the card, and check that the preflight is all PASS.
   - `bash solenta-bridge install agent@<box>`, then run a thread on the box, and confirm that `coder-threads` and `coder-memory` tool calls work.
   - Over Tailscale SSH, if the bridge log shows `remote port forwarding failed`, the tailnet policy doesn't grant remote forwarding. Use the LAN fallback from the docs and note the result in the PR.

- [ ] **Step 7: Commit**

```bash
git add test/checks/97-solenta.sh test/checks/98-ci.sh test/ci_mcp_client.py test/web_ws.mjs test/web_e2e.mjs \
  .github/workflows/build.yml docs/solenta-and-ci.md
git commit -m "test: Solenta Mode A/B and CI checks in the VM; CI runs the new unit tests; docs (root NNNN MiB)"
```

---

## Spec coverage

| Spec item | Task (test) |
|---|---|
| Mode A runtime libraries, `ldd` passes; trixie `t64` names verified | 2 (`check_solenta_libs_installed`, `check_solenta_real_tarball`) |
| `agentos-solenta.service` as `agent`, condition on either install path, start command with PATH, `KillMode=process`, restart after `pkill` | 2 (`check_solenta_units_idle_without_install`, `check_solenta_stub_survives_logout_and_pkill`); adjustment 1 |
| `.path` unit starts it on install; Solenta's own start finds it up; upgrade brings up the new binary | 2 (`check_solenta_upgrade_rename_restarts`, `check_solenta_skips_when_port_taken`); adjustments 2–3 |
| Survives SSH logout | 2 (`check_solenta_stub_survives_logout_and_pkill`) |
| `AGENTOS_SOLENTA` (default 1, via `agentos-config`) | 2 (`env_test.sh`, `check_solenta_setting_off_and_on`), 8 (Settings form) |
| Host key fingerprints + `ssh-keyscan` line | 3 (`solenta_pair_test.sh`, `check_solenta_preflight_passes`), 8 (card) |
| Port 4620 loopback only, no firewall change | 2 (stub binds 127.0.0.1; no firewall edits) |
| Card: service status, version, web-token existence, never the token | 3 (`solenta_pair_test.sh` asserts the token is absent), 8 (`SolentaCard.test.tsx`) |
| 1A wrappers: keys from the shared parser, real binary via profile.d dirs, no self-loop, 127 message, other users | 1 (`wrapper_test.sh`), 9 (`check_clis_over_plain_ssh`, `check_cli_wrapper_passes_api_key`) |
| `load-secrets.sh` shared with profile.d | 1 (`wrapper_test.sh` profile.d section, `env_test.sh`) |
| 1B pairing: SSH access (key or Tailscale SSH), repo clone (sessions code, allowlist, `--`) or pick a dir, values with copy buttons, preflight per item | 3 (`solenta.test.ts`, `solenta_pair_test.sh`), 8 (`SolentaCard.test.tsx`), 9 (`check_solenta_preflight_passes`) |
| No new state | 3 (only `authorized_keys` via existing endpoints, and the checkout) |
| 1C bridge: ports only, `ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -R …`, re-read and backoff, launchd install/uninstall, conf file | 4 (`bridge_test.sh`: parsing, trace has no token, argv, retry, plist) |
| Box: remote forwarding allowed, loopback-only binds | 9 (`check_reverse_forward_loopback_only`: `sshd -T`, 127.0.0.1 and 0.0.0.0 requests) |
| Tailscale SSH `-R` verified and documented | fact table, adjustment 10, 9 (docs) |
| Security note in docs and card | 8 (card text), 9 (docs) |
| 2A engine in the venv, `/usr/local/bin/agentos-ci`, CLI with `--json` | 5 (`test_cli.py`), 9 (`check_ci_installed`) |
| Pipeline selection order; `ci.yml` parsing and validation; auto-detect table; "no CI configuration found" + hint | 5 (`test_pipeline.py`, `test_no_config_is_an_error_with_a_hint`) |
| `act` with `push`/`workflow_dispatch`, pinned + checksum, pinned runner mapping | 5 (`test_selection_order…`, `test_workflow_events…`), 6 (install), 9 (`check_ci_act_runs_a_workflow`) |
| Fresh checkout of the exact commit, removed afterwards; `bash -eo pipefail`; as agent | 5 (`test_passing_run_states_and_logs`, `test_pipefail_and_exact_commit`, `test_bare_repo`) |
| Clean env, secrets only when listed, names (never values) in metadata | 5 (`test_clean_env_and_secrets_only_when_listed`), 9 (`check_ci_clean_env_and_secrets`) |
| `image:` via `docker run --rm -v …:/w -w /w` | 5 (`runs.command`); container cleanup (adjustment 14) |
| Run timeout kills the step's group | 5 (`test_timeout_kills_the_step`) |
| State: `run.json` + `<step>.log`; monotonic ids; retention 200; max parallel with flock; statuses | 5 (`test_ids_…`, `test_retention_…`, `test_queue_respects_max_parallel`, state assertions throughout) |
| Cancel: SIGTERM to the group, SIGKILL after 10 s | 5 (`test_cancel_kills_the_process_group`, `test_cancel_escalates_to_sigkill`, `test_cancel_a_queued_run`), 9 (`check_ci_cancel_kills_steps`) |
| Name and path validation | 5 (`test_paths_must_be_repos_inside_home`), 6 (`test_remote_names`), 8 (`ci.test.ts` argv rejections) |
| 2B `remote create/list`, bare repo + hook, run per branch, id printed to the pusher, `git remote add` line | 6 (`test_create_and_list`, `test_hook_runs_ci_per_branch_and_reports_the_id`), 9 (`check_ci_push_pass_then_fail`) |
| Hook can't be hijacked by ref names; argv only | 6 (`test_hook_never_evaluates_ref_names`) |
| 2C MCP tools, path inside `/home/agent`, `ci_wait` tail of the failing step, registered in all four CLIs | 7 (`test_mcp_tools`), 9 (`check_ci_mcp_run_and_wait`, `check_ci_registered_with_every_cli`) |
| 2D skill: one source, four locations, idempotent, never overwrites user edits, marked block | 7 (`test_skill_install_is_idempotent_and_keeps_user_content`), 9 (`check_ci_skill_files_present`) |
| 2E CI page: list, detail, live log per step with backpressure, Re-run, Cancel, Run CI with DirPicker, remotes; Overview latest run | 8 (`CI.test.tsx`, `ci.test.ts`, backpressure test), 9 (`check_ci_web_api_lists_and_streams`, `check_web_e2e`) |
| Auth, CSRF, audit; as agent, no sudo | 8 (`ci.test.ts`: CSRF 403, audits, argv without sudo), 9 (journal audit line) |
| Security: `docker` group unchanged; pushes use the existing SSH rules | no new groups or sshd changes (Tasks 2–9) |
| Unit (bash): wrapper resolution, bridge port parsing (tokens never read or printed) | 1, 4 |
| In-VM list (Mode A ×4, CLIs + key over non-login, preflight, `ssh -R`, push pass/fail, act, npm auto-detect, MCP e2e, skill files, web CI API) | 2, 9 |
| Manual: real Solenta Mode A and Mode B | 9 Step 6 |
| Size budget | 9 Step 5 (`check_root_size_budget`, estimate +23 MiB) |

## Self-review

- **Spec coverage:** every row above maps to a task and a test. The deviations are listed under "Spec adjustments", each with its evidence.
- **Placeholders:** none in code. Every new file is complete; every edit to an existing file gives the exact text to find and its replacement, or the whole file. Run counts and command outputs are the ones observed while the plan was written. The only value left open is the measured root size (`NNNN`), which Task 9 records.
- **Names and types across tasks:**
  - `load-secrets.sh` gives `AGENTOS_USER_DIRS` and the `AGENTOS_CI_RUN` skip (Task 1). Task 5's `step_env` sets `AGENTOS_CI_RUN`.
  - `cli-wrapper`'s `AGENTOS_WHICH` (Task 1) is used by `solenta-pair` (Task 3).
  - `solenta-pair`'s JSON keys (Task 3) match `SolentaStatus` in `types.ts` and the card (Task 8).
  - `cloneRepo(deps, repo, name, login)` (Task 3) is used by `createSession` and `/api/solenta/clone`.
  - `Deps.bridgePath` (Task 4) is set in `defaultDeps` and `fakeDeps`.
  - `runs.*` (Task 5) is consumed unchanged by `remotes.py` (Task 6), `mcp_server.py` and `skill.py` (Task 7).
  - `cli.py` grows by whole-file replacement in Tasks 6 and 7; each version was tested on its own (47, 59 and 61 tests).
  - The `agentos-ci --json` shapes (`{run_id}`, `run.json`, `[run.json]`, `{name, path, remote_add}`) match `ci.ts`, `CiRun` and `CiRemote`, and the 98 checks' `jq` paths.
  - `ID_RE`/`CI_ID_RE`, `REF_RE`/`GIT_REF_RE` and `STEP_RE` are identical in Python and TypeScript.
- **Ordering:** each task's tests pass with only the earlier tasks applied. The staged server states were compiled and tested (90+1 after Task 3, 91+1 after Task 4, 98+1 after Task 8), and so were the Python stages.
