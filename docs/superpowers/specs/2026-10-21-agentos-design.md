# AgentOS — Design

Date: 2026-10-21
Status: Draft, awaiting review

## Goal

A minimal, headless Linux OS whose only job is to run AI coding agents (Claude Code, Codex, opencode, Grok CLI) plus everything they need to build software, with on-demand virtual XFCE desktops that agents can drive for computer use. Installs on bare metal via our own installer, and ships as VM images for hypervisors and clouds — all from one build.

"Nothing extra" means: no office/media apps, no desktop apps beyond XFCE core + Chromium. The dev toolchains are the only deliberate extras.

## Decisions

| Topic | Decision |
|---|---|
| Base | Debian 13 (trixie), amd64 |
| Build tool | mkosi (declarative, builds without booting a VM; must run on Linux — CI or a Linux VM) |
| Outputs | `agentos.raw`, `.qcow2` (Proxmox/Unraid/KVM/OpenStack), `.vhdx` (Hyper-V), `.vmdk` (VMware), `agentos-installer.iso` (bare metal) |
| Kernel | Generic `linux-image-amd64` + `firmware-linux` (real hardware + all hypervisors) |
| Boot | GRUB hybrid UEFI + BIOS, Debian signed shim (Secure Boot works) |
| Agent CLIs | Baked in at build, installed per-user so their own updaters work |
| Toolchains | Batteries included |
| Computer use | On-demand 1920×1080 XFCE desktops, driven via one MCP server (stdio in-VM + HTTP on tailnet) |
| Remote access | Tailscale; public interface closed by default |
| Out of scope v1 | RAID, LVM, dual-boot, LUKS (v2 candidate), WiFi, arm64 |

## 1. Image contents

### Repo layout

```
mkosi.conf                    # Debian trixie, amd64, packages, bootloader, outputs
mkosi.images/installer/       # sub-image: live installer environment
mkosi.postinst.chroot         # non-apt installs: agent CLIs, rustup, bun, Playwright browsers
mkosi.repart/                 # partition definitions (ESP, BIOS boot, root)
mkosi.extra/                  # files copied verbatim into the image
  etc/systemd/system/         #   agentos-desktop@.service, agentos-novnc, agentos-mcp-http, agentos-firstboot
  etc/polkit-1/rules.d/       #   lets `agent` start/stop agentos-desktop@* only
  etc/nftables.conf
  etc/profile.d/agentos.sh    #   loads ~agent/.config/agentos/secrets.env
  home/agent/.config/xfce4/   #   minimal preconfigured desktop
  usr/local/bin/              #   agentos-config, agentos-update, agentos-install
  usr/local/lib/agentos/      #   agentos-computer MCP server
test/smoke.sh
.github/workflows/build.yml
```

### Packages

| Group | Contents |
|---|---|
| Base | `linux-image-amd64`, `firmware-linux`, systemd, systemd-repart, grub (efi + pc), shim-signed, cloud-init, openssh-server, sudo, nftables, unattended-upgrades, tailscale (upstream apt repo) |
| Guest agents | `qemu-guest-agent`, `hyperv-daemons`, `open-vm-tools` — each gated by `ConditionVirtualization` |
| Agent runtime | git, curl, ca-certificates, ripgrep, fd-find, jq, tmux, unzip, whiptail, Node 22 LTS, Python 3 + venv + pipx |
| Agent CLIs | `claude` (native installer), `codex`, `opencode`, `grok` — installed into `~agent` |
| Desktop | tigervnc-standalone-server, xfce4-session, xfwm4, xfce4-panel, xfdesktop4, xfce4-terminal, dbus-x11, xdotool, scrot, xclip, chromium, fonts-dejavu, fonts-noto-color-emoji. No Thunar, plugins, screensaver, power manager |
| Remote view | novnc, websockify |
| Toolchains | build-essential, Go (apt), Rust (rustup), Bun, Docker CE, OpenJDK 21, Playwright + its Chromium |

Expected size: 3–4 GB uncompressed.

### Users

Single user `agent`, passwordless sudo. The VM/machine is the security boundary, plus Tailscale. CLIs and toolchains live in `~agent` (`~/.local`, `~/.cargo`, `~/.bun`) so self-updaters never need root.

## 2. Desktops and computer use

### On-demand desktops — systemd is the registry

- Template unit `agentos-desktop@N.service` (User=agent): `Xvnc :N -geometry 1920x1080 -localhost` on port 5900+N, then `dbus-run-session startxfce4` with `DISPLAY=:N`. Own D-Bus session per desktop.
- `ExecStartPost` writes the websockify token file `/run/agentos/vnc/N` (`N: localhost:59NN`); `ExecStopPost` removes it.
- No state of our own: create = start the lowest free `agentos-desktop@N`; list = query systemd for active instances; destroy = stop the unit. All MCP server instances (stdio and HTTP) therefore share one view.
- Polkit rule allows `agent` to manage only `agentos-desktop@*.service`.
- Cap: `AGENTOS_MAX_DESKTOPS` (default 8). Each desktop + Chromium ≈ 300–500 MB RAM.

### MCP server `agentos-computer`

Python, xdotool + scrot. Tools:

- `create_desktop() -> {id, view_url}`, `list_desktops()`, `destroy_desktop(id)`
- `screenshot(desktop)`, `click(desktop, x, y, button)`, `double_click`, `move`, `drag`, `type(desktop, text)`, `key(desktop, combo)`, `scroll`, `cursor_position(desktop)`

Transports, same code:
- stdio — pre-registered in `~/.claude.json`, `~/.codex/config.toml`, opencode's `opencode.json`, and grok's settings.
- Streamable HTTP (`--http`) — `agentos-mcp-http.service` on `<tailnet-ip>:8765`.

If an existing well-maintained xdotool MCP server meets these requirements, use it instead of writing ours.

### Screenshot scaling

1920×1080 (~2 MP) exceeds what most models accept unscaled (~1.15 MP for Claude), which silently breaks click coordinates. The server:
- returns screenshots downscaled to `AGENTOS_SCREENSHOT_WIDTH` (default 1366, i.e. 1366×768),
- accepts input coordinates in that space,
- multiplies by the scale factor before calling xdotool, clamped to the screen.

### Watching

One websockify/noVNC on `<tailnet-ip>:6080` using `--token-plugin TokenFile --token-source /run/agentos/vnc/`. `view_url = http://<host>:6080/vnc.html?path=websockify?token=N`. Without Tailscale, reach it via SSH tunnel.

### Web tasks

Headless Playwright/Chromium needs no desktop; agents should prefer it for web-only work. Desktops are for GUI-only tasks.

### Known risks (spike first)

1. Multiple `startxfce4` sessions under one user may conflict (xfconfd, panel). Fallback: one Unix user per desktop (`agent-dN`).
2. Desktops leaked by crashed agents. `ponytail:` no idle reaper; add one if leaks occur in practice.
3. One desktop per agent: two agents on the same desktop collide; nothing prevents it.

## 3. Configuration, secrets, network

### Single config file

All settings are KEY=VALUE in `/etc/agentos/agentos.env` (0600):

```
AGENTOS_HOSTNAME=agentos-01
TS_AUTHKEY=tskey-auth-...
AGENTOS_MAX_DESKTOPS=8
AGENTOS_SCREENSHOT_WIDTH=1366
AGENTOS_LAN_SSH=0
ANTHROPIC_API_KEY=...
OPENAI_API_KEY=...
XAI_API_KEY=...
CLAUDE_CODE_OAUTH_TOKEN=...
```

Written by: the installer (bare metal), cloud-init `write_files` (VM images), or `agentos-config` (any time later). Every key is optional.

### `agentos-firstboot.service`

Oneshot, before desktop/MCP units, re-runs on each boot until it succeeds:
1. Apply hostname.
2. If `TS_AUTHKEY` set: `tailscale up --authkey --hostname --ssh`, then delete `TS_AUTHKEY` from the file. Failure prints the reason to console and retries next boot.
3. Move API keys/tokens to `~agent/.config/agentos/secrets.env` (0600), loaded by `/etc/profile.d/agentos.sh` into login shells. Desktop/MCP units never read secrets.

### `agentos-config`

Whiptail TUI, runnable any time (`sudo agentos-config`). Sets: password for `agent`, SSH authorized keys (paste or GitHub username lookup), Tailscale auth key, API keys / OAuth token, LAN SSH toggle, max desktops, screenshot width. Writes `agentos.env` and re-runs firstboot.

### Lockout prevention

If `agent` has no password, no SSH key, and Tailscale is not up, tty1 autologins straight into `agentos-config` on every boot. As soon as a password or key exists, autologin is disabled and tty1 shows a normal login prompt. (Console access already implies physical/hypervisor access.)

### Network

- nftables: allow inbound only on `tailscale0` + established/related + loopback. Public/LAN interfaces closed.
- `AGENTOS_LAN_SSH=1` additionally opens port 22 on all interfaces.
- SSH over the network is always key-only (`PasswordAuthentication no`); passwords are for console and sudo only.
- Tailscale SSH is enabled for tailnet access.
- Subscription logins (no API key): set `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`), or SSH in and run `claude` / `codex login --device-auth` once.

## 4. Installer

### Live environment

`mkosi.images/installer` builds a minimal live system (generic kernel, firmware, systemd, systemd-repart, grub, whiptail) that embeds `agentos.raw`. Packaged as a hybrid ISO bootable from USB or virtual CD, UEFI and BIOS. Boots straight into `agentos-install` on tty1 (Alt+F2 for a shell).

### Interactive flow

1. Disk — `lsblk` list with model and size; the boot medium is excluded. Wipe confirmed by typing the disk name.
2. Hostname.
3. Network — wired DHCP (default) or static IP. Saved as a systemd-networkd config.
4. Access (skippable) — password for `agent` and/or SSH public key (paste or GitHub username lookup).
5. Tailscale auth key (skippable).
6. API keys (skippable).
7. Summary → install:
   - `systemd-repart --empty=force` lays out ESP + BIOS boot + root, copying root from `agentos.raw`; root grows to fill the disk.
   - Write `agentos.env`, hostname, network config, credentials into the new root.
   - `grub-install` for UEFI (removable/fallback path `\EFI\BOOT\BOOTX64.EFI`, no NVRAM entry needed) and BIOS.
   - Reboot.

Offline, ~2–3 minutes, byte-identical OS to the VM images.

### Unattended mode

If an `agentos.env` containing `AGENTOS_INSTALL_DISK=/dev/...` is found (on the ISO's writable data partition, or fetched from the `agentos.autoinstall=<url>` kernel argument), the installer asks nothing and installs with those values. Used by CI and for multi-machine installs.

### Error handling

- Any failure before the partition step: nothing touched, return to menu.
- Failure after partitioning: show the error and log path (`/tmp/agentos-install.log`), offer retry; the disk is considered wiped.
- Disk smaller than 32 GB: refuse.

## 5. Build, test, update

### Build — `.github/workflows/build.yml` (ubuntu-24.04)

1. Install recent mkosi (from its git tag; Ubuntu's packaged version is too old for trixie).
2. `mkosi build` → `agentos.raw` + `agentos-installer.iso`.
3. `qemu-img convert` → `.qcow2`, `.vhdx`, `.vmdk`. Compress with zstd.
4. Run `test/smoke.sh`.
5. On tag `vYYYY.MM.DD`: GitHub Release with all artifacts + `SHA256SUMS`.
6. Weekly scheduled rebuild + release, so the newest artifact is ≤7 days behind Debian security fixes and CLI releases.

### Test — `test/smoke.sh`

Run for both firmware types (OVMF/UEFI and SeaBIOS/BIOS):
1. Boot the installer ISO in QEMU/KVM in unattended mode onto a blank 40 GB virtual disk (`AGENTOS_LAN_SSH=1`, an SSH key, no Tailscale key).
2. Reboot into the installed system.
3. Over SSH assert:
   - `claude`, `codex`, `opencode`, `grok`, `node`, `python3`, `go`, `cargo`, `bun`, `java`, `docker` all run `--version`;
   - root filesystem fills the disk;
   - nftables active; firstboot succeeded without a Tailscale key.
4. Computer use via the MCP server over stdio: `create_desktop` → `screenshot` (assert 1366×768 PNG) → `click` → `destroy_desktop` → `list_desktops` is empty.
5. Boot `agentos.qcow2` directly with a cloud-init NoCloud seed and repeat step 3 (verifies the VM-image path).

The MCP server additionally carries an `assert`-based self-check of the coordinate scaling (1366→1920 mapping, edge clamping).

### Keeping a running system current

- `unattended-upgrades`: Debian security updates, automatic.
- `agentos-update` (manual): `apt upgrade` + each CLI's own updater (`claude update`, `opencode upgrade`, …) + `rustup update` + `bun upgrade`.
- No automatic CLI update timer: an agent's tools changing mid-task is worse than being a week behind. Claude Code's built-in auto-update remains as-is.

## Open items to resolve during planning

- Which `grok` CLI to ship: xAI's official CLI if available, otherwise the community `grok-cli`.
- Confirm the generic kernel + `firmware-linux` keeps the image within ~4 GB.
- Confirm mkosi's current support for embedding one image inside another's ISO (sub-images) vs. a post-build `xorriso` step.
