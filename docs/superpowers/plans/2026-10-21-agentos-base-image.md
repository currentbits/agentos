# AgentOS Base Image Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Debian 13 disk image, built by mkosi, that boots in UEFI and BIOS. It contains the agent CLIs and toolchains, is configured by `agentos.env`, sits behind a tailnet-only firewall, and is proven by a QEMU smoke test in CI.

**Architecture:** One mkosi project at the repo root. Packages are declared in `mkosi.conf.d/*.conf`. Non-apt installs (agent CLIs, rustup, bun, Playwright) run in `mkosi.prepare.chroot`, which has network access. Static files live in `mkosi.extra/`. Build-time invariants are asserted in `mkosi.finalize.chroot`. Runtime behaviour is small bash scripts in `/usr/local/{bin,lib/agentos}`, driven by systemd units. `test/smoke.sh` boots the image in QEMU with a cloud-init NoCloud seed, then runs every `test/checks/*.sh` over SSH.

**Tech Stack:** mkosi (≥ v26, from git), Debian trixie, systemd, bash, nftables, cloud-init, QEMU/OVMF, GitHub Actions.

**Out of scope here:** desktops, the MCP server and noVNC (Plan 2), and the installer image (Plan 3).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-21-agentos-design.md`. When this plan and the spec disagree, the spec wins; stop and flag it.
- Base: Debian 13 `trixie`, `x86-64`, components `main,contrib,non-free,non-free-firmware`.
- Single user `agent` (uid 1000), passwordless sudo, groups `sudo,docker`. Account password locked by default.
- CLIs and user toolchains install into `/home/agent` (`~/.local`, `~/.cargo`, `~/.bun`, etc.), never `/usr/local`.
- All runtime config lives in `/etc/agentos/agentos.env` (KEY=VALUE, mode 0600). Every key is optional.
- Secrets match `^[A-Z0-9_]*(API_KEY|TOKEN)=` and move to `/home/agent/.config/agentos/secrets.env` (0600, owned by agent).
- Inbound network: drop everything except loopback, `tailscale0`, established, ICMP, DHCP, and Tailscale UDP 41641. `AGENTOS_LAN_SSH=1` additionally opens TCP 22.
- SSH: key-only, `PermitRootLogin no`, `AllowUsers agent`.
- Root filesystem used space after first boot ≤ 4608 MiB (CI fails above that).
- No SSH host keys, machine-id, Tailscale state, or CLI auth files in the built image.
- Every script: `#!/bin/bash` + `set -euo pipefail`. Every script must pass `shellcheck`.

## Build host (all tasks)

mkosi only runs on Linux. Run every build and test on an **Ubuntu 24.04 x86-64 host with KVM**: a local VM, `devvm`, or the GitHub runner from Task 9. One-time setup:

```bash
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils pipx git shellcheck gnupg curl
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0   # mkosi needs user namespaces
sudo chmod 666 /dev/kvm
pipx install "git+https://github.com/systemd/mkosi@$(git ls-remote --tags --sort=-v:refname https://github.com/systemd/mkosi 'v2*' | head -1 | sed 's#.*refs/tags/##; s#\^{}##')"
mkosi --version   # expect 26 or newer
```

## File map

```
mkosi.conf                          # distribution, output, boot, global content settings
mkosi.conf.d/10-base.conf           # base system packages
mkosi.conf.d/20-runtime.conf        # agent runtime + toolchain packages (apt)
mkosi.prepare.chroot                # creates `agent`, installs CLIs/toolchains as agent (network)
mkosi.finalize.chroot               # asserts image invariants, writes MANIFEST
apt/                                # copied to /etc/apt in build sandbox AND image
  sources.list.d/{nodesource,docker,tailscale}.sources
  keyrings/{nodesource.gpg,docker.asc,tailscale.gpg}
tools/fetch-keyrings.sh             # one-time keyring download + fingerprint check
mkosi.extra/
  etc/ssh/sshd_config.d/10-agentos.conf
  etc/sudoers.d/agent
  etc/cloud/cloud.cfg.d/90-agentos.cfg
  etc/systemd/network/80-dhcp.network
  etc/systemd/system/agentos-ssh-keygen.service
  etc/systemd/system/agentos-firewall.service
  etc/systemd/system/agentos-firstboot.service
  etc/systemd/system/docker.service.d/10-agentos.conf
  etc/docker/daemon.json
  etc/sysctl.d/90-agentos.conf
  etc/apt/apt.conf.d/20auto-upgrades
  etc/apt/apt.conf.d/52agentos-unattended
  etc/dpkg/dpkg.cfg.d/01-agentos-nodoc   # (in mkosi.skeleton, see Task 8)
  etc/profile.d/agentos.sh
  etc/issue
  usr/lib/systemd/system-preset/10-agentos.preset
  usr/local/lib/agentos/env.sh
  usr/local/lib/agentos/firewall.nft
  usr/local/lib/agentos/docker-user.sh
  usr/local/sbin/agentos-firewall
  usr/local/sbin/agentos-firstboot
  usr/local/sbin/agentos-console-apply
  usr/local/sbin/agentos-config-tty
  usr/local/bin/agentos-config
  usr/local/bin/agentos-update
test/smoke.sh                        # boots image in QEMU (uefi + bios), runs checks
test/checks/NN-*.sh                  # one file per task, defines check_* functions
.github/workflows/build.yml
```

---

### Task 1: Bootable minimal image and smoke harness

**Files:**
- Create: `mkosi.conf`, `mkosi.conf.d/10-base.conf`, `mkosi.prepare.chroot`
- Create: `mkosi.extra/etc/ssh/sshd_config.d/10-agentos.conf`, `mkosi.extra/etc/sudoers.d/agent`, `mkosi.extra/etc/cloud/cloud.cfg.d/90-agentos.cfg`, `mkosi.extra/etc/systemd/network/80-dhcp.network`, `mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset`
- Create: `test/smoke.sh`, `test/checks/10-base.sh`, `.gitignore`

**Interfaces:**
- Produces: `mkosi.output/agentos.raw`, the build output used by every later task.
- Produces: `test/smoke.sh <image.raw> [uefi] [bios]`. Exit 0 means all checks passed. It sources every `test/checks/*.sh` and runs each function named `check_*`. Inside a check:
  - `vm <cmd>` runs a command as `agent` over SSH (non-login shell);
  - `vml '<cmd>'` runs it in a login shell (`bash -lc`), so `/etc/profile.d` applies;
  - `$MODE` is `uefi` or `bios`, `$WORK` is a temp dir shared across modes, and `$HOSTPORT_HTTP` is a host port forwarded to guest TCP 8080.
- Produces: the guest's `agentos.env` written by the seed. It contains `AGENTOS_HOSTNAME=agentos-test`, `AGENTOS_LAN_SSH=1`, `ANTHROPIC_API_KEY=sk-test-dummy`, `AGENTOS_AUTO_REBOOT=0`.

- [ ] **Step 1: Write the smoke harness (the failing test)**

`test/smoke.sh`:
```bash
#!/bin/bash
# Boot an AgentOS image in QEMU (UEFI and/or BIOS) and run test/checks/*.sh against it.
set -euo pipefail

IMG=$(realpath "${1:?usage: smoke.sh <agentos.raw> [uefi] [bios]}")
shift
MODES=("$@"); [ ${#MODES[@]} -gt 0 ] || MODES=(uefi bios)
HERE=$(cd "$(dirname "$0")" && pwd)
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d)
export WORK
FAILS=0

cleanup() {
  for p in "$WORK"/*.pid; do [ -e "$p" ] && kill "$(cat "$p")" 2>/dev/null || true; done
  [ "${KEEP_WORK:-0}" = 1 ] && echo "work dir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"

cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$WORK/key.pub")
write_files:
  - path: /etc/agentos/agentos.env
    permissions: "0600"
    content: |
      AGENTOS_HOSTNAME=agentos-test
      AGENTOS_LAN_SSH=1
      AGENTOS_AUTO_REBOOT=0
      ANTHROPIC_API_KEY=sk-test-dummy
EOF

vm()  { ssh -i "$WORK/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=5 agent@127.0.0.1 "$@"; }
vml() { vm "bash -lc $(printf '%q' "$1")"; }
export -f vm vml

boot() {  # boot <mode> <port>
  local mode=$1
  PORT=$2; HOSTPORT_HTTP=$(( $2 + 1 ))
  export PORT HOSTPORT_HTTP MODE=$mode
  printf 'instance-id: smoke-%s-%s\n' "$mode" "$RANDOM" > "$WORK/meta-data"
  cloud-localds "$WORK/seed-$mode.iso" "$WORK/user-data" "$WORK/meta-data"
  qemu-img convert -O qcow2 "$IMG" "$WORK/disk-$mode.qcow2"
  qemu-img resize -q "$WORK/disk-$mode.qcow2" 40G
  local fw=()
  if [ "$mode" = uefi ]; then
    cp "$OVMF_VARS" "$WORK/vars.fd"
    fw=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd")
  fi
  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 -smp 2 "${fw[@]}" \
    -drive "file=$WORK/disk-$mode.qcow2,if=virtio" \
    -drive "file=$WORK/seed-$mode.iso,media=cdrom" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22,hostfwd=tcp:127.0.0.1:$HOSTPORT_HTTP-:8080" \
    -display none -serial "file:$WORK/serial-$mode.log" \
    -daemonize -pidfile "$WORK/qemu-$mode.pid"
  for _ in $(seq 1 120); do
    vm true 2>/dev/null && vm 'cloud-init status --wait >/dev/null 2>&1; systemctl is-system-running --wait >/dev/null 2>&1 || true' && return 0
    sleep 5
  done
  echo "FAIL [$mode] VM never became reachable over SSH; serial log tail:"; tail -50 "$WORK/serial-$mode.log"
  return 1
}

run_checks() {
  local f fn
  for f in "$HERE"/checks/*.sh; do
    # shellcheck source=/dev/null
    . "$f"
  done
  for fn in $(declare -F | awk '{print $3}' | grep '^check_' | sort); do
    if out=$("$fn" 2>&1); then echo "PASS [$MODE] $fn"
    else echo "FAIL [$MODE] $fn"; echo "$out" | sed 's/^/    /'; FAILS=$((FAILS + 1)); fi
  done
}

port=2222
for mode in "${MODES[@]}"; do
  if boot "$mode" "$port"; then run_checks; else FAILS=$((FAILS + 1)); fi
  kill "$(cat "$WORK/qemu-$mode.pid")" 2>/dev/null || true
  port=$((port + 10))
done

[ "$FAILS" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "$FAILS FAILURE(S)"; exit 1; }
```

`test/checks/10-base.sh`:
```bash
# shellcheck shell=bash
check_boot_mode_matches() {
  if [ "$MODE" = uefi ]; then vm 'test -d /sys/firmware/efi'; else vm 'test ! -d /sys/firmware/efi'; fi
}
check_agent_user()        { vm 'test "$(id -u)" = 1000 && id -nG | grep -qw sudo'; }
check_passwordless_sudo() { vm 'sudo -n true'; }
check_password_ssh_refused() {
  ! ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no agent@127.0.0.1 true 2>/dev/null
}
check_sshd_hardening() {
  vm 'sudo sshd -T | grep -qx "passwordauthentication no" &&
      sudo sshd -T | grep -qx "permitrootlogin no" &&
      sudo sshd -T | grep -qx "allowusers agent"'
}
check_root_grown()        { vm 'test "$(df --output=size -BG / | tail -1 | tr -dc 0-9)" -ge 35'; }
check_networkd_dhcp()     { vm 'networkctl status >/dev/null && getent hosts deb.debian.org >/dev/null'; }
```

`.gitignore`:
```
mkosi.output/
mkosi.cache/
mkosi.tools/
```

- [ ] **Step 2: Run the harness without an image to confirm it fails**

```bash
chmod +x test/smoke.sh && shellcheck test/smoke.sh test/checks/*.sh
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: it exits non-zero because `realpath` can't find `mkosi.output/agentos.raw`.

- [ ] **Step 3: Write the mkosi config and base files**

`mkosi.conf`:
```ini
[Distribution]
Distribution=debian
Release=trixie
Architecture=x86-64
Repositories=main,contrib,non-free,non-free-firmware

[Output]
ImageId=agentos
Format=disk
OutputDirectory=mkosi.output
ManifestFormat=json

[Build]
ToolsTree=default
WithNetwork=yes

[Content]
Bootable=yes
Bootloader=grub-signed
BiosBootloader=grub
ShimBootloader=signed
UnifiedKernelImages=none
KernelCommandLine=console=ttyS0 console=tty0
Hostname=agentos
Locale=C.UTF-8
Timezone=UTC
Ssh=never
WithDocs=no
RemoveFiles=/etc/ssh/ssh_host_*
            /var/lib/apt/lists/*
            /var/cache/apt/*.bin
            /home/agent/.npm
            /home/agent/.cargo/registry
            /home/agent/.bun/install/cache
```

`mkosi.conf.d/10-base.conf`:
```ini
[Content]
Packages=
        linux-image-amd64
        amd64-microcode
        intel-microcode
        firmware-realtek
        firmware-bnx2
        firmware-bnx2x
        firmware-qlogic
        firmware-misc-nonfree
        systemd
        systemd-sysv
        systemd-resolved
        udev
        dbus
        grub-efi-amd64-bin
        grub-efi-amd64-signed
        grub-pc-bin
        shim-signed
        openssh-server
        sudo
        ca-certificates
        cloud-init
        cloud-guest-utils
        nftables
        iptables
        iproute2
        iputils-ping
        procps
        less
        qemu-guest-agent
        hyperv-daemons
        open-vm-tools
```

`mkosi.prepare.chroot` (Task 3 and Task 4 extend it):
```bash
#!/bin/bash
# Runs inside the image after apt packages are installed. Has network access.
set -euo pipefail
[ "${1:-final}" = final ] || exit 0

id agent >/dev/null 2>&1 || useradd --create-home --uid 1000 --shell /bin/bash --groups sudo agent
```

`mkosi.extra/etc/ssh/sshd_config.d/10-agentos.conf`:
```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers agent
```

`mkosi.extra/etc/sudoers.d/agent` (must be mode 0440; Step 4 sets it):
```
agent ALL=(ALL) NOPASSWD:ALL
```

`mkosi.extra/etc/cloud/cloud.cfg.d/90-agentos.cfg`:
```yaml
system_info:
  default_user:
    name: agent
    lock_passwd: true
    shell: /bin/bash
    groups: [sudo]
disable_root: true
ssh_pwauth: false
```

`mkosi.extra/etc/systemd/network/80-dhcp.network`:
```ini
[Match]
Name=en* eth*

[Network]
DHCP=yes
```

`mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset`:
```
enable systemd-networkd.service
enable systemd-resolved.service
enable ssh.service
enable cloud-*.service
enable qemu-guest-agent.service
enable agentos-*.service
disable nftables.service
```

- [ ] **Step 4: Build**

```bash
chmod 0440 mkosi.extra/etc/sudoers.d/agent
chmod +x mkosi.prepare.chroot
mkosi -f build
ls -lh mkosi.output/agentos.raw
```
Expected: the build finishes and `agentos.raw` exists (roughly 1–2 GB at this stage).

If mkosi rejects `Bootloader=grub-signed` together with `UnifiedKernelImages=none`, use `Bootloader=grub` with `ShimBootloader=none`, and record "Secure Boot: not yet working" in the commit message. Plan 1 must not block on Secure Boot.

- [ ] **Step 5: Run the smoke test**

```bash
test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `PASS` for all 7 checks in both modes, then `ALL CHECKS PASSED`. If boot fails, rerun with `KEEP_WORK=1` and read `serial-<mode>.log`.

- [ ] **Step 6: Commit**

```bash
git add .gitignore mkosi.conf mkosi.conf.d mkosi.prepare.chroot mkosi.extra test
git commit -m "feat: bootable Debian trixie base image with QEMU smoke test"
```

---

### Task 2: Per-install identity and build-time invariants

**Files:**
- Create: `mkosi.extra/etc/systemd/system/agentos-ssh-keygen.service`
- Create: `mkosi.finalize.chroot`
- Create: `test/checks/20-identity.sh`

**Interfaces:**
- Produces: `mkosi.finalize.chroot`. It fails the build if a forbidden file exists, and writes `/var/lib/agentos-manifest.txt` into the image; Task 4 and Task 9 extend it and copy it out.
- Produces: `$WORK/ident-<mode>`, which smoke checks compare across modes.

- [ ] **Step 1: Write the failing checks**

`test/checks/20-identity.sh`:
```bash
# shellcheck shell=bash
check_host_keys_present() { vm 'test -s /etc/ssh/ssh_host_ed25519_key.pub'; }
check_machine_id_set()    { vm 'test "$(wc -c < /etc/machine-id)" -eq 33'; }
check_identity_unique_across_boots() {
  vm 'cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub' > "$WORK/ident-$MODE"
  local other
  for other in "$WORK"/ident-*; do
    [ "$other" = "$WORK/ident-$MODE" ] && continue
    ! cmp -s "$other" "$WORK/ident-$MODE" || { echo "identity identical to $other"; return 1; }
  done
}
```

- [ ] **Step 2: Run to see what fails**

```bash
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: the checks pass on cloud-init boots, because cloud-init regenerates host keys. The real guard is the build-time assertion in Step 3, which also covers non-cloud-init boots (installer, Plan 3). Go to Step 3 either way.

- [ ] **Step 3: Implement key generation and build assertions**

`mkosi.extra/etc/systemd/system/agentos-ssh-keygen.service`:
```ini
[Unit]
Description=Generate SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
```

`mkosi.finalize.chroot`:
```bash
#!/bin/bash
# Runs inside the finished image tree, after RemoveFiles. Fails the build on leaked per-install state.
set -euo pipefail

fail() { echo "IMAGE INVARIANT VIOLATED: $*" >&2; exit 1; }

compgen -G '/etc/ssh/ssh_host_*' >/dev/null && fail "SSH host keys baked into image"
[ -s /etc/machine-id ] && [ "$(cat /etc/machine-id)" != uninitialized ] && fail "machine-id baked into image"
[ -n "$(ls -A /var/lib/tailscale 2>/dev/null)" ] && fail "tailscale state baked into image"
for f in /home/agent/.claude/.credentials.json /home/agent/.codex/auth.json \
         /home/agent/.local/share/opencode/auth.json /home/agent/.grok/auth.json; do
  [ -e "$f" ] && fail "CLI auth state baked into image: $f"
done

dpkg-query -W -f '${Package} ${Version}\n' > /var/lib/agentos-manifest.txt
echo "image invariants OK"
```

- [ ] **Step 4: Build and test**

```bash
chmod +x mkosi.finalize.chroot
mkosi -f build 2>&1 | tee /tmp/build.log | grep -E 'image invariants OK|INVARIANT'
test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `image invariants OK` in the build log, and `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add mkosi.extra/etc/systemd/system/agentos-ssh-keygen.service mkosi.finalize.chroot test/checks/20-identity.sh
git commit -m "feat: per-install SSH host keys and build-time image invariants"
```

---

### Task 3: Third-party repos, runtimes and toolchains

**Files:**
- Create: `tools/fetch-keyrings.sh`, `apt/sources.list.d/{nodesource,docker,tailscale}.sources`, `apt/keyrings/*`
- Create: `mkosi.conf.d/20-runtime.conf`, `mkosi.extra/etc/profile.d/agentos.sh`
- Modify: `mkosi.prepare.chroot`, `mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset`
- Create: `test/checks/30-toolchains.sh`

**Interfaces:**
- Produces: `/etc/profile.d/agentos.sh`, which puts these on the login PATH: `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`, `~/.opencode/bin`, `~/.grok/bin`. Task 5 appends secrets loading to this file.
- Produces: helper `as_agent '<script>'` in `mkosi.prepare.chroot`, which Task 4 reuses.

- [ ] **Step 1: Write the failing checks**

`test/checks/30-toolchains.sh`:
```bash
# shellcheck shell=bash
check_node_24()     { vml 'node --version | grep -q "^v24\."'; }
check_python()      { vml 'python3 --version && python3 -m venv --help >/dev/null && pipx --version'; }
check_go()          { vml 'go version'; }
check_rust()        { vml 'cargo --version && rustc --version && cargo clippy --version && rustfmt --version'; }
check_rust_user()   { vml 'test "$(command -v cargo)" = "$HOME/.cargo/bin/cargo"'; }
check_bun()         { vml 'bun --version'; }
check_java()        { vml 'java -version 2>&1 | grep -q "\"21\."'; }
check_build_tools() { vml 'gcc --version && make --version && pkg-config --version'; }
check_cli_utils()   { vml 'git --version && rg --version && fdfind --version && jq --version && tmux -V'; }
check_docker()      { vm 'id -nG | grep -qw docker && docker run --rm hello-world | grep -q "Hello from Docker"'; }
check_tailscale()   { vm 'tailscale version && systemctl is-active tailscaled'; }
check_playwright()  { vml 'test -d "$HOME/.cache/ms-playwright" && ls "$HOME/.cache/ms-playwright" | grep -q chromium'; }
```

- [ ] **Step 2: Run to confirm failures**

```bash
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: all `check_node_24` … `check_playwright` FAIL (not installed).

- [ ] **Step 3: Fetch and pin third-party keyrings**

`tools/fetch-keyrings.sh`:
```bash
#!/bin/bash
# One-time: download third-party apt keyrings and verify fingerprints. Commit the results.
set -euo pipefail
cd "$(dirname "$0")/../apt/keyrings"

fetch() {  # fetch <file> <url> <expected-fingerprint>
  curl -fsSL "$2" -o "$1"
  local got
  got=$(gpg --show-keys --with-colons "$1" | awk -F: '/^fpr/{print $10; exit}')
  [ "$got" = "$3" ] || { echo "FINGERPRINT MISMATCH for $1: got $got, expected $3" >&2; rm -f "$1"; exit 1; }
  echo "OK $1 $got"
}

fetch docker.asc     https://download.docker.com/linux/debian/gpg                 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
fetch tailscale.gpg  https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg  2596A99EAAB33821893C0A79458CA832957F5868
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor > nodesource.gpg
got=$(gpg --show-keys --with-colons nodesource.gpg | awk -F: '/^fpr/{print $10; exit}')
[ "$got" = 6F71F525282841EEDAF851B42F59B5F99B1BE0B4 ] || { echo "FINGERPRINT MISMATCH nodesource: $got" >&2; rm -f nodesource.gpg; exit 1; }
echo "OK nodesource.gpg $got"
```
If a fingerprint mismatches, **stop**. Check the vendor's current install docs (Docker, Tailscale, NodeSource) for the published fingerprint. Update the script only if the vendor publishes the new value; never just accept whatever was downloaded.

`apt/sources.list.d/docker.sources`:
```
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
```

`apt/sources.list.d/tailscale.sources`:
```
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/tailscale.gpg
```

`apt/sources.list.d/nodesource.sources`:
```
Types: deb
URIs: https://deb.nodesource.com/node_24.x
Suites: nodistro
Components: main
Signed-By: /etc/apt/keyrings/nodesource.gpg
```

```bash
mkdir -p apt/keyrings && chmod +x tools/fetch-keyrings.sh && tools/fetch-keyrings.sh
```
Expected: three `OK` lines.

Wire `apt/` into both the build sandbox (so mkosi's apt can see the repos) and the image (so apt in the running system keeps using them). In `mkosi.conf`, add `SandboxTrees=apt:/etc/apt` under `[Build]` and `SkeletonTrees=apt:/etc/apt` under `[Content]`.

- [ ] **Step 4: Add apt packages**

`mkosi.conf.d/20-runtime.conf`:
```ini
[Content]
Packages=
        git
        curl
        ripgrep
        fd-find
        jq
        tmux
        unzip
        zstd
        xz-utils
        whiptail
        nodejs
        python3
        python3-venv
        python3-pip
        pipx
        build-essential
        pkg-config
        libssl-dev
        golang-go
        openjdk-21-jdk-headless
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
        tailscale
```

Append to `mkosi.extra/usr/lib/systemd/system-preset/10-agentos.preset`:
```
enable docker.service
enable containerd.service
enable tailscaled.service
```

- [ ] **Step 5: Install user toolchains in the prepare script**

Replace `mkosi.prepare.chroot` with:
```bash
#!/bin/bash
# Runs inside the image after apt packages are installed. Has network access.
set -euo pipefail
[ "${1:-final}" = final ] || exit 0

id agent >/dev/null 2>&1 || useradd --create-home --uid 1000 --shell /bin/bash --groups sudo,docker agent
usermod -aG docker agent

AGENT_PATH=/home/agent/.local/bin:/home/agent/.cargo/bin:/home/agent/.bun/bin:/home/agent/.opencode/bin:/home/agent/.grok/bin:/usr/local/bin:/usr/bin:/bin
as_agent() {
  runuser -u agent -- env -i HOME=/home/agent USER=agent PATH="$AGENT_PATH" \
    SHELL=/bin/bash TERM=dumb bash -euo pipefail -c "$1"
}

# Rust: minimal profile (no offline docs) + clippy, rustfmt
as_agent 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal -c clippy,rustfmt'
# Bun
as_agent 'curl -fsSL https://bun.sh/install | bash'
# npm global prefix inside ~/.local so `npm i -g` never needs root
as_agent 'npm config set prefix "$HOME/.local"'
# Playwright + its Chromium (browser in ~/.cache/ms-playwright); OS deps via apt as root
as_agent 'npm install -g playwright'
/home/agent/.local/bin/playwright install-deps chromium
as_agent 'playwright install chromium'
```

`mkosi.extra/etc/profile.d/agentos.sh`:
```bash
# AgentOS: user toolchain paths for the agent user.
for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin" "$HOME/.opencode/bin" "$HOME/.grok/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
export PATH
```

- [ ] **Step 6: Build and test**

```bash
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 7: Commit**

```bash
git add tools apt mkosi.conf mkosi.conf.d/20-runtime.conf mkosi.prepare.chroot mkosi.extra test/checks/30-toolchains.sh
git commit -m "feat: runtimes and batteries-included toolchains with pinned third-party repos"
```

---

### Task 4: Agent CLIs and manifest

**Files:**
- Modify: `mkosi.prepare.chroot` (append), `mkosi.finalize.chroot` (append)
- Create: `test/checks/40-agent-clis.sh`

**Interfaces:**
- Consumes: `as_agent` from Task 3.
- Produces: the binaries `claude`, `codex`, `opencode` and `grok` on the agent's login PATH. Produces `/var/lib/agentos-manifest.txt`, which gains a `# agent CLIs` section with `<name> <version> <sha256>` lines (Task 9 publishes it).

- [ ] **Step 1: Write the failing checks**

`test/checks/40-agent-clis.sh`:
```bash
# shellcheck shell=bash
check_claude()   { vml 'claude --version'; }
check_codex()    { vml 'codex --version'; }
check_opencode() { vml 'opencode --version'; }
check_grok()     { vml 'grok --version'; }
check_clis_user_owned() {
  vml 'for c in claude codex opencode grok; do p=$(readlink -f "$(command -v $c)"); case "$p" in /home/agent/*) ;; *) echo "$c at $p"; exit 1;; esac; done'
}
check_manifest_lists_clis() { vm 'grep -A4 "^# agent CLIs" /var/lib/agentos-manifest.txt | grep -c . | grep -qx 5'; }
```

- [ ] **Step 2: Run to confirm failures**

```bash
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: the six new checks FAIL.

- [ ] **Step 3: Install CLIs**

Append to `mkosi.prepare.chroot`:
```bash
# Agent CLIs, each via its official installer, into the agent's home so self-updates work without root.
as_agent 'curl -fsSL https://claude.ai/install.sh | bash'
as_agent 'npm install -g @openai/codex'
as_agent 'curl -fsSL https://opencode.ai/install | bash'
as_agent 'curl -fsSL https://x.ai/cli/install.sh | bash'

# Installers may edit ~/.bashrc / ~/.profile to add PATH lines; /etc/profile.d/agentos.sh owns PATH.
cp /etc/skel/.bashrc /home/agent/.bashrc
cp /etc/skel/.profile /home/agent/.profile
chown agent:agent /home/agent/.bashrc /home/agent/.profile

for c in claude codex opencode grok; do
  as_agent "command -v $c >/dev/null" || { echo "agent CLI '$c' not on PATH after install" >&2; exit 1; }
done
```
If `grok` is not found, run `find /home/agent -maxdepth 4 -name grok -type f` inside `mkosi shell`. Add the directory you find to both `AGENT_PATH` in `mkosi.prepare.chroot` and the loop in `/etc/profile.d/agentos.sh`.

Append to `mkosi.finalize.chroot` (before `echo "image invariants OK"`):
```bash
{
  echo "# agent CLIs"
  for c in claude codex opencode grok; do
    p=$(runuser -u agent -- bash -lc "readlink -f \"\$(command -v $c)\"")
    v=$(runuser -u agent -- bash -lc "$c --version 2>/dev/null | head -1")
    echo "$c ${v// /_} $(sha256sum "$p" | cut -d' ' -f1)"
  done
} >> /var/lib/agentos-manifest.txt
```

- [ ] **Step 4: Build and test**

```bash
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `ALL CHECKS PASSED`, and the build still prints `image invariants OK` (no auth files were created).

- [ ] **Step 5: Commit**

```bash
git add mkosi.prepare.chroot mkosi.finalize.chroot test/checks/40-agent-clis.sh
git commit -m "feat: bake claude, codex, opencode and grok into the agent's home"
```

---

### Task 5: `agentos.env`, firstboot, secrets and Tailscale

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/env.sh`, `mkosi.extra/usr/local/sbin/agentos-firstboot`, `mkosi.extra/etc/systemd/system/agentos-firstboot.service`
- Modify: `mkosi.extra/etc/profile.d/agentos.sh` (append)
- Create: `test/checks/50-firstboot.sh`, `test/env_test.sh`

**Interfaces:**
- Produces: `/usr/local/lib/agentos/env.sh` (sourced, root only), which defines:
  - `AGENTOS_ENV=/etc/agentos/agentos.env` and `AGENTOS_SECRETS=/home/agent/.config/agentos/secrets.env`
  - `env_get <file> <KEY>`: prints the last value, or nothing
  - `env_set <file> <KEY> <VALUE>`: replaces or appends; rejects bad keys and newline values (exit 2)
  - `env_unset <file> <KEY>`
  - `is_secret_key <KEY>`: exit 0 if the key matches `^[A-Z0-9_]*(API_KEY|TOKEN)$`
- Produces: `/usr/local/sbin/agentos-firstboot`, idempotent and safe to re-run. Task 6 and Task 7 add calls to `agentos-firewall` and `agentos-console-apply` at the end of it.
- Produces: `/etc/agentos/mcp-token` (0600 root, 43 chars), which Plan 2 consumes.

- [ ] **Step 1: Write the failing unit test for env.sh**

`test/env_test.sh` (runs on the build host, with no VM):
```bash
#!/bin/bash
set -euo pipefail
# shellcheck source=../mkosi.extra/usr/local/lib/agentos/env.sh
. "$(dirname "$0")/../mkosi.extra/usr/local/lib/agentos/env.sh"
f=$(mktemp); trap 'rm -f "$f"' EXIT

env_set "$f" FOO bar;               [ "$(env_get "$f" FOO)" = bar ]
env_set "$f" FOO 'baz=qux&x/y';     [ "$(env_get "$f" FOO)" = 'baz=qux&x/y' ]; [ "$(grep -c '^FOO=' "$f")" = 1 ]
env_set "$f" OTHER 1;               [ "$(env_get "$f" OTHER)" = 1 ]
env_unset "$f" FOO;                 [ -z "$(env_get "$f" FOO)" ]; [ "$(env_get "$f" OTHER)" = 1 ]
! env_set "$f" 'bad-key' x 2>/dev/null
! env_set "$f" GOOD $'two\nlines' 2>/dev/null
is_secret_key ANTHROPIC_API_KEY; is_secret_key CLAUDE_CODE_OAUTH_TOKEN; is_secret_key GEMINI_API_KEY
! is_secret_key TS_AUTHKEY; ! is_secret_key AGENTOS_LAN_SSH
echo "env.sh OK"
```

```bash
chmod +x test/env_test.sh && test/env_test.sh
```
Expected: FAIL, because `env.sh` doesn't exist yet.

- [ ] **Step 2: Implement env.sh**

`mkosi.extra/usr/local/lib/agentos/env.sh`:
```bash
# shellcheck shell=bash
# AgentOS KEY=VALUE env-file helpers. Sourced by agentos-firstboot and agentos-config.
AGENTOS_ENV=/etc/agentos/agentos.env
AGENTOS_SECRETS=/home/agent/.config/agentos/secrets.env

env_get() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n1 || true; }

env_unset() {
  [ -f "$1" ] || return 0
  local tmp; tmp=$(mktemp "$1.XXXXXX")
  grep -v "^$2=" "$1" > "$tmp" || true
  chmod --reference="$1" "$tmp"; chown --reference="$1" "$tmp" 2>/dev/null || true
  mv "$tmp" "$1"
}

env_set() {
  [[ $2 =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "invalid key: $2" >&2; return 2; }
  [[ $3 != *$'\n'* ]] || { echo "value for $2 contains a newline" >&2; return 2; }
  [ -f "$1" ] || install -m 600 /dev/null "$1"
  env_unset "$1" "$2"
  printf '%s=%s\n' "$2" "$3" >> "$1"
}

is_secret_key() { [[ $1 =~ ^[A-Z0-9_]*(API_KEY|TOKEN)$ ]]; }
```

```bash
test/env_test.sh
```
Expected: `env.sh OK`.

- [ ] **Step 3: Write the failing VM checks**

`test/checks/50-firstboot.sh`:
```bash
# shellcheck shell=bash
check_firstboot_succeeded() { vm 'systemctl is-active agentos-firstboot.service'; }
check_hostname_applied()    { vm 'test "$(hostname)" = agentos-test'; }
check_env_mode()            { vm 'test "$(sudo stat -c %a /etc/agentos/agentos.env)" = 600'; }
check_secret_moved()        { vm '! sudo grep -q ANTHROPIC_API_KEY /etc/agentos/agentos.env &&
                                  test "$(stat -c %a ~/.config/agentos/secrets.env)" = 600'; }
check_secret_in_login_env() { vml 'test "$ANTHROPIC_API_KEY" = sk-test-dummy'; }
check_mcp_token()           { vm 'test "$(sudo stat -c %a /etc/agentos/mcp-token)" = 600 &&
                                  test "$(sudo wc -c < /etc/agentos/mcp-token)" -ge 40'; }
check_no_tskey_ok()         { vm '! sudo grep -q "^TS_AUTHKEY=" /etc/agentos/agentos.env'; }
check_firstboot_rerun_idempotent() {
  vm 'sudo /usr/local/sbin/agentos-firstboot && test "$(grep -c ANTHROPIC_API_KEY ~/.config/agentos/secrets.env)" = 1'
}
```

```bash
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: the new checks FAIL.

- [ ] **Step 4: Implement firstboot**

`mkosi.extra/usr/local/sbin/agentos-firstboot`:
```bash
#!/bin/bash
# Apply /etc/agentos/agentos.env. Idempotent; runs every boot and after agentos-config changes.
set -euo pipefail
. /usr/local/lib/agentos/env.sh

install -d -m 700 /etc/agentos
[ -f "$AGENTOS_ENV" ] || install -m 600 /dev/null "$AGENTOS_ENV"
chmod 600 "$AGENTOS_ENV"

# 1. Hostname
h=$(env_get "$AGENTOS_ENV" AGENTOS_HOSTNAME)
[ -n "$h" ] && [ "$(hostname)" != "$h" ] && hostnamectl set-hostname "$h"

# 2. MCP bearer token (consumed by Plan 2)
if [ ! -s /etc/agentos/mcp-token ]; then
  (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > /etc/agentos/mcp-token)
fi

# 3. Secrets -> agent-owned file
install -d -o agent -g agent -m 700 /home/agent/.config /home/agent/.config/agentos
[ -f "$AGENTOS_SECRETS" ] || install -o agent -g agent -m 600 /dev/null "$AGENTOS_SECRETS"
while IFS='=' read -r k v; do
  [ -n "$k" ] && is_secret_key "$k" || continue
  env_set "$AGENTOS_SECRETS" "$k" "$v"
  env_unset "$AGENTOS_ENV" "$k"
done < <(grep -E '^[A-Z0-9_]+=' "$AGENTOS_ENV" || true)
chown agent:agent "$AGENTOS_SECRETS"; chmod 600 "$AGENTOS_SECRETS"

# 4. Auto-reboot preference for unattended-upgrades
if [ "$(env_get "$AGENTOS_ENV" AGENTOS_AUTO_REBOOT)" = 0 ]; then
  echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/53agentos-noreboot
else
  rm -f /etc/apt/apt.conf.d/53agentos-noreboot
fi

# 5. Tailscale last: a bad key must not block the steps above. Failure -> unit fails, retried next boot.
k=$(env_get "$AGENTOS_ENV" TS_AUTHKEY)
if [ -n "$k" ]; then
  tailscale up --auth-key="$k" --hostname="$(hostname)" --ssh
  env_unset "$AGENTOS_ENV" TS_AUTHKEY
fi
```

`mkosi.extra/etc/systemd/system/agentos-firstboot.service`:
```ini
[Unit]
Description=AgentOS: apply /etc/agentos/agentos.env
After=cloud-init.service network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agentos-firstboot
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
```

Append to `mkosi.extra/etc/profile.d/agentos.sh`:
```bash
# AgentOS: API keys / tokens for agent CLIs (written by agentos-firstboot / agentos-config).
if [ -r "$HOME/.config/agentos/secrets.env" ]; then
  set -a; . "$HOME/.config/agentos/secrets.env"; set +a
fi
```

- [ ] **Step 5: Build and test**

```bash
chmod +x mkosi.extra/usr/local/sbin/agentos-firstboot
shellcheck mkosi.extra/usr/local/sbin/* mkosi.extra/usr/local/lib/agentos/*.sh
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add mkosi.extra test/checks/50-firstboot.sh test/env_test.sh
git commit -m "feat: agentos.env firstboot: hostname, secrets, MCP token, tailscale"
```

---

### Task 6: Firewall, Docker exposure, sysctl and unattended upgrades

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/firewall.nft`, `mkosi.extra/usr/local/sbin/agentos-firewall`, `mkosi.extra/etc/systemd/system/agentos-firewall.service`
- Create: `mkosi.extra/etc/docker/daemon.json`, `mkosi.extra/usr/local/lib/agentos/docker-user.sh`, `mkosi.extra/etc/systemd/system/docker.service.d/10-agentos.conf`
- Create: `mkosi.extra/etc/sysctl.d/90-agentos.conf`, `mkosi.extra/etc/apt/apt.conf.d/20auto-upgrades`, `mkosi.extra/etc/apt/apt.conf.d/52agentos-unattended`
- Modify: `mkosi.conf.d/10-base.conf` (add `unattended-upgrades`), `mkosi.extra/usr/local/sbin/agentos-firstboot` (append)
- Create: `test/checks/60-network.sh`

**Interfaces:**
- Consumes: `env_get`, `AGENTOS_ENV` (Task 5).
- Produces: `agentos-firewall`. It reloads the `inet agentos` table from `firewall.nft` and adds TCP 22 to the `public_tcp` set when `AGENTOS_LAN_SSH=1`. Plan 2 opens nothing publicly, because noVNC and MCP are tailnet-only and already allowed through `tailscale0`.

- [ ] **Step 1: Write the failing checks**

`test/checks/60-network.sh`:
```bash
# shellcheck shell=bash
check_nft_table()       { vm 'sudo nft list table inet agentos | grep -q "policy drop"'; }
check_lan_ssh_open()    { vm 'sudo nft list set inet agentos public_tcp | grep -qw 22'; }
check_no_flush_ruleset(){ vm 'sudo nft list tables | grep -q "ip filter\|ip nat"'; }  # docker's tables survived
check_docker_default_localhost() {
  vm 'docker rm -f ag-web >/dev/null 2>&1; docker run -d --name ag-web -p 8080:80 nginx:alpine >/dev/null && sleep 3'
  ! curl -s -m 5 "http://127.0.0.1:$HOSTPORT_HTTP/" >/dev/null
}
check_docker_explicit_public_blocked() {
  vm 'docker rm -f ag-web >/dev/null 2>&1; docker run -d --name ag-web -p 0.0.0.0:8080:80 nginx:alpine >/dev/null && sleep 3'
  local rc=0; curl -s -m 5 "http://127.0.0.1:$HOSTPORT_HTTP/" >/dev/null || rc=$?
  vm 'docker rm -f ag-web >/dev/null; curl -sf -m 5 http://127.0.0.1:8080/ >/dev/null || true'
  [ "$rc" -ne 0 ]
}
check_sysctl()          { vm 'test "$(sysctl -n kernel.kptr_restrict)" = 2 && test "$(sysctl -n kernel.unprivileged_bpf_disabled)" -ge 1'; }
check_unattended()      { vm 'systemctl is-enabled apt-daily-upgrade.timer && sudo unattended-upgrade --dry-run -d 2>&1 | grep -q "Allowed origins.*Debian-Security"'; }
check_noreboot_honored(){ vm 'test -f /etc/apt/apt.conf.d/53agentos-noreboot'; }
```
`check_docker_default_localhost` is a negative test: it passes when the host can't reach the container. The guest-side curl in the cleanup line is just a sanity probe.

```bash
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: `check_nft_table`, `check_lan_ssh_open`, `check_docker_*`, `check_sysctl` and `check_unattended` FAIL. `check_noreboot_honored` already passes (Task 5).

- [ ] **Step 2: Implement the firewall**

`mkosi.extra/usr/local/lib/agentos/firewall.nft`:
```
# AgentOS inbound policy. Own table, no `flush ruleset`: Docker and Tailscale rules stay intact.
table inet agentos
delete table inet agentos

table inet agentos {
  set public_tcp { type inet_service; }

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
  }
}
```

`mkosi.extra/usr/local/sbin/agentos-firewall`:
```bash
#!/bin/bash
# Load AgentOS nftables policy and apply env-driven openings.
set -euo pipefail
. /usr/local/lib/agentos/env.sh
nft -f /usr/local/lib/agentos/firewall.nft
if [ "$(env_get "$AGENTOS_ENV" AGENTOS_LAN_SSH)" = 1 ]; then
  nft add element inet agentos public_tcp '{ 22 }'
fi
```

`mkosi.extra/etc/systemd/system/agentos-firewall.service`:
```ini
[Unit]
Description=AgentOS: inbound firewall
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agentos-firewall

[Install]
WantedBy=sysinit.target
```

Append to `mkosi.extra/usr/local/sbin/agentos-firstboot`, **before** the `# 5. Tailscale` block, so that a Tailscale failure can't skip it:
```bash
# 4b. Re-apply firewall (env may have changed)
/usr/local/sbin/agentos-firewall
```

- [ ] **Step 3: Implement the Docker exposure guard**

`mkosi.extra/etc/docker/daemon.json`:
```json
{
  "ip": "127.0.0.1"
}
```

`mkosi.extra/usr/local/lib/agentos/docker-user.sh`:
```bash
#!/bin/bash
# Drop NEW forwarded connections into containers unless they arrive via tailnet or local bridges.
set -euo pipefail
iptables -N AGENTOS-DOCKER 2>/dev/null || iptables -F AGENTOS-DOCKER
iptables -A AGENTOS-DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
for i in lo docker0 'br-+' tailscale0; do iptables -A AGENTOS-DOCKER -i "$i" -j RETURN; done
iptables -A AGENTOS-DOCKER -j DROP
iptables -C DOCKER-USER -j AGENTOS-DOCKER 2>/dev/null || iptables -I DOCKER-USER -j AGENTOS-DOCKER
# ponytail: IPv4 only; Docker's IPv6 is off by default. Mirror with ip6tables if ip6 is enabled in daemon.json.
```

`mkosi.extra/etc/systemd/system/docker.service.d/10-agentos.conf`:
```ini
[Service]
ExecStartPost=/usr/local/lib/agentos/docker-user.sh
```

- [ ] **Step 4: sysctl and unattended-upgrades**

`mkosi.extra/etc/sysctl.d/90-agentos.conf`:
```
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
```

`mkosi.extra/etc/apt/apt.conf.d/20auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

`mkosi.extra/etc/apt/apt.conf.d/52agentos-unattended`:
```
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Tailscale";
        "origin=Docker";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```
Before building, confirm the `origin=` values. On the running test VM, run `vm 'sudo apt-get update -qq; apt-cache policy | grep -E "o=(Tailscale|Docker)"'`. If either origin string differs, use the printed `o=` value.

Add `unattended-upgrades` to the `Packages=` list in `mkosi.conf.d/10-base.conf`. Append to the preset file:
```
enable agentos-firewall.service
enable apt-daily.timer
enable apt-daily-upgrade.timer
enable unattended-upgrades.service
```

- [ ] **Step 5: Build and test**

```bash
chmod +x mkosi.extra/usr/local/sbin/agentos-firewall mkosi.extra/usr/local/lib/agentos/docker-user.sh
shellcheck mkosi.extra/usr/local/sbin/* mkosi.extra/usr/local/lib/agentos/*.sh
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `ALL CHECKS PASSED`. SSH still works because the seed sets `AGENTOS_LAN_SSH=1`.

- [ ] **Step 6: Commit**

```bash
git add mkosi.conf.d/10-base.conf mkosi.extra test/checks/60-network.sh
git commit -m "feat: tailnet-only firewall, docker exposure guard, sysctl hardening, security auto-updates"
```

---

### Task 7: `agentos-config`, console mode and lockout prevention

**Files:**
- Create: `mkosi.extra/usr/local/bin/agentos-config`, `mkosi.extra/usr/local/sbin/agentos-console-apply`, `mkosi.extra/usr/local/sbin/agentos-config-tty`, `mkosi.extra/etc/issue`
- Modify: `mkosi.extra/usr/local/sbin/agentos-firstboot` (append), `mkosi.extra/etc/profile.d/agentos.sh` (append), `mkosi.conf.d/10-base.conf` (add `cage`, `foot`, `fonts-dejavu-core`)
- Create: `test/checks/70-config.sh`

**Interfaces:**
- Consumes: `env.sh` (Task 5), `agentos-firstboot` (Task 5), `agentos-firewall` (Task 6).
- Produces the `agentos-config` CLI. Plan 3's installer writes the same files directly, and Plan 2 adds menu items.
  - `agentos-config` with no args opens the whiptail menu.
  - `agentos-config set KEY VALUE` writes to `agentos.env`, or to secrets for secret keys.
  - `agentos-config get KEY` refuses secret keys (exit 3).
  - `agentos-config add-ssh-key "<pubkey>"`
  - `agentos-config github-keys <user>`
  - `agentos-config password`
  - `agentos-config apply` re-runs firstboot.
  - `agentos-config show-mcp-token`
- Produces `agentos-console-apply`. It manages `/etc/systemd/system/getty@tty1.service.d/agentos.conf`:
  - present (autologin into `agentos-config-tty`) only when no access is configured;
  - absent otherwise.

- [ ] **Step 1: Write the failing checks**

`test/checks/70-config.sh`:
```bash
# shellcheck shell=bash
check_config_set_get() {
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 4 && test "$(sudo agentos-config get AGENTOS_MAX_DESKTOPS)" = 4'
}
check_config_secret_routed() {
  vm 'sudo agentos-config set OPENAI_API_KEY sk-o-test &&
      grep -qx OPENAI_API_KEY=sk-o-test ~/.config/agentos/secrets.env &&
      ! sudo grep -q OPENAI_API_KEY /etc/agentos/agentos.env'
}
check_config_get_refuses_secret() { vm '! sudo agentos-config get OPENAI_API_KEY 2>/dev/null'; }
check_config_rejects_bad_key()    { vm '! sudo agentos-config set bad-key x 2>/dev/null'; }
check_add_ssh_key() {
  vm 'k="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestOnly0000000000000000000000 t@t";
      sudo agentos-config add-ssh-key "$k" && grep -qF "$k" ~/.ssh/authorized_keys &&
      sudo agentos-config add-ssh-key "$k" && test "$(grep -cF "$k" ~/.ssh/authorized_keys)" = 1'
}
check_mcp_token_shown() { vm 'test "$(sudo agentos-config show-mcp-token)" = "$(sudo cat /etc/agentos/mcp-token)"'; }
check_no_autologin_when_key_present() {
  vm 'sudo agentos-console-apply && test ! -e /etc/systemd/system/getty@tty1.service.d/agentos.conf'
}
check_autologin_when_no_access() {
  vm 'mv ~/.ssh/authorized_keys ~/.ssh/ak.bak
      sudo agentos-console-apply; r=0; test -e /etc/systemd/system/getty@tty1.service.d/agentos.conf || r=1
      mv ~/.ssh/ak.bak ~/.ssh/authorized_keys; sudo agentos-console-apply
      test ! -e /etc/systemd/system/getty@tty1.service.d/agentos.conf && exit $r'
}
check_terminal_mode_profile() { vm 'grep -q "cage -- foot" /etc/profile.d/agentos.sh && command -v cage && command -v foot'; }
check_issue_banner()          { vm 'grep -q "agentos-config" /etc/issue'; }
```

```bash
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: the new checks FAIL.

- [ ] **Step 2: Implement `agentos-config`**

`mkosi.extra/usr/local/bin/agentos-config`:
```bash
#!/bin/bash
# AgentOS configuration: whiptail menu (no args) or scriptable subcommands.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
. /usr/local/lib/agentos/env.sh

AK=/home/agent/.ssh/authorized_keys

cmd_set() {
  if is_secret_key "$1"; then
    install -d -o agent -g agent -m 700 /home/agent/.config/agentos
    env_set "$AGENTOS_SECRETS" "$1" "$2"; chown agent:agent "$AGENTOS_SECRETS"; chmod 600 "$AGENTOS_SECRETS"
  else
    env_set "$AGENTOS_ENV" "$1" "$2"
  fi
}
cmd_get() {
  is_secret_key "$1" && { echo "refusing to print secret $1" >&2; exit 3; }
  env_get "$AGENTOS_ENV" "$1"
}
cmd_add_ssh_key() {
  [[ $1 =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/=]+ ]] \
    || { echo "not an SSH public key" >&2; exit 2; }
  install -d -o agent -g agent -m 700 /home/agent/.ssh
  touch "$AK"; grep -qxF "$1" "$AK" || printf '%s\n' "$1" >> "$AK"
  chown agent:agent "$AK"; chmod 600 "$AK"
}
cmd_github_keys() {
  [[ $1 =~ ^[A-Za-z0-9-]{1,39}$ ]] || { echo "invalid GitHub username" >&2; exit 2; }
  local keys; keys=$(curl -fsS --max-time 15 "https://github.com/$1.keys")
  [ -n "$keys" ] || { echo "no public keys for GitHub user $1" >&2; exit 1; }
  while IFS= read -r k; do cmd_add_ssh_key "$k"; done <<< "$keys"
}
cmd_apply() { /usr/local/sbin/agentos-firstboot; }

menu() {
  while true; do
    local c
    c=$(whiptail --title "AgentOS configuration" --menu "Choose a setting" 22 72 12 \
      password  "Set password for 'agent' (console + sudo)" \
      sshkey    "Add an SSH public key" \
      github    "Import SSH keys from a GitHub username" \
      tailscale "Tailscale auth key" \
      apikeys   "API keys / OAuth token" \
      lanssh    "Allow SSH from LAN (no Tailscale)" \
      console   "Local console: headless or terminal" \
      reboot    "Auto-reboot for kernel security updates" \
      mcptoken  "Show MCP HTTP bearer token" \
      done      "Apply and exit" 3>&1 1>&2 2>&3) || c=done
    case $c in
      password)  passwd agent || true ;;
      sshkey)    k=$(whiptail --inputbox "Paste SSH public key" 10 72 3>&1 1>&2 2>&3) && cmd_add_ssh_key "$k" || true ;;
      github)    u=$(whiptail --inputbox "GitHub username" 10 60 3>&1 1>&2 2>&3) && cmd_github_keys "$u" || true ;;
      tailscale) whiptail --msgbox "Use a TAGGED, pre-approved auth key (tag:agentos) so this machine cannot reach your other devices. See docs/tailscale-acl.md." 12 72
                 k=$(whiptail --passwordbox "Tailscale auth key (tskey-auth-...)" 10 72 3>&1 1>&2 2>&3) && [ -n "$k" ] && cmd_set TS_AUTHKEY "$k" || true ;;
      apikeys)   whiptail --msgbox "Use a dedicated, spend-capped key per AgentOS machine: a hijacked agent can read any key stored here." 10 72
                 for n in ANTHROPIC_API_KEY OPENAI_API_KEY GROK_CODE_XAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
                   v=$(whiptail --passwordbox "$n (empty = keep current)" 10 72 3>&1 1>&2 2>&3) || break
                   [ -n "$v" ] && cmd_set "$n" "$v"
                 done ;;
      lanssh)    if whiptail --yesno "Open SSH (key-only) on all interfaces?" 8 60; then cmd_set AGENTOS_LAN_SSH 1; else cmd_set AGENTOS_LAN_SSH 0; fi ;;
      console)   m=$(whiptail --menu "Local console mode" 12 60 2 headless "Status + login prompt" terminal "Full-screen terminal after login" 3>&1 1>&2 2>&3) && cmd_set AGENTOS_CONSOLE "$m" || true ;;
      reboot)    if whiptail --yesno "Reboot automatically at 04:00 when a kernel update requires it?" 8 70; then cmd_set AGENTOS_AUTO_REBOOT 1; else cmd_set AGENTOS_AUTO_REBOOT 0; fi ;;
      mcptoken)  whiptail --msgbox "$(cat /etc/agentos/mcp-token)" 8 72 ;;
      done)      cmd_apply || whiptail --msgbox "Some settings failed to apply (see: journalctl -u agentos-firstboot). Tailscale key wrong?" 9 72
                 return ;;
    esac
  done
}

case "${1:-}" in
  "")              menu ;;
  set)             [ $# -eq 3 ] || { echo "usage: agentos-config set KEY VALUE" >&2; exit 2; }; cmd_set "$2" "$3" ;;
  get)             [ $# -eq 2 ] || { echo "usage: agentos-config get KEY" >&2; exit 2; }; cmd_get "$2" ;;
  add-ssh-key)     cmd_add_ssh_key "${2:?usage: agentos-config add-ssh-key '<pubkey>'}" ;;
  github-keys)     cmd_github_keys "${2:?usage: agentos-config github-keys <user>}" ;;
  password)        passwd agent ;;
  apply)           cmd_apply ;;
  show-mcp-token)  cat /etc/agentos/mcp-token ;;
  *)               echo "usage: agentos-config [set KEY VALUE|get KEY|add-ssh-key KEY|github-keys USER|password|apply|show-mcp-token]" >&2; exit 2 ;;
esac
```

Create `docs/tailscale-acl.md`, which the menu references:
````markdown
# Tailscale ACL for AgentOS

Use a tagged, pre-approved auth key with `tag:agentos`. Add to your tailnet policy:

```json
{
  "tagOwners": { "tag:agentos": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos:22,6080,8765"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos"], "users": ["agent"] }
  ]
}
```

No rule lets `tag:agentos` initiate connections to other tailnet devices, so a hijacked agent can't reach them. Internet egress is unaffected.
````

- [ ] **Step 3: Implement console handling**

`mkosi.extra/usr/local/sbin/agentos-config-tty`:
```bash
#!/bin/bash
# tty1 login program while no access method is configured: run the config menu, never a shell.
set -euo pipefail
export TERM=linux
clear
echo "AgentOS has no way to log in yet (no password, SSH key, or Tailscale)."
echo "Configure access now. This screen returns until one is set."
sleep 2
/usr/local/bin/agentos-config || true
/usr/local/sbin/agentos-console-apply
```

`mkosi.extra/usr/local/sbin/agentos-console-apply`:
```bash
#!/bin/bash
# Decide tty1 behaviour: autologin into agentos-config only when no access method exists.
set -euo pipefail
DROPIN=/etc/systemd/system/getty@tty1.service.d/agentos.conf

has_access() {
  [ -s /home/agent/.ssh/authorized_keys ] && return 0
  [[ $(passwd -S agent | awk '{print $2}') == P ]] && return 0
  tailscale status >/dev/null 2>&1 && return 0
  return 1
}

if has_access; then
  [ -e "$DROPIN" ] || exit 0
  rm -f "$DROPIN"
else
  [ -e "$DROPIN" ] && exit 0
  install -d "$(dirname "$DROPIN")"
  cat > "$DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --skip-login --nonewline --noissue --login-program /usr/local/sbin/agentos-config-tty %I $TERM
EOF
fi
systemctl daemon-reload
systemctl restart getty@tty1.service || true
```

Append to `mkosi.extra/usr/local/sbin/agentos-firstboot`, as the last line **before** the `# 5. Tailscale` block:
```bash
# 4c. Console: lockout prevention (re-evaluated after Tailscale by agentos-config-tty / next boot)
/usr/local/sbin/agentos-console-apply
```

Append to `mkosi.extra/etc/profile.d/agentos.sh`:
```bash
# AgentOS: terminal console mode — full-screen terminal on tty1 after login.
if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ "$(id -un)" = agent ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
   grep -qx 'AGENTOS_CONSOLE=terminal' /etc/agentos/console.mode 2>/dev/null; then
  exec cage -- foot -e tmux new -A -s main
fi
```

`agentos.env` is root-only, so firstboot publishes the console mode to a world-readable file. Append to `agentos-firstboot`, next to step 4c:
```bash
printf 'AGENTOS_CONSOLE=%s\n' "$(env_get "$AGENTOS_ENV" AGENTOS_CONSOLE | grep -x terminal || echo headless)" > /etc/agentos/console.mode
chmod 644 /etc/agentos/console.mode
chmod 711 /etc/agentos
```
Also change the first `install -d -m 700 /etc/agentos` in `agentos-firstboot` to `install -d -m 711 /etc/agentos`. The directory stays non-listable, `agentos.env` and `mcp-token` stay 0600, and `console.mode` becomes readable.

`mkosi.extra/etc/issue`:
```
AgentOS \n  —  \4  (tailnet: \4{tailscale0})

Configure: sudo agentos-config    Update: agentos-update

```

Add to the `Packages=` list in `mkosi.conf.d/10-base.conf`:
```
        cage
        foot
        fonts-dejavu-core
```

- [ ] **Step 4: Build and test**

```bash
chmod +x mkosi.extra/usr/local/bin/agentos-config mkosi.extra/usr/local/sbin/agentos-console-apply mkosi.extra/usr/local/sbin/agentos-config-tty
shellcheck mkosi.extra/usr/local/bin/* mkosi.extra/usr/local/sbin/* mkosi.extra/usr/local/lib/agentos/*.sh
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Manual console check (once, UEFI)**

Boot with a seed that has **no** `ssh_authorized_keys`, using a visible display:
```bash
qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/tmp/vars.fd -drive file=/tmp/manual.qcow2,if=virtio -vga std
```
(Prepare `/tmp/vars.fd` and `/tmp/manual.qcow2` as `smoke.sh` does, but without a seed.)

Expected:
- tty1 shows the "no way to log in yet" message and then the menu.
- After you set a password and choose "Apply and exit", tty1 shows the `/etc/issue` banner and a normal login prompt.
- After `sudo agentos-config set AGENTOS_CONSOLE terminal && sudo agentos-config apply`, logging in on tty1 opens a full-screen foot terminal running tmux.

- [ ] **Step 6: Commit**

```bash
git add mkosi.conf.d/10-base.conf mkosi.extra docs/tailscale-acl.md test/checks/70-config.sh
git commit -m "feat: agentos-config TUI/CLI, terminal console mode, lockout prevention"
```

---

### Task 8: Size trimming, size budget and `agentos-update`

**Files:**
- Create: `mkosi.skeleton/etc/dpkg/dpkg.cfg.d/01-agentos-nodoc`, `mkosi.extra/usr/local/bin/agentos-update`
- Modify: `mkosi.conf` (add `mkosi.skeleton` to `SkeletonTrees=`)
- Create: `test/checks/80-size-update.sh`

**Interfaces:**
- Produces `agentos-update`: runs `apt upgrade`, then each CLI's updater, then rustup and bun. It exits non-zero if any step failed and prints a summary line per step.

- [ ] **Step 1: Write the failing checks**

`test/checks/80-size-update.sh`:
```bash
# shellcheck shell=bash
check_root_size_budget() {
  local used; used=$(vm 'df --output=used -BM / | tail -1 | tr -dc 0-9')
  echo "root used: ${used} MiB (budget 4608)"; [ "$used" -le 4608 ]
}
check_no_foreign_locales() { vm 'test -z "$(ls /usr/share/locale | grep -vE "^(en|en_US|en_GB|locale.alias)$")"'; }
check_no_man_pages()       { vm 'test -z "$(find /usr/share/man -type f -name "*.gz" 2>/dev/null | head -1)"'; }
check_agentos_update()     { vm 'agentos-update' ; }
```

```bash
test/smoke.sh mkosi.output/agentos.raw uefi
```
Expected: `check_no_foreign_locales` and `check_agentos_update` FAIL. Record the `root used:` number printed by `check_root_size_budget`.

- [ ] **Step 2: Trim docs, man pages and locales at install time**

`mkosi.skeleton/etc/dpkg/dpkg.cfg.d/01-agentos-nodoc`:
```
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*
path-include=/usr/share/locale/locale.alias
path-exclude=/usr/share/lintian/*
```

In `mkosi.conf`, change:
```ini
SkeletonTrees=apt:/etc/apt
```
to:
```ini
SkeletonTrees=apt:/etc/apt
              mkosi.skeleton
```

- [ ] **Step 3: Implement `agentos-update`**

`mkosi.extra/usr/local/bin/agentos-update`:
```bash
#!/bin/bash
# Update OS packages and every agent CLI/toolchain. Manual by design: never mid-task.
set -uo pipefail
[ "$(id -un)" = agent ] || { echo "run as the agent user" >&2; exit 2; }
# shellcheck source=/dev/null
. /etc/profile.d/agentos.sh

FAILED=0
step() {  # step <label> <command...>
  local label=$1; shift
  if "$@" >/tmp/agentos-update.log 2>&1; then echo "ok    $label"
  else echo "FAIL  $label (see below)"; tail -5 /tmp/agentos-update.log | sed 's/^/      /'; FAILED=1; fi
}

step "apt"      sudo bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -y -qq upgrade'
step "claude"   claude update
step "codex"    npm install -g @openai/codex@latest
step "opencode" opencode upgrade
step "grok"     bash -c 'grok update 2>/dev/null || curl -fsSL https://x.ai/cli/install.sh | bash'
step "rustup"   rustup update
step "bun"      bun upgrade
step "playwright" bash -c 'npm install -g playwright@latest && playwright install chromium'
exit $FAILED
```

- [ ] **Step 4: Build and test**

```bash
chmod +x mkosi.extra/usr/local/bin/agentos-update && shellcheck mkosi.extra/usr/local/bin/agentos-update
mkosi -f build && test/smoke.sh mkosi.output/agentos.raw uefi bios
```
Expected: `ALL CHECKS PASSED`, with `root used:` ≤ 4608 MiB. If the budget is exceeded, run this in the VM to find the largest directories:
```bash
vm 'sudo du -xh / --max-depth=3 2>/dev/null | sort -h | tail -25'
```
Fix only by removing caches or docs (add to `RemoveFiles=`). Never remove a spec'd component. If the budget still can't be met, stop and report the numbers.

- [ ] **Step 5: Commit**

```bash
git add mkosi.conf mkosi.skeleton mkosi.extra/usr/local/bin/agentos-update test/checks/80-size-update.sh
git commit -m "feat: doc/locale trimming, 4.5 GB size budget, agentos-update"
```

---

### Task 9: CI build, conversions, release and weekly rebuild

**Files:**
- Create: `.github/workflows/build.yml`, `tools/convert.sh`

**Interfaces:**
- Consumes: `mkosi.output/agentos.raw`, `/var/lib/agentos-manifest.txt` inside the image, and `test/smoke.sh`.
- Produces the release assets: `agentos-<ver>.raw.zst`, `.qcow2`, `.vhdx.zst`, `.vmdk.zst`, `MANIFEST.txt`, `SHA256SUMS`, plus build-provenance attestations. Plan 3 adds `agentos-installer-<ver>.img.zst` to the same release.

- [ ] **Step 1: Write the conversion script and test it locally**

`tools/convert.sh`:
```bash
#!/bin/bash
# Convert agentos.raw into all release formats + manifest + checksums.
set -euo pipefail
RAW=${1:?usage: convert.sh <agentos.raw> <version> <outdir>}; VER=${2:?}; OUT=${3:?}
mkdir -p "$OUT"
base="$OUT/agentos-$VER"

qemu-img convert -c -O qcow2 "$RAW" "$base.qcow2"
qemu-img convert -O vhdx -o subformat=dynamic "$RAW" "$base.vhdx"
qemu-img convert -O vmdk -o subformat=streamOptimized "$RAW" "$base.vmdk"
zstd -q -T0 -19 --rm "$base.vhdx" "$base.vmdk"
zstd -q -T0 -19 -o "$base.raw.zst" "$RAW"

# Manifest from the image's root partition
loop=$(sudo losetup --find --show --partscan "$RAW")
trap 'sudo umount /mnt/agentos-root 2>/dev/null || true; sudo losetup -d "$loop"' EXIT
root=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk 'tolower($2) ~ /root/ {print $1; exit}')
sudo mkdir -p /mnt/agentos-root && sudo mount -o ro "$root" /mnt/agentos-root
cp /mnt/agentos-root/var/lib/agentos-manifest.txt "$OUT/MANIFEST.txt"

(cd "$OUT" && sha256sum agentos-* MANIFEST.txt > SHA256SUMS)
ls -lh "$OUT"
```

```bash
chmod +x tools/convert.sh && shellcheck tools/convert.sh
tools/convert.sh mkosi.output/agentos.raw test /tmp/release
grep -c . /tmp/release/MANIFEST.txt && cat /tmp/release/SHA256SUMS
```
Expected: 4 image files, plus `MANIFEST.txt` (several hundred lines, ending with the `# agent CLIs` section) and `SHA256SUMS`.

- [ ] **Step 2: Write the workflow**

`.github/workflows/build.yml`:
```yaml
name: build
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
  schedule:
    - cron: "17 3 * * 1"   # weekly rebuild, Monday 03:17 UTC
  workflow_dispatch:

permissions:
  contents: write
  id-token: write
  attestations: write

jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4

      - name: Host setup
        run: |
          sudo apt-get update
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils pipx shellcheck zstd
          sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
          sudo chmod 666 /dev/kvm
          tag=$(git ls-remote --tags --sort=-v:refname https://github.com/systemd/mkosi 'v2*' | head -1 | sed 's#.*refs/tags/##; s#\^{}##')
          pipx install "git+https://github.com/systemd/mkosi@$tag"
          df -h /

      - name: Lint and unit tests
        run: |
          shellcheck test/smoke.sh test/checks/*.sh test/env_test.sh tools/*.sh mkosi.prepare.chroot mkosi.finalize.chroot \
            mkosi.extra/usr/local/bin/* mkosi.extra/usr/local/sbin/* mkosi.extra/usr/local/lib/agentos/*.sh
          test/env_test.sh

      - name: Build image
        run: mkosi -f build

      - name: Smoke test (UEFI + BIOS)
        run: test/smoke.sh mkosi.output/agentos.raw uefi bios

      - name: Version
        id: ver
        run: |
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then echo "v=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          else echo "v=$(date -u +%Y.%m.%d)" >> "$GITHUB_OUTPUT"; fi

      - name: Convert
        if: github.event_name != 'pull_request'
        run: tools/convert.sh mkosi.output/agentos.raw "${{ steps.ver.outputs.v }}" release

      - name: Attest provenance
        if: github.event_name != 'pull_request'
        uses: actions/attest-build-provenance@v2
        with:
          subject-path: "release/agentos-*"

      - name: Release
        if: startsWith(github.ref, 'refs/tags/v') || github.event_name == 'schedule'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="v${{ steps.ver.outputs.v }}"
          gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" --title "AgentOS $tag" --notes-file release/MANIFEST.txt
          gh release upload "$tag" release/* --clobber
```

If the runner runs out of disk (the build needs roughly 20 GB), add this as the first step:
```yaml
      - name: Free disk
        run: sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache
```

- [ ] **Step 3: Validate the workflow syntax locally**

```bash
pipx run check-jsonschema --builtin-schema vendor.github-workflows .github/workflows/build.yml
```
Expected: `ok -- validation done`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml tools/convert.sh
git commit -m "ci: build, smoke test, convert, attest and release AgentOS images weekly"
```

- [ ] **Step 5: Verify on GitHub**

Ask the user before pushing: the repo has no remote yet, and creating one and pushing is outward-facing. Once a remote exists:
```bash
git push -u origin HEAD
gh run watch
```
Expected: the `build` job is green, and the smoke step shows `ALL CHECKS PASSED`.

---

## Spec coverage (Plan 1)

| Spec item | Task |
|---|---|
| Debian trixie, mkosi, hybrid UEFI+BIOS, signed shim | 1 |
| Generic kernel, microcode, targeted NIC firmware, guest agents | 1 |
| `agent` user, sudo, key-only SSH hardening | 1 |
| cloud-init default user, root grow | 1 |
| machine-id / host keys / tailscale / CLI auth not baked | 2 |
| Pinned third-party apt keyrings | 3 |
| Node 24, Python, Go, Rust (minimal), Bun, Docker, JDK 21, Playwright | 3 |
| claude, codex, opencode, grok per-user + manifest | 4 |
| `agentos.env`, firstboot, secrets move, MCP token, Tailscale | 5 |
| nftables own table, LAN SSH toggle, Docker guard, sysctl, unattended-upgrades + reboot | 6 |
| `agentos-config`, lockout prevention, console mode, issue banner, Tailscale ACL doc | 7 |
| Size budget, doc/locale trimming, `agentos-update` | 8 |
| CI, conversions, SHA256SUMS, attestations, weekly release | 9 |

Deferred to Plan 2: desktops, MCP server, noVNC, Debian `chromium`, XFCE, the MCP pre-registration in CLI configs, and the MCP/noVNC smoke checks.
Deferred to Plan 3: installer image, TUI, unattended install, autoinstall URL rules, and the installer smoke path.
