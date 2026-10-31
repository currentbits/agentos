# AgentOS

A minimal, headless Linux machine for AI coding agents.

AgentOS is a Debian 13 (trixie) image with everything needed to run **Claude Code, Codex, opencode and Grok** on a server, VM or spare PC. It also gives those agents real desktops for computer use, a web UI to drive the machine from your browser, built-in CI, Solenta support, and signed one-click updates.

```
your laptop ── Tailscale ──▶ AgentOS box
                              ├─ agents: claude · codex · opencode · grok   (tmux sessions)
                              ├─ desktops: XFCE on demand, driven by the agentos-computer MCP server
                              ├─ web UI: sessions, terminals, desktops, CI, settings, updates
                              ├─ agentos-ci: local CI, push-to-run, MCP tools for agents
                              └─ Solenta: headless on the box, or the box as a worker for your Mac
```

**Download:** [installer `.iso`](https://dl.currentbits.net/agentos/index.html) (one file: USB stick, virtual CD or VM) · [all formats on the latest release](https://github.com/currentbits/agentos/releases/latest)

---

## Contents

- [What's inside](#whats-inside)
- [Requirements](#requirements)
- [Install](#install)
- [First boot and configuration](#first-boot-and-configuration)
- [Reaching the box](#reaching-the-box)
- [The web UI](#the-web-ui)
- [Agents](#agents)
- [Desktops for computer use](#desktops-for-computer-use)
- [Built-in CI](#built-in-ci)
- [Solenta](#solenta)
- [Updates](#updates)
- [Security model](#security-model)
- [Settings reference](#settings-reference)
- [Building from source](#building-from-source)
- [Repository layout](#repository-layout)
- [Releasing (maintainers)](#releasing-maintainers)
- [More documentation](#more-documentation)

---

## What's inside

| Area | What you get |
|---|---|
| **Agent CLIs** | Claude Code, Codex, opencode and Grok. Each is installed into the `agent` user's home by its official installer, so its own self-update works without root. |
| **Toolchains** | Node 24, Python 3.13, Rust (rustup, clippy, rustfmt), Go, Bun, build-essential, Docker, and Playwright with Chromium. |
| **Desktops** | On-demand XFCE desktops (Xvnc). Agents drive them through the `agentos-computer` MCP server (screenshot, click, type, key, scroll, drag, …), and you can watch them in the browser via noVNC. Idle desktops are reaped automatically. |
| **Web UI** | Behind `tailscale serve` (HTTPS on your tailnet), with a Tailscale identity allowlist. Agent sessions in tmux, terminals, desktops, CI runs with live logs, settings and secrets, system status and logs, power, and updates. |
| **Built-in CI** | `agentos-ci` runs `.agentos/ci.yml`, your GitHub workflows (through `act`) or an auto-detected test suite. You can trigger it from the CLI, the web UI, the agents' MCP tools, or a `git push` to the box. |
| **Solenta** | Mode A runs Solenta 0.27 or later headless on the box, installed by Solenta's own Remote Connections. Mode B uses the box as an SSH worker host for Solenta on your Mac. |
| **Updates** | AgentOS ships as a signed `agentos` .deb from its own apt repo. The box checks daily and shows when a release is available. You click Update, or run `agentos-update`. Rollback is supported. |
| **Install media** | VM images (raw, qcow2, vhdx, vmdk) and a USB / virtual-CD installer with Secure Boot, which supports interactive or unattended installs. |
| **Network** | An nftables firewall, with SSH reachable only over Tailscale by default. Tailscale SSH is supported. There's no password SSH. |

## Requirements

- **x86-64 (amd64)**, booted in **UEFI** mode. Secure Boot works. BIOS/CSM boots, but UEFI is the supported path.
- **Disk:** at least 32 GB (the installer refuses smaller disks). The root filesystem uses about 6.3 GB, and grows to fill the disk on first boot.
- **RAM:** 4 GB minimum. 8 GB or more is comfortable with desktops: each desktop plus Chromium uses about 300–500 MB, and you can run up to `AGENTOS_MAX_DESKTOPS` of them (default 8).
- **A Tailscale account.** This is strongly recommended, and it's how you reach the web UI.
- **Credentials** for the agents you want to use: a subscription login (Claude Pro/Max, ChatGPT, xAI) or API keys.

## Install

Download the files from the [latest release](https://github.com/currentbits/agentos/releases/latest). Large files are split into parts under 1900 MiB because of GitHub's release-asset size limit. Reassemble and verify them:

```bash
cat agentos-1.0.0.qcow2.part* > agentos-1.0.0.qcow2
sha256sum -c --ignore-missing SHA256SUMS
```

| File | Use it for |
|---|---|
| [`agentos-installer-<v>.iso`](https://dl.currentbits.net/agentos/index.html) | **Bare metal, the simplest way.** The installer as one direct download from `dl.currentbits.net`: no parts, nothing to decompress. Write it to a USB stick (`dd`, Etcher), attach it as a virtual CD (iDRAC/iLO/IPMI virtual media), or as the CD/DVD of a Proxmox, VMware or Hyper-V VM, then boot in UEFI mode. Latest release only; its SHA-256 is published next to it (`.sha256`), and is in the release's `SHA256SUMS` from 1.0.2 on. |
| `agentos-installer-<v>.img.zst` | **Bare metal.** Decompress it (`zstd -d`), write it to a USB stick (`dd`, Etcher, or Rufus in DD mode) or attach it as a virtual CD (iDRAC/iLO/IPMI virtual media, Hyper-V DVD), then boot in UEFI mode. |
| `agentos-<v>.qcow2` | KVM / QEMU / Proxmox / libvirt. |
| `agentos-<v>.vhdx.zst` | Hyper-V. |
| `agentos-<v>.vmdk.zst` | VMware. |
| `agentos-<v>.raw.zst` | Anything that takes a raw disk image, or `dd` to a disk. |

### Bare metal with the installer

- **Interactive:** boot the stick and follow the on-screen menu.
- **Unattended:**
  1. Copy `agentos.env.example` to `agentos.env` on the stick's data partition.
  2. Set `AGENTOS_INSTALL_DISK` (for example `/dev/disk/by-id/nvme-…`) and anything else you need.
  3. Boot. The installer **erases that disk without asking**, applies your settings, then deletes `agentos.env` from the stick, since it may contain secrets.

> [!WARNING]
> BMC virtual media (iDRAC, iLO, IPMI) often stays attached across power cycles. Detach the virtual CD after an unattended install, or the next boot erases the disk and installs again. A CD is read-only, so the installer can't delete `agentos.env` from it. It powers off after installing instead, and you must delete the image's copy yourself.

CD boot is tested in QEMU/OVMF, including with Secure Boot, but not yet on real iDRAC or iLO hardware.

### VM images with cloud-init

The VM images run cloud-init on first boot. Write your settings to `/etc/agentos/agentos.env` with `write_files`:

```yaml
#cloud-config
write_files:
  - path: /etc/agentos/agentos.env
    permissions: "0600"
    content: |
      AGENTOS_HOSTNAME=agentos-01
      AGENTOS_SSH_KEY=ssh-ed25519 AAAA... you@laptop
      TS_AUTHKEY=tskey-auth-...
      AGENTOS_WEB_USERS=you@example.com
      ANTHROPIC_API_KEY=sk-ant-...
```

Without a cloud-init seed the image still boots: configure it from the console with `sudo agentos-config`.

## First boot and configuration

All settings live in **`/etc/agentos/agentos.env`** as `KEY=VALUE` lines. Every key is optional. The installer, cloud-init, the web UI, or `agentos-config` writes them, and `agentos-firstboot` applies them on every boot until it succeeds.

On first boot, AgentOS:
- sets the hostname;
- joins Tailscale with `TS_AUTHKEY` (then deletes the key from the file);
- moves API keys into the `agent` user's `~/.config/agentos/secrets.env` (mode 0600);
- registers the MCP servers and the CI skill with every agent CLI;
- publishes the web UI.

To change settings later, from the console or over SSH:

```bash
sudo agentos-config                    # full-screen menu
sudo agentos-config set KEY VALUE      # scriptable
sudo agentos-config get KEY
sudo agentos-config apply              # apply changes (re-runs firstboot)
sudo agentos-config add-ssh-key 'ssh-ed25519 AAAA… you@laptop'
sudo agentos-config github-keys <github-user>   # import your GitHub SSH keys
sudo agentos-config password           # console/sudo password for 'agent'
sudo agentos-config solenta            # Solenta pairing info
sudo agentos-config show-web-fingerprint   # the LAN certificate's SHA-256 (AGENTOS_WEB_LAN=1)
```

The **local console** shows a status screen with the hostname, the Tailscale address, the web UI URL, update notices and a login prompt. Set `AGENTOS_CONSOLE=terminal` to get a full-screen terminal after login instead.

## Reaching the box

**Use Tailscale. It's the intended way in.** Generate a **single-use, pre-approved auth key tagged `tag:agentos`**, set it as `TS_AUTHKEY`, and add this to your tailnet policy:

```json
{
  "tagOwners": { "tag:agentos": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos:22,443,6080,8765"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos"], "users": ["agent"] }
  ]
}
```

The box can't initiate connections to your other tailnet devices, so a hijacked agent can't reach them. Enable **HTTPS certificates** for your tailnet (admin console → DNS → HTTPS Certificates); the web UI needs them. See [docs/tailscale-acl.md](docs/tailscale-acl.md).

- **SSH:** `ssh agent@<box>` over Tailscale, with Tailscale SSH or your key. Password SSH is off. Set `AGENTOS_LAN_SSH=1` to also accept key-only SSH on the LAN.
- **User:** everything runs as **`agent`**, which has passwordless sudo and is in the `docker` group.

### Without Tailscale: the web UI on your local network

On a trusted home or lab network you can also open the web UI at **`https://<the box's LAN address>`**, logging in with the password of `agent`. It is off by default. Turn it on in the installer, in the web UI's Settings page, in `sudo agentos-config` ("Web UI on the local network"), or with:

```bash
sudo agentos-config password                    # if agent has no password yet
sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply
```

The box makes its own certificate, so your browser warns about it the first time. Continue only if the certificate's SHA-256 fingerprint matches the one on the box's console, in `sudo agentos-config show-web-fingerprint`, or on the web UI's System page. The certificate lasts 825 days, and the box makes a new one (with a new fingerprint) a month before it expires, or after you delete `/etc/agentos/web-lan/`.

- `https://<hostname>` and `https://<hostname>.local` work too, where your network resolves those names. Plain `http://` (port 80) only redirects to the `https://` address.
- A session ends after 12 hours without use, after 7 days, on **Log out**, when the web UI restarts (an update, or an `agentos-config apply` that changes LAN access), and when `agent`'s password is changed with `sudo agentos-config password` (or the same from the menu) — each of those logs everyone out. A password changed some other way (`sudo passwd agent`) doesn't end existing sessions: run `sudo systemctl restart agentos-web` after it.
- After 5 wrong passwords from one address (one /64 for IPv6), or 30 from anywhere, within 10 minutes, logins are refused until the 10 minutes have passed. This is by design: it's also the lockout a distributed guesser hits, and the way back in during it is the console or Tailscale, not another LAN login attempt. Every login, failed login and logout is in the audit log (`journalctl -t agentos-web`), as `agent@lan(<address>)`.
- With LAN access on, don't publish a Docker container on host port 443 or 80: Docker's own port forwarding and the LAN redirect would compete for it.
- Without a password for `agent`, LAN access stays off, and `apply` says so.
- Tailscale keeps working as before, alongside it.

## The web UI

Open **`https://<box>.<tailnet>.ts.net`** after allowing your tailnet login:

```bash
sudo agentos-config set AGENTOS_WEB_USERS you@example.com && sudo agentos-config apply
```

| Page | What it does |
|---|---|
| **Overview** | Health, agents, desktops, the latest CI run, and the **"AgentOS X is available"** banner, with release notes. |
| **Sessions** | Start or attach to agent sessions (claude, codex, opencode, grok, or a shell) in tmux, optionally in a fresh clone of a git repo. |
| **Terminal** | A full terminal in the browser. |
| **Desktops** | Live thumbnails. Open one in noVNC, create, or destroy. |
| **CI** | Runs, live per-step logs, re-run, cancel, "Run CI" on any directory, and push remotes. |
| **Settings** | Every setting in `agentos.env`, API keys (write-only), SSH keys, and the Solenta card. |
| **System** | Services, journal, Tailscale, power, and the **update card**: installed and available versions, Check now, Update with a live log, and rollback via the CLI. |

The footer shows the installed AgentOS version. Access requires a Tailscale identity in `AGENTOS_WEB_USERS`, or, with LAN access on, the password of `agent` (see [Without Tailscale](#without-tailscale-the-web-ui-on-your-local-network)). Requests from tagged devices carry no identity, so they are always refused. Every change goes through CSRF checks and is written to an audit log.

## Agents

Log in as `agent` and run `claude`, `codex`, `opencode` or `grok`. Each CLI works with **either a subscription login or an API key**. The box is headless, so every subscription login uses a flow that needs no local browser: open the printed URL on your laptop and paste back the code, or enter it there.

| CLI | Sign in with a subscription | Or use an API key |
|---|---|---|
| **Claude Code** | Run `claude` and choose your Claude Pro/Max account (log in once). Or run `claude setup-token` on any machine and store the result as `CLAUDE_CODE_OAUTH_TOKEN`. | `ANTHROPIC_API_KEY` |
| **Codex** | `codex login --device-auth` (ChatGPT plan). Turn on device-code login in your ChatGPT security settings first. | `OPENAI_API_KEY` |
| **opencode** | `opencode auth login`, then pick a provider and sign-in method. | Any provider key, via `opencode auth login` |
| **Grok** | `grok login --device-auth` (your xAI / grok.com account). | `XAI_API_KEY` |

- **Where API keys go:** in the web UI's Settings page, `sudo agentos-config`, or `agentos.env` at install time. AgentOS moves them to `~/.config/agentos/secrets.env` (mode 0600) and exports them to every shell and agent.
- **Where subscription logins go:** each CLI keeps its own credentials in the `agent` user's home, for example `~/.claude`, `~/.codex/auth.json` and `~/.grok/auth.json`. They survive AgentOS updates, but not a reinstall.
- **If both are set**, the CLI's own precedence decides. Claude Code, for example, prefers `ANTHROPIC_API_KEY` when it's set, so leave it empty if you want your subscription to be used.

`/usr/local/bin` wrappers load the keys from `~/.config/agentos/secrets.env` even in non-login shells, for example over `ssh box 'claude …'`. Every CLI is preconfigured with:
- **`agentos-computer`** (MCP): desktops for computer use.
- **`agentos-ci`** (MCP): `ci_run`, `ci_wait`, `ci_status`, `ci_logs`, `ci_list`, `ci_cancel`.
- **The `agentos-ci` skill:** before declaring work done, commit, run CI, wait for the result, and fix real failures. Never weaken tests to get a pass.

> [!TIP]
> Use a dedicated, spend-capped API key per AgentOS machine. A hijacked agent can read any key stored on the box.

## Desktops for computer use

Agents call `create_desktop`, then `screenshot`, `click`, `double_click`, `move`, `drag`, `type`, `key`, `scroll` and `cursor_position`, and finally `destroy_desktop`. Each desktop is an isolated XFCE session on its own X display (`:1` to `:16`), with Chromium available.

- **Watch** from the web UI's Desktops page, which uses noVNC with a per-desktop token.
- **Limits:** up to `AGENTOS_MAX_DESKTOPS` desktops (default 8). Screenshots are scaled to `AGENTOS_SCREENSHOT_WIDTH` (default 1366).
- **Reaper:** desktops idle for `AGENTOS_DESKTOP_IDLE_MINUTES` (default 120, `0` = never) are stopped, unless someone is viewing them.
- **Remote MCP:** `agentos-computer` is also served over HTTP on the tailnet (port 8765), for agents running elsewhere. It's protected by a token: `sudo agentos-config show-mcp-token`. Treat that token like a root password.

## Built-in CI

`agentos-ci` runs CI for any git repo under `/home/agent`, without GitHub. Pipeline selection, first match wins:

1. **`.agentos/ci.yml`:**
   ```yaml
   image: node:24        # optional: run every step in this container
   timeout: 30m          # optional (default 30m)
   secrets: [NPM_TOKEN]  # optional: names from secrets.env exposed to the steps
   steps:
     - name: install
       run: npm ci
     - name: test
       run: npm test
   ```
2. **`.github/workflows/*.yml`** with an `on: push` or `workflow_dispatch` trigger, run with [`act`](https://github.com/nektos/act). The `catthehacker/ubuntu:act-24.04` runner image is pulled on first use.
3. **Auto-detect:** an npm `test` script, pytest, `cargo test`, `go test ./...`, or `make test`.

Ways to run it:

```bash
agentos-ci run ~/work/myapp --wait          # run and wait
agentos-ci list                             # recent runs
agentos-ci logs <id> --follow               # live logs
agentos-ci status <id> | cancel <id>        # every command takes --json

agentos-ci remote create myapp              # push-to-run remote; prints:
#   git remote add agentos agent@<box>:git/myapp.git
git push agentos main                       # from your laptop: CI runs, the push prints the run id
```

You can also use the web UI's CI page, or let agents call `ci_run` / `ci_wait`. At most `AGENTOS_CI_MAX_PARALLEL` runs (default 2) execute at once; the rest queue. The newest 200 runs are kept.

> [!CAUTION]
> **CI is not a sandbox.** Steps run as `agent`, which has sudo and Docker, so a step can become root and can read `secrets.env`. Steps don't get API keys in their environment unless the repo lists them under `secrets:`, but that's hygiene, not isolation. **Never run untrusted code through agentos-ci.**

Details: [docs/solenta-and-ci.md](docs/solenta-and-ci.md#built-in-ci).

## Solenta

AgentOS works with [Solenta](https://github.com/currentbits/solenta) as it is, with no changes to Solenta.

- **Mode A (recommended): Solenta on the box.**
  1. In Solenta (0.27 or later) on your Mac, add the box under **Remote Connections**.
  2. Solenta installs its Linux build on the box over SSH. AgentOS's `agentos-solenta` service then keeps it running headless on `127.0.0.1:4620`, and Solenta reaches it through its own SSH tunnel.

  Agents, the CLIs and Solenta's MCP servers all run on the box. Before connecting, add the box's host key to your Mac's `known_hosts`. The Solenta card in the web UI, or `sudo agentos-config solenta`, shows the `ssh-keyscan` line to use.
- **Mode B: Solenta on your Mac, agents on the box.**
  1. Pair with `sudo agentos-config solenta`, or with the Solenta card in the web UI. It clones your repo, shows the `remoteHost` / `remotePath` values, and runs a preflight check.
  2. To give the box's agents Solenta's MCP servers, run `solenta-bridge` on your Mac. You can download it from the Solenta card. It keeps an `ssh -R` tunnel open for the MCP ports only, and never reads Solenta's tokens.

Solenta 0.26's Linux build crashes without an X display, so **0.27 or later is required**. Details: [docs/solenta-and-ci.md](docs/solenta-and-ci.md#solenta).

## Updates

AgentOS's own parts ship as the signed **`agentos`** package from AgentOS's apt repo, at `https://currentbits.github.io/agentos/apt`. Those parts are the scripts, services, web UI, agentos-ci, the MCP servers and the bridge.

- **Notify:** the box checks once a day. When a release is available, it says so on the web UI (Overview banner, System card, footer), the console, and at SSH login. **Nothing installs on its own.**
- **Update:** click **Update** on the System page, or run:
  ```bash
  agentos-update            # AgentOS first, then Debian packages, then the agent CLIs
  agentos-update --check    # check now
  agentos-update --version  # installed AgentOS version
  agentos-update --rollback [VERSION]   # go back to an earlier release
  ```
  An update never interrupts running agent sessions, desktops, Solenta or CI runs, and the web UI reconnects to its log if it restarts mid-update.
- **Debian security updates** still install automatically through unattended-upgrades, which never installs `agentos`. You can set `AGENTOS_AUTO_REBOOT=1` to reboot at 04:00 when a kernel update needs it.

Boxes installed before the update system existed need a one-time bootstrap: see [docs/updates.md](docs/updates.md#boxes-installed-before-updates-existed).

### Verifying the repository key

The package repository is signed by the AgentOS archive key:

```
6755 0B5C 0BA4 E47D E9F7  7146 232C 46B0 F5A0 43FE
```

```bash
curl -fsSL https://currentbits.github.io/agentos/apt/agentos-archive.gpg -o /tmp/agentos-archive.gpg
gpg --show-keys /tmp/agentos-archive.gpg     # compare the fingerprint with the one above
```

Boxes trust this key only for this repo (`Signed-By`). An unsigned or wrongly signed repo is refused.

## Security model

- **The network is closed by default.** SSH is reachable only over Tailscale unless you set `AGENTOS_LAN_SSH=1`, and password SSH is off. The web UI, noVNC and VNC listen on loopback only and are published only through `tailscale serve`, unless you set `AGENTOS_WEB_LAN=1`. The tailnet ACL above stops the box from reaching your other devices.
- **LAN access to the web UI is root-equivalent access for anyone who can reach the box's LAN address and knows the `agent` password.** Use it only on a network you trust (home, lab), with a strong password, and prefer Tailscale for anything else. It is HTTPS only (port 80 answers with nothing but a redirect to HTTPS); the password is checked by a root helper that reads it on stdin, so it never appears in a command line, a log or the audit trail. Sessions live only in the web server's memory, and logins are rate-limited. noVNC, MCP HTTP and SSH are not opened by it.
- **Secrets** are kept in `~agent/.config/agentos/secrets.env` (mode 0600). That file is parsed, never sourced. The web UI treats them as write-only, and they never appear in logs or `sudo` command lines.
- **Agents are trusted with the machine.** `agent` has passwordless sudo. Run AgentOS on a machine dedicated to agents, with spend-capped keys, and don't use it for anything else you care about.
- **Updates** are signed with a key that exists only in the release job (an Actions secret, used only for `v*` tags) and in an offline backup. Release notes are treated as untrusted text everywhere they're shown.
- **CI** is not a sandbox (see above).

## Settings reference

All settings go in `/etc/agentos/agentos.env`. Set them with `sudo agentos-config set KEY VALUE`, or in the web UI's Settings page.

| Key | Default | Meaning |
|---|---|---|
| `AGENTOS_HOSTNAME` | `agentos` | Hostname, and the machine's Tailscale name. |
| `AGENTOS_SSH_KEY` | — | An SSH public key for `agent`. |
| `AGENTOS_GITHUB_USER` | — | Import this GitHub user's SSH keys. |
| `AGENTOS_PASSWORD_HASH` | — | Console/sudo password hash for `agent` (`openssl passwd -6`). |
| `TS_AUTHKEY` | — | Tailscale auth key: single-use, pre-approved, tagged `tag:agentos`. Deleted after use. |
| `AGENTOS_LAN_SSH` | `0` | `1` = also accept key-only SSH on all interfaces. |
| `AGENTOS_CONSOLE` | `headless` | `headless` (status screen and login) or `terminal`. |
| `AGENTOS_WEB` | `1` | Publish the web UI on the tailnet. |
| `AGENTOS_WEB_USERS` | — | Comma-separated tailnet logins allowed into the web UI. Empty means nobody. |
| `AGENTOS_WEB_LAN` | `0` | `1` = also serve the web UI at `https://<LAN address>`, with the password of `agent`. |
| `AGENTOS_MAX_DESKTOPS` | `8` | Maximum concurrent desktops (1–16). |
| `AGENTOS_SCREENSHOT_WIDTH` | `1366` | Screenshot width sent to agents (640–1920). |
| `AGENTOS_DESKTOP_IDLE_MINUTES` | `120` | Reap idle desktops after this many minutes (`0` = never). |
| `AGENTOS_CI_MAX_PARALLEL` | `2` | Concurrent CI runs (1–16). |
| `AGENTOS_SOLENTA` | `1` | Keep a Solenta that Solenta installed running headless (Mode A). |
| `AGENTOS_AUTO_REBOOT` | `0` | `1` = reboot at 04:00 when a kernel update requires it. |
| `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `XAI_API_KEY` | — | Agent credentials, moved to `secrets.env` on apply. Optional if you sign in with a subscription instead (see [Agents](#agents)). |
| `AGENTOS_NET_IFACE`, `AGENTOS_NET_ADDRESS`, `AGENTOS_NET_GATEWAY`, `AGENTOS_NET_DNS` | DHCP | Static network, set by the installer. |
| `AGENTOS_INSTALL_DISK`, `AGENTOS_INSTALL_POWEROFF` | — | Unattended installer only. |

## Building from source

You need a **Debian 13** build host (root, KVM for the tests) with [mkosi](https://github.com/systemd/mkosi) v27, `qemu-system-x86`, `ovmf`, `cloud-image-utils`, `shellcheck`, `zstd`, `jq` and Docker.

```bash
AGENTOS_DEV=1 tools/build-deb.sh         # the agentos .deb (dev build: update source disabled)
mkosi -f build                           # mkosi.output/agentos.raw
TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed   # boots it in QEMU and runs test/checks
tools/build-installer.sh                 # mkosi.output/agentos-installer.raw
tools/convert.sh mkosi.output/agentos.raw <version> release mkosi.output/agentos-installer.raw
```

- **Re-running checks:** `SMOKE_ONLY='<regex>'` runs only the matching smoke checks.
- **Unit tests:**
  - shell: `test/*_test.sh`;
  - Python: `pytest test/ci`;
  - web: `npm ci && npx vitest run` in `web/server` and `web/ui`.
- **The `.deb` build is reproducible:** the same commit gives the same bytes. The base image is pinned by digest, and Python dependencies are pinned by hash in `tools/requirements.txt`.
- **CI:** [`.github/workflows/build.yml`](.github/workflows/build.yml) does all of the above on every push and pull request, plus a weekly rebuild.

## Repository layout

| Path | Contents |
|---|---|
| `mkosi.conf`, `mkosi.conf.d/` | Image definition: Debian packages and partitions. |
| `mkosi.prepare.chroot`, `mkosi.finalize.chroot` | Install the agent CLIs and toolchains, and check image invariants. |
| `mkosi.extra/` | Image-only files that other packages own or that only make sense in the image: `/etc/issue`, fstab, DHCP networking, cloud-init and apt auto-upgrade config, root growth on first boot, and the terminal profile. |
| `package/` | Everything in the **`agentos` .deb**: scripts (`usr/local/bin`, `usr/local/lib/agentos`), systemd units, configs, `agentos-ci`, the MCP servers, postinst and migrations. |
| `web/server`, `web/ui` | The web UI: Fastify + node-pty, and React + Vite. |
| `installer/` | The USB / virtual-CD installer image. |
| `tools/` | `build-deb.sh`, `apt-publish.sh`, `build-installer.sh`, `convert.sh`, `solenta-bridge`. |
| `dist/` | `agentos-dist`, the Girder worker that mirrors each release's installer to `dl.currentbits.net` as one `.iso`. |
| `test/` | The QEMU smoke harness (`smoke.sh`, `checks/`), installer tests and unit tests. |
| `docs/` | User docs, release notes (`docs/releases/`), and design specs and plans (`docs/superpowers/`). |

## Releasing (maintainers)

1. Write `docs/releases/<version>.md`: what's new, in plain text.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. The release job builds and tests everything, publishes the GitHub release (images, installer, checksums), and publishes the signed `agentos` package and notes to the apt repo on `gh-pages`. Within about 15–30 minutes, `agentos-dist` (`dist/`, on Girder) mirrors the installer to [dl.currentbits.net](https://dl.currentbits.net/agentos/index.html) as one `.iso`, after checking it against `SHA256SUMS`.

Boxes see the new release within a day, or immediately with **Check now**. Untagged builds are versioned `<last tag>+git<date>.<sha>`, so they never look like an older release. See [docs/updates.md](docs/updates.md) for the owner steps, the signing key, and how concurrent releases queue.

## More documentation

- [docs/updates.md](docs/updates.md): updates, rollback, the bootstrap for older boxes, security, and release owner steps.
- [docs/solenta-and-ci.md](docs/solenta-and-ci.md): Solenta modes A and B, and built-in CI in depth.
- [docs/tailscale-acl.md](docs/tailscale-acl.md): Tailscale key and ACL setup.
- [docs/releases/](docs/releases/): release notes.
- [docs/superpowers/](docs/superpowers/): design specs and implementation plans.
