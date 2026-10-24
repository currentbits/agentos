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
| Outputs | `agentos.raw`, `.qcow2` (Proxmox/Unraid/KVM/OpenStack), `.vhdx` (Hyper-V), `.vmdk` (VMware), `agentos-installer.img` (bare metal, USB only — see "Live environment" for the virtual-CD limitation) |
| Kernel | Generic `linux-image-amd64` + microcode + NIC firmware only (real hardware + all hypervisors) |
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
| Base | `linux-image-amd64`, `amd64-microcode`, `intel-microcode`, systemd, systemd-repart, grub (efi + pc), shim-signed, cloud-init, openssh-server, sudo, nftables, unattended-upgrades, tailscale (upstream apt repo) |
| NIC firmware | `firmware-realtek`, `firmware-bnx2`, `firmware-bnx2x`, `firmware-qlogic`, `firmware-misc-nonfree` (Intel/Mellanox NICs). Not `firmware-linux`: it drags in GPU firmware a headless box never loads |
| Guest agents | `qemu-guest-agent`, `hyperv-daemons`, `open-vm-tools` — each gated by `ConditionVirtualization` |
| Agent runtime | git, curl, ca-certificates, ripgrep, fd-find, jq, tmux, unzip, whiptail, Node 24 LTS (NodeSource; current Active LTS), Python 3 + venv + pipx |
| Agent CLIs | `claude` (native installer), `codex`, `opencode`, `grok` (xAI Grok Build, latest release, `https://x.ai/cli/install.sh`) — installed into `~agent` |
| Desktop | tigervnc-standalone-server, xfce4-session, xfwm4, xfce4-panel, xfdesktop4, xfce4-terminal, dbus-x11, xdotool, scrot, xclip, chromium, fonts-dejavu, fonts-noto-color-emoji. No Thunar, plugins, screensaver, power manager |
| Remote view | novnc, websockify |
| Local console | cage, foot (used only in `terminal` console mode) |
| Toolchains | build-essential, Go (apt), Rust (rustup), Bun, Docker CE, OpenJDK 21, Playwright + its Chromium |

### Size budget

Budget: CI fails the build above 7 GB (7168 MiB) root used space. The original 4 GB target was too low: measured Plan 1 root is ~5.4 GB (each agent CLI is 190–300 MB, Playwright browsers 677 MB, Rust 600 MB), and Plan 2 adds ~0.6 GB.

| Chunk | Rough size |
|---|---|
| Debian base + kernel + microcode + NIC firmware | ~0.7 GB |
| XFCE + Xvnc + Chromium + fonts | ~0.6 GB |
| Rust (rustup `minimal` profile + clippy, rustfmt) | ~0.5 GB |
| Docker CE, OpenJDK 21, Go | ~0.9 GB |
| Node, Bun, Python, build-essential | ~0.4 GB |
| Agent CLIs (4) | ~0.5 GB |
| Playwright Chromium | ~0.4 GB |

Trimming, all via mkosi `RemoveFiles=`/dpkg excludes: `/usr/share/doc`, `/usr/share/man`, `/usr/share/info`, non-English locales, apt lists, package caches. Rust uses the `minimal` profile (no offline docs, ~600 MB saved).

Two Chromiums is deliberate: Debian's `chromium` gets security updates via unattended-upgrades and is the one the desktop and agents browse with; Playwright's pinned Chromium is for test automation only.

### Users

Single user `agent`, passwordless sudo. The VM/machine is the security boundary, plus Tailscale. CLIs and toolchains live in `~agent` (`~/.local`, `~/.cargo`, `~/.bun`) so self-updaters never need root.

## 2. Desktops and computer use

### On-demand desktops — systemd is the registry

- Template unit `agentos-desktop@N.service` (User=agent): `Xvnc :N -geometry 1920x1080 -localhost` on port 5900+N, then `dbus-run-session startxfce4` with `DISPLAY=:N`. Own D-Bus session per desktop.
- `ExecStartPost` generates a random 128-bit token and writes the websockify token file `/run/agentos/vnc/N` (`<token>: localhost:59NN`); `ExecStopPost` removes it. The token is the viewer's credential, so it's unguessable rather than the desktop number.
- No state of our own: create = start the lowest free `agentos-desktop@N`; list = query systemd for active instances; destroy = stop the unit. All MCP server instances (stdio and HTTP) therefore share one view.
- Polkit rule allows `agent` to manage only `agentos-desktop@*.service`.
- Cap: `AGENTOS_MAX_DESKTOPS` (default 8). Each desktop + Chromium ≈ 300–500 MB RAM.

### MCP server `agentos-computer`

Python, xdotool + scrot. Tools:

- `create_desktop() -> {id, view_url}`, `list_desktops()`, `destroy_desktop(id)`
- `screenshot(desktop)`, `click(desktop, x, y, button)`, `double_click`, `move`, `drag`, `type(desktop, text)`, `key(desktop, combo)`, `scroll`, `cursor_position(desktop)`

Transports, same code:
- stdio — pre-registered in `~/.claude.json`, `~/.codex/config.toml`, opencode's `opencode.json`, and grok's settings.
- Streamable HTTP (`--http`) — `agentos-mcp-http.service` bound to `0.0.0.0:8765` (reachable only via `tailscale0` thanks to the nftables policy; binding the tailnet IP would break whenever tailscale0 comes up late), stateless, requiring `Authorization: Bearer <token>`. The token is generated at first boot (256-bit), stored root-only in `/etc/agentos/mcp-token`, passed to the service via `LoadCredential=`, and shown by `agentos-config`. The service runs as `agent` without `PrivateTmp` on purpose: it needs `/tmp/.X11-unix` and the shared desktop lock. Constant-time comparison; requests without it get 401.

If an existing well-maintained xdotool MCP server meets these requirements, use it instead of writing ours.

### Screenshot scaling

1920×1080 (~2 MP) exceeds what most models accept unscaled (~1.15 MP for Claude), which silently breaks click coordinates. The server:
- returns screenshots downscaled to `AGENTOS_SCREENSHOT_WIDTH` (default 1366, i.e. 1366×768),
- accepts input coordinates in that space,
- multiplies by the scale factor before calling xdotool, clamped to the screen.

### Watching

One websockify/noVNC bound to `0.0.0.0:6080` (tailnet-only via nftables) using `--token-plugin TokenFile --token-source /run/agentos/vnc/`. `view_url = http://<host>:6080/vnc.html?path=websockify%3Ftoken%3D<token>&autoconnect=1&resize=scale`, where `<host>` is the Tailscale DNS name when Tailscale is up, else the hostname. The view URL grants full interactive control, not just viewing: treat it like the MCP token. Tailscale encrypts the transport, so plain http on the tailnet is acceptable. Without Tailscale, reach it via SSH tunnel.

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
AGENTOS_CONSOLE=headless
ANTHROPIC_API_KEY=...
OPENAI_API_KEY=...
GROK_CODE_XAI_API_KEY=...
CLAUDE_CODE_OAUTH_TOKEN=...
```

Written by: the installer (bare metal), cloud-init `write_files` (VM images), or `agentos-config` (any time later). Every key is optional.

### `agentos-firstboot.service`

Oneshot, before desktop/MCP units, re-runs on each boot until it succeeds:
1. Apply hostname.
2. If `TS_AUTHKEY` set: `tailscale up --authkey --hostname --ssh`, then delete `TS_AUTHKEY` from the file. Failure prints the reason to console and retries next boot.
3. Move API keys/tokens to `~agent/.config/agentos/secrets.env` (0600), parsed (never sourced) by `/etc/profile.d/agentos.sh` into login shells. The MCP/noVNC services never read secrets; desktop terminals are login shells, so agents started inside a desktop do get the keys (intended).

### `agentos-config`

Whiptail TUI, runnable any time (`sudo agentos-config`). Sets: password for `agent`, SSH authorized keys (paste or GitHub username lookup), Tailscale auth key, API keys / OAuth token, LAN SSH toggle, console mode, max desktops, screenshot width. Writes `agentos.env` and re-runs firstboot.

### Local console

`AGENTOS_CONSOLE=headless|terminal`, chosen in the installer, changeable in `agentos-config`.

- **headless** (default): tty1 shows a status banner (hostname, IPs, tailnet name, desktop count) above a normal login prompt.
- **terminal**: for a machine with a monitor and keyboard. After a normal login on tty1, the `agent` login shell runs `cage -- foot -e tmux new -A -s main`: a full-screen terminal with proper Unicode, truecolor and mouse support. The raw Linux VT can't render agent TUIs properly. Login is still required, with no autologin.
  - The same tmux session `main` is reachable over SSH (`tmux attach -t main`), so you can start an agent at the desk and keep watching it remotely.
  - Adds `cage` (Wayland kiosk compositor) and `foot` (terminal), about 5 MB. Uses the kernel's generic KMS/simpledrm display, so no GPU firmware is needed.
  - `ponytail:` no local XFCE desktop on the physical screen. The desktops stay virtual (Section 2). Add a `desktop` console mode if someone wants local GUI use.

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

`mkosi.images/installer` builds a minimal live system (generic kernel, firmware, systemd, systemd-repart, grub, whiptail) that embeds the AgentOS root partition (zstd-compressed, ~1.5 GB). Boots straight into `agentos-install` on tty1 (Alt+F2 for a shell).

Packaging: mkosi has no ISO output, but `Format=disk` (+ optionally `ElTorito=yes`) produces one GPT disk image. mkosi documents El Torito as incompatible with grub as BIOS bootloader, so the **installer** image is UEFI-only regardless. That single file `agentos-installer.img` (~2 GB) is written to USB (`dd`, Etcher, Rufus DD mode) and boots UEFI.

The **installed system and the VM images** stay hybrid UEFI + BIOS (they carry no El Torito catalog), so BIOS-only clouds and hypervisors still work. `ponytail:` BIOS-only bare metal can't run the installer; `dd` `agentos.raw` to its disk instead. Add a post-build `xorriso` + isolinux step if that's ever needed.

**Known limitation (pending a decision):** `ElTorito=yes` builds fine (and was the original plan, to also support virtual CD / IPMI virtual media), but the resulting CD boot path drops to a GRUB rescue prompt — GRUB's embedded prefix does a GPT/PARTUUID search that can't resolve when the image is presented as CD-ROM media instead of a GPT disk, so it never finds `/grub/grub.cfg`. `ElTorito` is therefore disabled (`ElTorito=no`) and the installer is **USB-only** for now; CI's boot test runs with `SKIP_CD=1`. Revisit if virtual-CD/IPMI-media installs are needed.

### Interactive flow

1. Disk — `lsblk` list with model and size; the boot medium is excluded. Wipe confirmed by typing the disk name.
2. Hostname.
3. Network — wired DHCP (default) or static IP. Saved as a systemd-networkd config.
4. Access (skippable) — password for `agent` and/or SSH public key (paste or GitHub username lookup).
5. Tailscale auth key (skippable).
6. API keys (skippable).
7. Local console mode — `headless` (default) or `terminal` (see "Local console" below).
8. Summary → install:
   - Verify the embedded image (`sha256sum -c`), wipe the disk, write the tested `agentos.raw` verbatim (`zstd -dc | dd`), move the backup GPT to the disk end (`sgdisk -e`). The result is byte-identical to the VM images: ESP + BIOS boot + root, UEFI and BIOS bootable, Secure Boot via the signed shim; the root partition and filesystem grow at first boot (systemd-repart + x-systemd.growfs).
   - Mount the new root and apply settings with the target's own `agentos-config` (chroot); write the SSH key(s), password hash, optional static networkd file, and `/etc/cloud/cloud-init.disabled`.
   - Reboot.

Offline, ~2–3 minutes, byte-identical OS to the VM images.

### Unattended mode

If an `agentos.env` containing `AGENTOS_INSTALL_DISK=/dev/...` is found (on the installer image's FAT `AGENTOS` data partition, or fetched from the `agentos.autoinstall=<url>` kernel argument), the installer asks nothing and installs with those values. The data partition ships an `agentos.env.example` template; copy it to `agentos.env` on that partition to use it. Used by CI and for multi-machine installs. Remote config must be `https://` and may be pinned with `agentos.autoinstall_sha256=<hash>`; plain http is refused, since the file carries SSH keys and secrets. `AGENTOS_INSTALL_POWEROFF=1` powers the machine off instead of rebooting when the install finishes (useful for unattended/CI runs).

### Error handling

- The embedded image is checksum-verified (`sha256sum -c`) before anything is written.
- Any failure before the partition step: nothing touched, return to menu.
- Failure after partitioning: show the error and log path (`/tmp/agentos-install.log`), offer retry; the disk is considered wiped.
- Disk smaller than 32 GB: refuse.

## 5. Build, test, update

### Build — `.github/workflows/build.yml` (ubuntu-24.04)

1. Install recent mkosi (from its git tag; Ubuntu's packaged version is too old for trixie).
2. `mkosi build` → `agentos.raw` + `agentos-installer.img`.
3. `qemu-img convert` → `.qcow2`, `.vhdx`, `.vmdk`. Compress with zstd. Fail if root > 7 GB.
4. Run `test/smoke.sh`.
5. On tag `vYYYY.MM.DD`: GitHub Release with all artifacts, `SHA256SUMS`, a GitHub build-provenance attestation (`actions/attest-build-provenance`) per artifact, and `MANIFEST.txt` listing every apt package version plus each CLI's version and download SHA-256.
6. Weekly scheduled rebuild + release, so the newest artifact is ≤7 days behind Debian security fixes and CLI releases.

### Test — `test/smoke.sh`

Run for both firmware types (OVMF/UEFI and SeaBIOS/BIOS):
1. Boot the installer image in QEMU/KVM in unattended mode onto a blank 40 GB virtual disk (`AGENTOS_LAN_SSH=1`, an SSH key, no Tailscale key).
2. Reboot into the installed system.
3. Over SSH assert:
   - `claude`, `codex`, `opencode`, `grok`, `node`, `python3`, `go`, `cargo`, `bun`, `java`, `docker` all run `--version`;
   - root filesystem fills the disk;
   - nftables active; firstboot succeeded without a Tailscale key.
4. Security baseline:
   - SSH host keys and `/etc/machine-id` differ between two installs from the same image;
   - `ssh -o PasswordAuthentication=yes` is refused;
   - HTTP MCP without the bearer token returns 401;
   - a container started with `docker run -p 8080:80` is not reachable from the host side of QEMU's network;
   - `TS_AUTHKEY` is absent from `/etc/agentos/agentos.env` after firstboot.
5. Computer use via the MCP server over stdio: `create_desktop` → `screenshot` (assert 1366×768 PNG) → `click` → `destroy_desktop` → `list_desktops` is empty.
6. Boot `agentos.qcow2` directly with a cloud-init NoCloud seed and repeat step 3 (verifies the VM-image path).

The MCP server additionally carries an `assert`-based self-check of the coordinate scaling (1366→1920 mapping, edge clamping).

### Keeping a running system current

- `unattended-upgrades`: Debian security updates, automatic.
- `agentos-update` (manual): `apt upgrade` + each CLI's own updater (`claude update`, `opencode upgrade`, …) + `rustup update` + `bun upgrade`.
- No automatic CLI update timer: an agent's tools changing mid-task is worse than being a week behind. Claude Code's built-in auto-update remains as-is.

## 6. Security

### Threat model

- **Primary threat: a hijacked agent.** Agents read untrusted content (web pages, repos, issues, screenshots). A prompt injection gets whatever the `agent` user has: shell, sudo, Docker, API keys, the network. We accept that an agent can own its machine, because that's what the machine is for. We defend everything *around* it: other machines, your tailnet, other installs, and your keys' blast radius.
- **Secondary: network attackers** reaching the box from the internet or LAN.
- **Supply chain**: what goes into the image at build time.
- Out of scope: a malicious tailnet admin, physical attackers (no disk encryption in v1).

### Per-install uniqueness (image-based installs share bytes)

Every install and every VM from the same image must not share identity:
- `/etc/machine-id` empty in the image (mkosi default) → generated at first boot.
- `/etc/agentos/mcp-token` absent in the image (build fails otherwise) → generated at first boot.
- SSH host keys removed at build (`RemoveFiles=/etc/ssh/ssh_host_*`); `agentos-ssh-keygen.service` runs `ssh-keygen -A` before sshd starts when no host key exists.
- No Tailscale state in the image (`/var/lib/tailscale` empty); systemd random seed not shipped.
- No CLI login state in the image: CI asserts `~agent/.claude*`, `~agent/.codex/auth.json`, grok and opencode auth files don't exist.

### Network exposure

- nftables default-drop inbound except `tailscale0`, loopback, established (Section 3).
- **Docker bypasses host firewall rules** for published ports (its DNAT traffic goes through FORWARD, not INPUT). Two layers:
  - `/etc/docker/daemon.json` sets `"ip": "127.0.0.1"`, so `-p 8080:80` binds localhost by default;
  - a `docker.service` drop-in (`ExecStartPost`) adds a `DOCKER-USER` rule dropping new forwarded connections that arrive on any interface other than `tailscale0`, for when an agent explicitly passes `0.0.0.0`.
- Our ruleset lives in its own `table inet agentos` with **no `flush ruleset`** (Debian's default `nftables.conf` has one), so reloading it never wipes Docker's or Tailscale's rules.
- Every service that can drive the machine needs a credential even on the tailnet: MCP HTTP needs a bearer token, and noVNC needs a random per-desktop token. Being on the tailnet alone is not enough, because one shared tailnet device shouldn't mean remote code execution on every AgentOS box.
- Xvnc binds localhost only; websockify is the only path to it.

### Tailscale

- Docs and `agentos-config` recommend a **tagged, pre-approved** auth key (`tag:agentos`), so the node is owned by the tag, not your user, and can't reach your other devices unless your ACL allows it.
- Shipped ACL snippet: `tag:agentos` may receive connections from `autogroup:admin` on 22/6080/8765, and may initiate connections to nothing on the tailnet (internet egress still works).
- Tailscale SSH stays on, but `agentos-config` warns if the ACL lets non-admins in.

### SSH

`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers agent`. Passwords are for console and sudo only.

### Secrets

- `agentos.env` and `secrets.env` are 0600. `TS_AUTHKEY` is deleted after use; the MCP token is root-only.
- API keys are inherently readable by a hijacked agent. Mitigation is outside the OS: use **dedicated, spend-capped keys per AgentOS box** (Anthropic/OpenAI/xAI consoles all support per-key limits). `agentos-config` says so when you enter keys.
- In unattended installs the config with secrets stays on the USB stick: the installer prints a warning to wipe or remove `agentos.env` from the `AGENTOS` partition afterwards.

### Updates and patching

- `unattended-upgrades` origins: Debian security (includes `chromium`), plus the Tailscale and Docker apt repos. Auto-reboot at 04:00 only when a kernel update requires it (`Automatic-Reboot "true"`, `Automatic-Reboot-Time "04:00"`); `AGENTOS_AUTO_REBOOT=0` disables.
- CPU microcode packages shipped (`amd64-microcode`, `intel-microcode`).

### Kernel and OS hardening (cheap defaults only)

sysctl: `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1`, `kernel.unprivileged_bpf_disabled=1`, `net.core.bpf_jit_harden=2`, `kernel.yama.ptrace_scope=1`, `fs.protected_*=1/2`, `net.ipv4.conf.*.rp_filter=2` (loose, per Tailscale guidance), no ICMP redirects. Services we ship (`agentos-mcp-http`, novnc) use systemd sandboxing: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only` where possible, `PrivateTmp`.

Deliberately **not** done: AppArmor profiles for the agent CLIs, SELinux, dropping sudo. Each fights the agents' job of installing and running arbitrary software, while the box is already the boundary.

### Supply chain

- Third-party apt repos (Tailscale, Docker, NodeSource) use pinned keyrings via `signed-by=` with fingerprints checked in to the repo.
- Agent CLIs: downloaded at build over HTTPS from their official sources. Where a release publishes checksums (GitHub releases for codex and opencode, Claude's native installer verifies its own), the build verifies them. Every CLI's version and SHA-256 are recorded in `MANIFEST.txt`.
- Releases carry GitHub build-provenance attestations, so `gh attestation verify` proves an image was built by this repo's CI.
- The installer refuses `http://` autoinstall URLs (Section 4).
- Secure Boot via Debian's signed shim and GRUB.

### v2 candidates (not v1)

LUKS with TPM2 unlock; an egress allowlist mode (agent may reach only LLM APIs, package registries and GitHub); per-desktop Unix users if the XFCE spike shows we need them anyway.

## Resolved during review

- **Grok**: xAI's official Grok Build (`grok`, Apache-2.0, `xai-org/grok-build`), latest release via `https://x.ai/cli/install.sh`; headless auth via `GROK_CODE_XAI_API_KEY`.
- **Image size**: targeted firmware instead of `firmware-linux`, Rust `minimal` profile, doc/locale stripping; 7 GB budget (raised from 4.5 GB after measuring).
- **ISO**: mkosi `Format=disk` + `ElTorito=yes`, one `.img` for USB and virtual CD, UEFI-only (El Torito and grub-BIOS are mutually exclusive in mkosi). Installed systems and VM images remain UEFI + BIOS. No separate ISO tooling.

## Open items to resolve during planning

- Grok Build's MCP server config file location and format (for pre-registering `agentos-computer`), and whether `install.sh` supports a non-interactive per-user install with checksum verification.
- How mkosi passes the main image's root partition into the installer sub-image (`mkosi.images/` dependencies vs. a build script that copies from the output dir).
