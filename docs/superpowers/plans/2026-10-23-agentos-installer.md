# AgentOS Installer Implementation Plan (Plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bootable installer image (`agentos-installer.img`, USB stick or virtual CD) that puts AgentOS on a bare-metal disk. It works interactively (a whiptail TUI on tty1) or unattended (settings from the USB's `AGENTOS` FAT partition, or an `https://` URL on the kernel command line).

**Architecture:**
- **Two mkosi projects.** The installer is a second mkosi project in `installer/`, built after the main image. It embeds `agentos.raw.zst` plus its sha256.
- **Install by copying the tested image.** The installer writes the main image to the target disk byte for byte (`zstd -dc | dd`) and moves the backup GPT to the disk end (`sgdisk -e`). That disk is already bootable on UEFI and BIOS, and grows its root partition on first boot (Plan 1). This means no partitioning or bootloader code of our own: the bare-metal result is the exact OS the smoke suite tests.
- **Settings via the target's own tool.** Settings are applied by mounting the new root and running the target's own `agentos-config` in a chroot. On top of that the installer handles the SSH key, password hash, static network and `cloud-init.disabled`.
- **Testable core.** Pure logic lives in `lib.sh` with bash unit tests. The install engine is shared by the TUI and the unattended paths.
- **End-to-end test.** An unattended install in QEMU onto a blank disk, then the *entire* existing smoke suite run against the installed disk in UEFI and BIOS.

**Tech Stack:** mkosi 27, Debian trixie, bash, whiptail, zstd, gdisk, util-linux, systemd-networkd, QEMU/OVMF, mtools (test host).

**Builds on:** Plans 1–2, merged on `master` at c39be65. Read `.superpowers/sdd/context.md` for the build host workflow (devvm, `devvm.sh`, `TMPDIR=/var/tmp`, foreground polling).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-21-agentos-design.md` Section 4 (Installer). When this plan and the spec disagree, the spec wins; stop and flag it. **Deliberate simplification versus the spec text:** the spec describes `systemd-repart --empty=force` plus `grub-install`. This plan instead writes the already-bootable, already-tested `agentos.raw` verbatim, which gives the same result (whole disk, ESP + BIOS boot + root, UEFI+BIOS, Secure Boot via signed shim, root grows at first boot) with far less code. Task 5 updates the spec text.
- The installer image is UEFI-only (`BiosBootloader=none`). It boots from USB (raw `.img` written with dd/Etcher/Rufus) and, via El Torito, as a virtual CD. The **installed** system is UEFI+BIOS.
- The installer root partition's label is `agentos-installer`, never `root-x86-64`, because the installed system mounts `PARTLABEL=root-x86-64` and the USB may still be plugged in at first boot.
- Target disk rules: a whole disk (`TYPE=disk`), not the disk the installer booted from, ≥ 32 GiB, no mounted partitions. All validation happens **before** anything is written. If anything fails after writing starts, the message says the disk was erased.
- The embedded image is verified with `sha256sum -c` before writing.
- Settings file: KEY=VALUE lines. These keys are installer-only and never written into the target's `agentos.env`: `AGENTOS_INSTALL_DISK AGENTOS_INSTALL_POWEROFF AGENTOS_SSH_KEY AGENTOS_GITHUB_USER AGENTOS_PASSWORD_HASH AGENTOS_NET_IFACE AGENTOS_NET_ADDRESS AGENTOS_NET_GATEWAY AGENTOS_NET_DNS`. Every other key goes through the target's `agentos-config set` (so secrets land in `secrets.env`).
- Passwords are only ever handled as `$6$`/`$y$` crypt hashes in files. The TUI hashes with `openssl passwd -6 -stdin`.
- Remote autoinstall: `agentos.autoinstall=<url>` must be `https://`, with optional `agentos.autoinstall_sha256=<64 hex>`. `http://` is refused.
- Unattended source precedence: kernel command line URL, then `agentos.env` on the `AGENTOS` partition containing `AGENTOS_INSTALL_DISK`. Otherwise interactive.
- Installed systems get `/etc/cloud/cloud-init.disabled` (bare metal has no datasource).
- Bash scripts: `#!/bin/bash` + `set -euo pipefail`, `shellcheck -S warning` clean. Checks in `test/checks/*.sh` use `&&` chains.
- Host tools needed for tests (devvm and CI): `mtools` (install it on devvm in Task 2 with `apt-get install -y mtools`).

## File map

```
installer/mkosi.conf                                   # installer image (separate mkosi project)
installer/mkosi.repart/{00-esp,10-root,20-data}.conf   # ESP, root (label agentos-installer), AGENTOS FAT
installer/mkosi.extra/usr/lib/agentos-installer/lib.sh # pure helpers
installer/mkosi.extra/usr/local/sbin/agentos-install   # engine + --auto + --tui
installer/mkosi.extra/usr/local/sbin/agentos-install-tty
installer/mkosi.extra/etc/systemd/system/agentos-install-auto.service
installer/mkosi.extra/etc/systemd/system/getty@tty1.service.d/agentos.conf
installer/mkosi.extra/etc/systemd/system/getty@tty2.service.d/agentos.conf
installer/mkosi.extra/etc/systemd/system/systemd-networkd-wait-online.service.d/agentos.conf
installer/mkosi.extra/etc/systemd/network/80-dhcp.network
installer/mkosi.extra/usr/lib/systemd/system-preset/10-agentos-installer.preset
installer/mkosi.extra/usr/share/agentos/data/{README.txt,agentos.env.example}
tools/build-installer.sh                                # zstd + sha256 + payload dir + mkosi -C installer
test/installer_test.sh                                 # lib.sh unit tests
test/installer-boot-test.sh                            # installer boots to READY (USB + CD)
test/install-test.sh                                   # unattended install, negative cases, smoke on installed disk
test/smoke.sh                                          # + SMOKE_DISK / SMOKE_KEY / SMOKE_NOSEED, + installed_ checks
test/checks/95-installed.sh
.github/workflows/build.yml, tools/convert.sh          # installer build, tests, release asset
```

---

### Task 1: Installer library (`lib.sh`) with unit tests

**Files:**
- Create: `installer/mkosi.extra/usr/lib/agentos-installer/lib.sh`, `test/installer_test.sh`

**Interfaces:**
- Produces `lib.sh`. It's sourced, does no I/O except stdout/stderr, and uses bash ≥ 5. It defines:
  - `INSTALLER_KEYS` (array), `MIN_DISK_BYTES` (32 GiB), `ROOT_PARTLABEL=root-x86-64`
  - `is_installer_key KEY`
  - `parse_env FILE`: prints validated `KEY=VALUE` lines, skips blank and `#` lines, strips CR, returns 2 with `line N: …` on stderr for anything else. A last line without a newline is still read.
  - `env_value KEY`: reads parsed lines on stdin and prints the last value for KEY (empty if absent). Values may contain `=`.
  - `cmdline_get NAME CMDLINE`: prints the value of `NAME=…` from a kernel command line string; returns 1 if absent
  - `valid_https_url`, `valid_sha256`, `valid_hostname`, `valid_ipv4`, `valid_cidr`, `valid_iface`, `valid_password_hash`, `valid_ssh_pubkey`: each returns 0/1
  - `network_file IFACE CIDR GATEWAY DNS_CSV`: prints a systemd-networkd `.network` file
  - `autoinstall_source CMDLINE FAT_ENV_PATH`: prints `url <URL> <SHA-or-empty>`, `file <PATH>` or `none`. Returns 2 (message on stderr) for an invalid URL or sha.

- [ ] **Step 1: Write the failing test**

`test/installer_test.sh`:
```bash
#!/bin/bash
# Unit tests for the installer's pure helpers. Run on Linux (bash 5): test/installer_test.sh
set -euo pipefail
# shellcheck source=../installer/mkosi.extra/usr/lib/agentos-installer/lib.sh
. "$(dirname "$0")/../installer/mkosi.extra/usr/lib/agentos-installer/lib.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# parse_env: comments, blanks, CRLF, values with '=', last line without newline
printf '# comment\n\nAGENTOS_HOSTNAME=x\r\nPAD_TOKEN=abc==\nLAST=1' > "$t/a.env"
[ "$(parse_env "$t/a.env")" = $'AGENTOS_HOSTNAME=x\nPAD_TOKEN=abc==\nLAST=1' ] || fail parse_env
printf 'GOOD=1\nnot a pair\n' > "$t/b.env"
if parse_env "$t/b.env" 2>"$t/err"; then fail "parse_env accepted a bad line"; fi
grep -q '^line 2:' "$t/err" || fail "parse_env error names the line"
printf 'lower=1\n' > "$t/c.env"
if parse_env "$t/c.env" 2>/dev/null; then fail "parse_env accepted a lowercase key"; fi

# env_value
[ "$(printf 'A=1\nB=x=y\nA=2\n' | env_value A)" = 2 ] || fail "env_value last wins"
[ "$(printf 'B=x=y\n' | env_value B)" = "x=y" ] || fail "env_value keeps ="
[ -z "$(printf 'A=1\n' | env_value Z)" ] || fail "env_value absent"

# installer keys
is_installer_key AGENTOS_INSTALL_DISK || fail is_installer_key
if is_installer_key AGENTOS_HOSTNAME; then fail "AGENTOS_HOSTNAME is not installer-only"; fi

# kernel command line
h64=$(printf 'a%.0s' $(seq 1 64))
cl="BOOT_IMAGE=/vmlinuz root=PARTUUID=x agentos.autoinstall=https://h.example/a.env agentos.autoinstall_sha256=$h64 quiet"
[ "$(cmdline_get agentos.autoinstall "$cl")" = "https://h.example/a.env" ] || fail cmdline_get
if cmdline_get agentos.nothere "$cl" >/dev/null; then fail "cmdline_get absent"; fi

# validators
valid_https_url "https://h.example:8443/x?y=1" || fail url1
for bad in "http://h/x" "https://h/a b" "https://" "ftp://h/x"; do
  if valid_https_url "$bad"; then fail "url accepted: $bad"; fi
done
valid_sha256 "$h64" || fail sha
if valid_sha256 ABC; then fail "sha accepted ABC"; fi
valid_hostname agentos-01 || fail hostname
for bad in -bad Bad "" "a_b" "$(printf 'a%.0s' $(seq 1 64))"; do
  if valid_hostname "$bad"; then fail "hostname accepted: $bad"; fi
done
valid_ipv4 10.0.0.1 || fail ipv4
for bad in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d; do if valid_ipv4 "$bad"; then fail "ipv4 accepted: $bad"; fi; done
valid_cidr 192.168.1.10/24 || fail cidr
for bad in 192.168.1.10 192.168.1.10/33 300.1.1.1/24; do if valid_cidr "$bad"; then fail "cidr accepted: $bad"; fi; done
valid_iface enp3s0 || fail iface
for bad in "en p" averyveryverylongname ""; do if valid_iface "$bad"; then fail "iface accepted: $bad"; fi; done
valid_password_hash '$6$salt$hash' || fail hash6
valid_password_hash '$y$j9T$a$b' || fail hashy
for bad in plain '$1$x$y' '$6$a b'; do if valid_password_hash "$bad"; then fail "hash accepted: $bad"; fi; done
valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake test@x" || fail sshkey
for bad in "$(printf 'ssh-ed25519 AAAA a\ncommand="x" ssh-ed25519 AAAA b')" 'command="x" ssh-ed25519 AAAA' "ssh-dss AAAA"; do
  if valid_ssh_pubkey "$bad"; then fail "ssh key accepted: $bad"; fi
done

# network_file
nf=$(network_file enp1s0 10.0.0.5/24 10.0.0.1 1.1.1.1,9.9.9.9)
for want in "[Match]" "Name=enp1s0" "[Network]" "Address=10.0.0.5/24" "Gateway=10.0.0.1" "DNS=1.1.1.1" "DNS=9.9.9.9"; do
  grep -qxF "$want" <<< "$nf" || fail "network_file missing $want"
done
[ "$(network_file e0 10.0.0.5/24 10.0.0.1 "" | grep -c '^DNS=')" = 0 ] || fail "network_file empty DNS"

# autoinstall_source
[ "$(autoinstall_source "$cl" "")" = "url https://h.example/a.env $h64" ] || fail "source url"
[ "$(autoinstall_source "agentos.autoinstall=https://h/x" "")" = "url https://h/x " ] || fail "source url no sha"
if autoinstall_source "agentos.autoinstall=http://h/x" "" 2>/dev/null; then fail "source accepted http"; fi
if autoinstall_source "agentos.autoinstall=https://h/x agentos.autoinstall_sha256=zz" "" 2>/dev/null; then fail "source accepted bad sha"; fi
printf 'AGENTOS_INSTALL_DISK=/dev/vdb\n' > "$t/fat.env"
[ "$(autoinstall_source "quiet" "$t/fat.env")" = "file $t/fat.env" ] || fail "source fat"
printf 'AGENTOS_HOSTNAME=x\n' > "$t/fat2.env"
[ "$(autoinstall_source "quiet" "$t/fat2.env")" = none ] || fail "source fat without disk"
[ "$(autoinstall_source "quiet" "$t/missing.env")" = none ] || fail "source none"
[ "$(autoinstall_source "agentos.autoinstall=https://h/x" "$t/fat.env" | cut -d' ' -f1)" = url ] || fail "url wins over fat"

echo "installer lib OK"
```

- [ ] **Step 2: Run to confirm failure**

Run: `chmod +x test/installer_test.sh && .superpowers/sdd/devvm.sh sh 'test/installer_test.sh'`
Expected: FAIL, because `lib.sh` doesn't exist (`No such file or directory`).

- [ ] **Step 3: Implement**

`installer/mkosi.extra/usr/lib/agentos-installer/lib.sh`:
```bash
# shellcheck shell=bash
# AgentOS installer: pure helpers (stdout/stderr only). Sourced by agentos-install and test/installer_test.sh.

INSTALLER_KEYS=(AGENTOS_INSTALL_DISK AGENTOS_INSTALL_POWEROFF AGENTOS_SSH_KEY AGENTOS_GITHUB_USER
                AGENTOS_PASSWORD_HASH AGENTOS_NET_IFACE AGENTOS_NET_ADDRESS AGENTOS_NET_GATEWAY AGENTOS_NET_DNS)
MIN_DISK_BYTES=$((32 * 1024 * 1024 * 1024))
ROOT_PARTLABEL=root-x86-64

is_installer_key() {
  local k
  for k in "${INSTALLER_KEYS[@]}"; do [ "$k" = "$1" ] && return 0; done
  return 1
}

parse_env() {
  local n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[A-Z_][A-Z0-9_]*= ]] || { echo "line $n: expected KEY=VALUE" >&2; return 2; }
    printf '%s\n' "$line"
  done < "$1"
}

env_value() {
  local line v=""
  while IFS= read -r line; do [ "${line%%=*}" = "$1" ] && v=${line#*=}; done
  printf '%s' "$v"
}

cmdline_get() {
  local w
  for w in $2; do [[ $w == "$1="* ]] && { printf '%s' "${w#*=}"; return 0; }; done
  return 1
}

valid_https_url()     { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]]; }
valid_sha256()        { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
valid_hostname()      { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_iface()         { [[ $1 =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
valid_password_hash() { [[ $1 =~ ^\$(6|y)\$[^:[:space:]]+$ ]]; }
valid_ipv4() {
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local o IFS=.
  for o in $1; do [ "$((10#$o))" -le 255 ] || return 1; done
}
valid_cidr() { [[ $1 == */* ]] && valid_ipv4 "${1%/*}" && [[ ${1#*/} =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]; }
# Keep in sync with cmd_add_ssh_key in mkosi.extra/usr/local/bin/agentos-config (the target re-validates).
valid_ssh_pubkey() {
  [[ $1 != *$'\n'* && $1 != *$'\r'* ]] &&
  [[ $1 =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]]
}

network_file() {
  printf '[Match]\nName=%s\n\n[Network]\nAddress=%s\nGateway=%s\n' "$1" "$2" "$3"
  local d
  for d in ${4//,/ }; do printf 'DNS=%s\n' "$d"; done
}

autoinstall_source() {
  local url sha
  if url=$(cmdline_get agentos.autoinstall "$1"); then
    valid_https_url "$url" || { echo "agentos.autoinstall must be an https:// URL" >&2; return 2; }
    sha=$(cmdline_get agentos.autoinstall_sha256 "$1") || sha=""
    [ -z "$sha" ] || valid_sha256 "$sha" || { echo "agentos.autoinstall_sha256 must be 64 lowercase hex chars" >&2; return 2; }
    printf 'url %s %s\n' "$url" "$sha"
    return 0
  fi
  if [ -n "$2" ] && [ -f "$2" ] && grep -q '^AGENTOS_INSTALL_DISK=' "$2"; then
    printf 'file %s\n' "$2"
    return 0
  fi
  echo none
}
```

- [ ] **Step 4: Run to confirm it passes**

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning test/installer_test.sh installer/mkosi.extra/usr/lib/agentos-installer/lib.sh && test/installer_test.sh'`
Expected: `installer lib OK`

- [ ] **Step 5: Commit**

```bash
git add installer/mkosi.extra/usr/lib/agentos-installer/lib.sh test/installer_test.sh
git commit -m "feat: installer helper library with unit tests"
```

---

### Task 2: Installer image that boots to READY (USB and CD)

**Files:**
- Create: `installer/mkosi.conf`, `installer/mkosi.repart/00-esp.conf`, `installer/mkosi.repart/10-root.conf`, `installer/mkosi.repart/20-data.conf`, `tools/build-installer.sh`, `test/installer-boot-test.sh`
- Create: `installer/mkosi.extra/usr/local/sbin/agentos-install` (minimal; Task 3 completes it), `installer/mkosi.extra/etc/systemd/system/agentos-install-auto.service`, `installer/mkosi.extra/etc/systemd/network/80-dhcp.network`, `installer/mkosi.extra/etc/systemd/system/systemd-networkd-wait-online.service.d/agentos.conf`, `installer/mkosi.extra/usr/lib/systemd/system-preset/10-agentos-installer.preset`, `installer/mkosi.extra/usr/share/agentos/data/README.txt`, `installer/mkosi.extra/usr/share/agentos/data/agentos.env.example`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `mkosi.output/agentos.raw` (Plan 1 build); `lib.sh` (Task 1).
- Produces: `tools/build-installer.sh`, which builds `mkosi.output/agentos-installer.raw` from an existing `mkosi.output/agentos.raw`.
- Produces: the installer image layout:
  - `/usr/share/agentos/agentos.raw.zst` plus `agentos.raw.zst.sha256` (relative filename inside);
  - partitions ESP, root (PARTLABEL `agentos-installer`), and FAT `AGENTOS` (PARTLABEL and fs label `AGENTOS`, holding README.txt and agentos.env.example).
- Produces: at boot, `agentos-install-auto.service` runs `agentos-install --auto`. With no unattended config, it prints `AGENTOS-INSTALLER READY (interactive)` to the console (serial in tests).
- Produces: `test/installer-boot-test.sh <agentos-installer.raw>`. It boots the image as a USB disk (and as a CD when El Torito is present) and greps the serial log for READY.

- [ ] **Step 1: Write the failing test**

`test/installer-boot-test.sh`:
```bash
#!/bin/bash
# Boot the installer image (UEFI) as a USB disk and as a CD; each must print the READY marker.
set -euo pipefail
INST=$(realpath "${1:?usage: installer-boot-test.sh <agentos-installer.raw>}")
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d); trap 'pkill -F "$WORK/q.pid" 2>/dev/null || true; rm -rf "$WORK"' EXIT
FAILS=0

boot_until() {  # boot_until <label> <marker> <qemu drive args...>
  local label=$1 marker=$2; shift 2
  cp "$OVMF_VARS" "$WORK/vars.fd"; : > "$WORK/serial.log"
  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    "$@" -nic user,model=virtio-net-pci -display none -serial "file:$WORK/serial.log" \
    -daemonize -pidfile "$WORK/q.pid"
  for _ in $(seq 1 90); do grep -q "$marker" "$WORK/serial.log" && break; sleep 2; done
  pkill -F "$WORK/q.pid" 2>/dev/null || true; sleep 1
  if grep -q "$marker" "$WORK/serial.log"; then echo "PASS [$label] $marker"
  else echo "FAIL [$label] no '$marker'; serial tail:"; tail -30 "$WORK/serial.log"; FAILS=$((FAILS + 1)); fi
}

boot_until usb "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,if=virtio,readonly=on"
if [ "${SKIP_CD:-0}" != 1 ]; then
  boot_until cd "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,media=cdrom,readonly=on"
fi
[ "$FAILS" -eq 0 ] && echo "INSTALLER BOOT OK" || { echo "$FAILS FAILURE(S)"; exit 1; }
```

Run: `chmod +x test/installer-boot-test.sh && .superpowers/sdd/devvm.sh sh 'test/installer-boot-test.sh mkosi.output/agentos-installer.raw; echo rc=$?'`
Expected: fails (`realpath` can't find `agentos-installer.raw`).

- [ ] **Step 2: Build script and payload wiring**

`tools/build-installer.sh`:
```bash
#!/bin/bash
# Build mkosi.output/agentos-installer.raw from an already built mkosi.output/agentos.raw.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f mkosi.output/agentos.raw ] || { echo "build agentos.raw first: mkosi -f build" >&2; exit 1; }
p=mkosi.output/installer-payload/usr/share/agentos
mkdir -p "$p"
zstd -q -T0 -10 -f mkosi.output/agentos.raw -o "$p/agentos.raw.zst"
(cd "$p" && sha256sum agentos.raw.zst > agentos.raw.zst.sha256)
mkosi -C installer -f build
ls -lh mkosi.output/agentos-installer.raw
```

Append to `.gitignore`:
```
mkosi.output/installer-payload/
installer/mkosi.cache/
installer/mkosi.tools/
```

- [ ] **Step 3: Installer mkosi project**

`installer/mkosi.conf`:
```ini
[Distribution]
Distribution=debian
Release=trixie
Architecture=x86-64
Repositories=main,contrib,non-free,non-free-firmware

[Output]
ImageId=agentos-installer
Format=disk
OutputDirectory=../mkosi.output
ElTorito=yes

[Build]
ToolsTree=default

[Content]
Bootable=yes
Bootloader=grub-signed
ShimBootloader=signed
UnifiedKernelImages=none
BiosBootloader=none
KernelCommandLine=console=ttyS0 console=tty0
Hostname=agentos-installer
Locale=C.UTF-8
Timezone=UTC
Ssh=never
WithDocs=no
WithRecommends=no
ExtraTrees=../mkosi.output/installer-payload
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
        grub-efi-amd64-bin
        grub-efi-amd64-signed
        shim-signed
        whiptail
        zstd
        gdisk
        util-linux
        e2fsprogs
        dosfstools
        curl
        ca-certificates
        openssl
        iproute2
        passwd
        kmod
        less
```
Notes for the implementer:
- `ElTorito=` needs systemd-repart ≥ v261 in the tools tree. If mkosi rejects it or the CD boot fails, set `ElTorito=no`, run the boot test with `SKIP_CD=1`, and report the exact error. In that case the virtual-CD path becomes a documented limitation for the controller to raise with the user; the USB path must still work.
- If building a second default tools tree is slow, `ToolsTree=` may point at the main project's existing tools tree directory (check `mkosi summary` in the repo root for its location). Report what you used.

`installer/mkosi.repart/00-esp.conf`:
```ini
[Partition]
Type=esp
Format=vfat
CopyFiles=/boot:/
CopyFiles=/efi:/
SizeMinBytes=512M
SizeMaxBytes=512M
```

`installer/mkosi.repart/10-root.conf`:
```ini
# Label must NOT be root-x86-64: installed systems mount PARTLABEL=root-x86-64 and the stick may still be plugged in.
[Partition]
Type=root
Label=agentos-installer
Format=ext4
CopyFiles=/
Minimize=guess
```

`installer/mkosi.repart/20-data.conf`:
```ini
# FAT "basic data" partition, editable from Windows/macOS/Linux after flashing: put agentos.env here.
[Partition]
Type=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7
Label=AGENTOS
Format=vfat
CopyFiles=/usr/share/agentos/data:/
SizeMinBytes=32M
SizeMaxBytes=32M
```
If repart doesn't set the vfat filesystem label from `Label=`, that's fine: the installer finds the partition by PARTLABEL (`/dev/disk/by-partlabel/AGENTOS`). Report what you observed.

- [ ] **Step 4: Minimal `agentos-install`, auto service and networking**

`installer/mkosi.extra/usr/local/sbin/agentos-install` (minimal version; Task 3 replaces it with the full engine):
```bash
#!/bin/bash
# AgentOS installer. Task 2 version: --auto detects unattended config and otherwise reports READY.
set -euo pipefail
. /usr/lib/agentos-installer/lib.sh
DATA_DEV=/dev/disk/by-partlabel/AGENTOS

auto() {
  local fat="" src
  mkdir -p /run/agentos-data
  if [ -e "$DATA_DEV" ] && mount -o ro "$DATA_DEV" /run/agentos-data 2>/dev/null; then
    fat=/run/agentos-data/agentos.env
  fi
  src=$(autoinstall_source "$(cat /proc/cmdline)" "$fat") || { echo "INSTALL FAILED: invalid autoinstall settings" >&2; exit 1; }
  if [ "$src" = none ]; then
    echo "AGENTOS-INSTALLER READY (interactive)"
    return 0
  fi
  echo "unattended install not implemented yet ($src)" >&2
  exit 1
}

case "${1:-}" in
  --auto) auto ;;
  *) echo "usage: agentos-install --auto" >&2; exit 2 ;;
esac
```

`installer/mkosi.extra/etc/systemd/system/agentos-install-auto.service`:
```ini
[Unit]
Description=AgentOS unattended install (if configured)
Wants=network-online.target
After=network-online.target systemd-udev-settle.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/agentos-install --auto
# kmsg, not console: /dev/console is tty0 (last console= on the cmdline), but kernel-log lines reach
# every console, i.e. the screen on real hardware AND the serial log the tests read.
StandardOutput=kmsg
StandardError=kmsg

[Install]
WantedBy=multi-user.target
```

`installer/mkosi.extra/etc/systemd/network/80-dhcp.network`:
```ini
[Match]
Name=en* eth*

[Network]
DHCP=yes
```

`installer/mkosi.extra/etc/systemd/system/systemd-networkd-wait-online.service.d/agentos.conf`:
```ini
# Live installer: don't stall the boot on machines with unplugged NICs.
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30
```

`installer/mkosi.extra/usr/lib/systemd/system-preset/10-agentos-installer.preset`:
```
enable systemd-networkd.service
enable systemd-resolved.service
enable agentos-install-auto.service
```

`installer/mkosi.extra/usr/share/agentos/data/README.txt`:
```
AgentOS installer data partition

Interactive install: boot this stick and follow the menu on screen.

Unattended install: copy agentos.env.example to agentos.env on this partition,
set AGENTOS_INSTALL_DISK and whatever else you need, then boot. The installer
erases that disk without asking.

agentos.env may contain secrets (API keys, Tailscale key, password hash).
Delete it from this stick after installing.
```

`installer/mkosi.extra/usr/share/agentos/data/agentos.env.example`:
```
# Rename to agentos.env for an unattended install. Lines are KEY=VALUE.
# Required for unattended mode: the disk to ERASE and install onto.
#AGENTOS_INSTALL_DISK=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_XXXXXXXX
#AGENTOS_HOSTNAME=agentos-01
#AGENTOS_SSH_KEY=ssh-ed25519 AAAA... you@laptop
#AGENTOS_GITHUB_USER=yourname
# Password hash for the 'agent' user (console/sudo). Create with: openssl passwd -6
#AGENTOS_PASSWORD_HASH=$6$...
#TS_AUTHKEY=tskey-auth-...   (single-use, pre-approved, tagged tag:agentos)
#AGENTOS_LAN_SSH=1
#AGENTOS_CONSOLE=headless
#ANTHROPIC_API_KEY=...
#OPENAI_API_KEY=...
#GROK_CODE_XAI_API_KEY=...
# Static network (omit for DHCP)
#AGENTOS_NET_IFACE=enp3s0
#AGENTOS_NET_ADDRESS=192.168.1.50/24
#AGENTOS_NET_GATEWAY=192.168.1.1
#AGENTOS_NET_DNS=1.1.1.1,9.9.9.9
# Power off instead of reboot when done
#AGENTOS_INSTALL_POWEROFF=1
```

- [ ] **Step 5: Build and test**

```bash
chmod +x tools/build-installer.sh installer/mkosi.extra/usr/local/sbin/agentos-install
.superpowers/sdd/devvm.sh sh 'apt-get install -y -qq mtools >/dev/null && echo mtools ok'
.superpowers/sdd/devvm.sh run 'shellcheck -S warning tools/build-installer.sh test/installer-boot-test.sh installer/mkosi.extra/usr/local/sbin/agentos-install && mkosi -f build && tools/build-installer.sh && test/installer-boot-test.sh mkosi.output/agentos-installer.raw'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `PASS [usb]`, `PASS [cd]`, `INSTALLER BOOT OK`. Report the size of `agentos-installer.raw`, and confirm the partition labels with `sgdisk -p mkosi.output/agentos-installer.raw` on devvm.

- [ ] **Step 6: Commit**

```bash
git add .gitignore tools/build-installer.sh test/installer-boot-test.sh installer/
git commit -m "feat: installer image (UEFI USB + El Torito CD) that boots to the installer"
```

---

### Task 3: Install engine, unattended install, end-to-end test

**Files:**
- Modify: `installer/mkosi.extra/usr/local/sbin/agentos-install` (replace with the full engine)
- Modify: `test/smoke.sh` (SMOKE_DISK / SMOKE_KEY / SMOKE_NOSEED, `installed_` checks)
- Create: `test/install-test.sh`, `test/checks/95-installed.sh`

**Interfaces:**
- Consumes: `lib.sh` (Task 1); the installer image and `tools/build-installer.sh` (Task 2); the target's `/usr/local/bin/agentos-config` `set`/`add-ssh-key` (Plan 1).
- Produces `agentos-install`:
  - `--auto`: unattended if configured, else READY.
  - `--env FILE`: install from a settings file.
  - Task 4 adds `--tui`.
- Function `install_from_env FILE`: validates everything first, then writes, configures, and prints `AGENTOS INSTALL OK (<disk>)`. On failure it prints `INSTALL FAILED: <reason>` and exits 1.
- Produces in `test/smoke.sh`:
  - `SMOKE_DISK=<qcow2>`: every mode boots a fresh copy-on-write overlay of that disk instead of converting IMG. IMG is still required as the first argument; pass the same path.
  - `SMOKE_KEY=<private key>`: use this key instead of generating one.
  - `SMOKE_NOSEED=1`: no cloud-init seed, but the checks still run over SSH.
  - When `SMOKE_DISK` is set, functions named `installed_*` also run.
- Produces `test/install-test.sh <agentos-installer.raw>`: negative cases, then the unattended install, then the full smoke suite in uefi and bios against the installed disk. Prints `INSTALL TEST OK`.

- [ ] **Step 1: Smoke harness support for installed disks**

In `test/smoke.sh`:

1. Replace `ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"` with:
```bash
if [ -n "${SMOKE_KEY:-}" ]; then
  cp "$SMOKE_KEY" "$WORK/key"; chmod 600 "$WORK/key"; ssh-keygen -y -f "$WORK/key" > "$WORK/key.pub"
else
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
fi
```
2. In `boot()`, replace `if [[ $mode != *-noseed ]]; then` (the seed block) with `if [[ $mode != *-noseed && ${SMOKE_NOSEED:-0} != 1 ]]; then`.
3. In `boot()`, replace:
```bash
  qemu-img convert -O qcow2 "$IMG" "$WORK/disk-$mode.qcow2"
  qemu-img resize -q "$WORK/disk-$mode.qcow2" 40G
```
with:
```bash
  if [ -n "${SMOKE_DISK:-}" ]; then
    qemu-img create -q -f qcow2 -b "$(realpath "$SMOKE_DISK")" -F qcow2 "$WORK/disk-$mode.qcow2"
  else
    qemu-img convert -O qcow2 "$IMG" "$WORK/disk-$mode.qcow2"
    qemu-img resize -q "$WORK/disk-$mode.qcow2" 40G
  fi
```
4. In `run_checks()`, replace:
```bash
  for fn in $(declare -F | awk '{print $3}' | grep "^$prefix" | sort); do
```
with:
```bash
  local pattern="^$prefix"
  [[ -n ${SMOKE_DISK:-} && $prefix == check_ ]] && pattern="^(check_|installed_)"
  for fn in $(declare -F | awk '{print $3}' | grep -E "$pattern" | sort); do
```

`test/checks/95-installed.sh`:
```bash
# shellcheck shell=bash
# Only run against disks written by the installer (smoke.sh with SMOKE_DISK set).
installed_cloud_init_disabled()   { vm 'test -f /etc/cloud/cloud-init.disabled'; }
installed_no_installer_keys()     { vm '! sudo grep -qE "^(AGENTOS_INSTALL_|AGENTOS_SSH_KEY|AGENTOS_PASSWORD_HASH|AGENTOS_NET_|AGENTOS_GITHUB_USER)" /etc/agentos/agentos.env'; }
installed_hostname_from_env()     { vm 'test "$(hostname)" = agentos-test'; }
installed_three_partitions_only() { vm 'test "$(lsblk -nro PARTLABEL /dev/vda | grep -c .)" = 3 && ! lsblk -nro PARTLABEL /dev/vda | grep -qx AGENTOS'; }
installed_password_set()          { vm 'test "$(sudo passwd -S agent | cut -d" " -f2)" = P'; }
installed_static_network()        { vm 'grep -qx "Address=10.0.2.15/24" /etc/systemd/network/10-agentos-static.network && ip -4 addr show | grep -q "10.0.2.15/24"'; }
```

- [ ] **Step 2: Write the end-to-end test (failing)**

`test/install-test.sh`:
```bash
#!/bin/bash
# End-to-end installer test: refusal cases, an unattended install onto a blank 40G disk,
# then the full smoke suite (uefi + bios) against the installed disk.
set -euo pipefail
INST=$(realpath "${1:?usage: install-test.sh <agentos-installer.raw>}")
HERE=$(cd "$(dirname "$0")" && pwd)
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d); trap 'pkill -F "$WORK/q.pid" 2>/dev/null || true; [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"' EXIT
FAILS=0
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
HASH=$(openssl passwd -6 -stdin <<< 'agentos-test-password')

# installer stick with agentos.env on its AGENTOS partition
stick() {  # stick <env-file> -> $WORK/stick.raw
  cp --sparse=always "$INST" "$WORK/stick.raw"
  local start
  start=$(partx -g -o START,NAME "$WORK/stick.raw" | awk '$2=="AGENTOS"{print $1}')
  [ -n "$start" ] || { echo "no AGENTOS partition in installer image" >&2; exit 1; }
  mcopy -o -i "$WORK/stick.raw@@$((start * 512))" "$1" ::agentos.env
}

run_installer() {  # run_installer <target.qcow2> <marker> <timeout-s>: boot until marker or poweroff
  cp "$OVMF_VARS" "$WORK/vars.fd"; : > "$WORK/serial.log"
  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$WORK/stick.raw,format=raw,if=none,id=stick" -device virtio-blk-pci,drive=stick,serial=agentos-stick \
    -drive "file=$1,format=qcow2,if=none,id=tgt" -device virtio-blk-pci,drive=tgt,serial=agentos-target \
    -nic user,model=virtio-net-pci -display none -serial "file:$WORK/serial.log" -no-reboot \
    -daemonize -pidfile "$WORK/q.pid"
  local i
  for i in $(seq 1 "$3"); do
    grep -q "$2" "$WORK/serial.log" && break
    pkill -0 -F "$WORK/q.pid" 2>/dev/null || break
    sleep 1
  done
  for i in $(seq 1 120); do pkill -0 -F "$WORK/q.pid" 2>/dev/null || break; [[ $2 == "AGENTOS INSTALL OK"* ]] || break; sleep 1; done
  pkill -F "$WORK/q.pid" 2>/dev/null || true; sleep 1
  grep -q "$2" "$WORK/serial.log"
}

expect() {  # expect <label> <command...>
  if "${@:2}"; then echo "PASS [install] $1"; else echo "FAIL [install] $1"; tail -40 "$WORK/serial.log"; FAILS=$((FAILS + 1)); fi
}
untouched() { [ "$(qemu-img info --output=json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])')" -lt 1048576 ]; }

# 1. refuses the installer's own disk; target untouched
printf 'AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-stick\n' > "$WORK/env"; stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/t1.qcow2" 40G
expect refuses_boot_disk run_installer "$WORK/t1.qcow2" "refusing to install onto the installer's own disk" 300
expect boot_disk_case_target_untouched untouched "$WORK/t1.qcow2"

# 2. refuses a disk smaller than 32 GiB
printf 'AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-target\n' > "$WORK/env"; stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/t2.qcow2" 20G
expect refuses_small_disk run_installer "$WORK/t2.qcow2" "smaller than 32 GiB" 300
expect small_disk_untouched untouched "$WORK/t2.qcow2"

# 3. refuses invalid settings before writing
printf 'AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-target\nAGENTOS_SSH_KEY=command="x" ssh-ed25519 AAAA\n' > "$WORK/env"; stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/t3.qcow2" 40G
expect refuses_bad_ssh_key run_installer "$WORK/t3.qcow2" "invalid AGENTOS_SSH_KEY" 300
expect bad_settings_untouched untouched "$WORK/t3.qcow2"

# 4. the real install
cat > "$WORK/env" <<EOF
AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-target
AGENTOS_INSTALL_POWEROFF=1
AGENTOS_SSH_KEY=$(cat "$WORK/key.pub")
AGENTOS_PASSWORD_HASH=$HASH
AGENTOS_HOSTNAME=agentos-test
AGENTOS_LAN_SSH=1
AGENTOS_AUTO_REBOOT=0
ANTHROPIC_API_KEY=sk-test-dummy
PAD_TOKEN=abc==
PAD1_TOKEN=abc=
AGENTOS_NET_IFACE=enp0s2
AGENTOS_NET_ADDRESS=10.0.2.15/24
AGENTOS_NET_GATEWAY=10.0.2.2
AGENTOS_NET_DNS=10.0.2.3
EOF
stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/target.qcow2" 40G
expect unattended_install run_installer "$WORK/target.qcow2" "AGENTOS INSTALL OK" 1800
expect secrets_warning grep -q "wipe agentos.env" "$WORK/serial.log"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURE(S) before smoke"; exit 1; fi

# 5. full smoke suite on the installed disk, booted UEFI and BIOS
SMOKE_DISK="$WORK/target.qcow2" SMOKE_KEY="$WORK/key" SMOKE_NOSEED=1 "$HERE/smoke.sh" "$INST" uefi bios
echo "INSTALL TEST OK"
```
The static network check assumes the smoke VM's NIC is named `enp0s2` (q35 + virtio-net). Before relying on it, look up the real name: boot the installed disk once, or read `ip link` in any smoke VM via `vm 'ip -o link'`. Use that name in `AGENTOS_NET_IFACE`, and report it.

Run: `chmod +x test/install-test.sh && .superpowers/sdd/devvm.sh run 'tools/build-installer.sh && TMPDIR=/var/tmp test/install-test.sh mkosi.output/agentos-installer.raw'` and then `wait`.
Expected: FAIL. Case 1 times out without the refusal message, because the Task 2 engine says "not implemented".

- [ ] **Step 3: Full engine**

Replace `installer/mkosi.extra/usr/local/sbin/agentos-install` with:
```bash
#!/bin/bash
# AgentOS installer: writes the tested AgentOS disk image to a whole disk and applies settings.
#   agentos-install --auto        unattended if configured (kernel cmdline URL or AGENTOS partition), else READY
#   agentos-install --env FILE    install using KEY=VALUE settings from FILE
set -euo pipefail
. /usr/lib/agentos-installer/lib.sh
IMG_DIR=/usr/share/agentos
IMG=$IMG_DIR/agentos.raw.zst
DATA_DEV=/dev/disk/by-partlabel/AGENTOS
TARGET=/mnt/target
LOG=/tmp/agentos-install.log

die() { echo "INSTALL FAILED: $*" >&2; exit 1; }

boot_disk() { lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1; }

check_disk() {
  local d=$1 real
  [ -b "$d" ] || die "$d is not a block device"
  real=$(readlink -f "$d")
  [ "$(lsblk -dno TYPE "$real")" = disk ] || die "$d is not a whole disk"
  [ "$(basename "$real")" != "$(boot_disk)" ] || die "refusing to install onto the installer's own disk ($d)"
  [ "$(lsblk -bdno SIZE "$real")" -ge "$MIN_DISK_BYTES" ] || die "$d is smaller than 32 GiB"
  ! lsblk -no MOUNTPOINTS "$real" | grep -q . || die "$d has mounted partitions"
}

cleanup_mounts() {
  local m
  for m in "$TARGET/proc" "$TARGET/dev" "$TARGET"; do mountpoint -q "$m" && umount "$m"; done
  return 0
}

install_from_env() {
  local parsed disk real root line k v ghkeys=""
  parsed=$(parse_env "$1") || die "invalid settings file $1"
  get() { printf '%s\n' "$parsed" | env_value "$1"; }

  # --- validate everything before touching any disk ---
  disk=$(get AGENTOS_INSTALL_DISK); [ -n "$disk" ] || die "AGENTOS_INSTALL_DISK is not set"
  check_disk "$disk"; real=$(readlink -f "$disk")
  v=$(get AGENTOS_HOSTNAME);      [ -z "$v" ] || valid_hostname "$v"      || die "invalid AGENTOS_HOSTNAME"
  v=$(get AGENTOS_SSH_KEY);       [ -z "$v" ] || valid_ssh_pubkey "$v"    || die "invalid AGENTOS_SSH_KEY"
  v=$(get AGENTOS_PASSWORD_HASH); [ -z "$v" ] || valid_password_hash "$v" || die "AGENTOS_PASSWORD_HASH must be a \$6\$ or \$y\$ crypt hash (openssl passwd -6)"
  if [ -n "$(get AGENTOS_NET_ADDRESS)" ]; then
    valid_iface "$(get AGENTOS_NET_IFACE)" && valid_cidr "$(get AGENTOS_NET_ADDRESS)" &&
      valid_ipv4 "$(get AGENTOS_NET_GATEWAY)" || die "invalid static network settings (AGENTOS_NET_*)"
    for v in $(get AGENTOS_NET_DNS | tr ',' ' '); do valid_ipv4 "$v" || die "invalid DNS server $v"; done
  fi
  v=$(get AGENTOS_GITHUB_USER)
  if [ -n "$v" ]; then
    [[ $v =~ ^[A-Za-z0-9-]{1,39}$ ]] || die "invalid AGENTOS_GITHUB_USER"
    ghkeys=$(curl -fsS --max-time 20 "https://github.com/$v.keys") || die "could not fetch SSH keys for GitHub user $v"
  fi
  echo "Verifying the AgentOS image on this stick..."
  (cd "$IMG_DIR" && sha256sum -c --quiet agentos.raw.zst.sha256) || die "the installer image is corrupt; re-flash the stick. Nothing was changed."

  # --- write ---
  echo "Writing AgentOS to $disk. Everything on it will be erased."
  wipefs -a "$real" >/dev/null
  zstd -dc "$IMG" | dd of="$real" bs=4M conv=fsync status=progress ||
    die "writing the image failed; $disk was erased. Fix the problem and run the installer again."
  sgdisk -e "$real" >/dev/null || die "could not move the backup GPT to the end of $disk"
  partx -u "$real" 2>/dev/null || true
  udevadm settle
  root=""
  for _ in $(seq 1 20); do
    root=$(lsblk -lnpo NAME,PARTLABEL "$real" | awk -v l="$ROOT_PARTLABEL" '$2==l{print $1}')
    [ -n "$root" ] && break
    sleep 0.5; udevadm settle
  done
  [ -n "$root" ] || die "root partition not found on $disk after writing"

  # --- configure the new system via its own agentos-config ---
  trap cleanup_mounts EXIT
  mkdir -p "$TARGET"; mount "$root" "$TARGET"
  mount --bind /dev "$TARGET/dev"; mount -t proc proc "$TARGET/proc"
  while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}
    is_installer_key "$k" && continue
    [ -n "$v" ] || continue
    chroot "$TARGET" /usr/local/bin/agentos-config set "$k" "$v" >/dev/null || die "could not apply $k"
  done <<< "$parsed"
  v=$(get AGENTOS_SSH_KEY)
  [ -z "$v" ] || chroot "$TARGET" /usr/local/bin/agentos-config add-ssh-key "$v" || die "could not add AGENTOS_SSH_KEY"
  while IFS= read -r k; do
    [ -n "$k" ] && valid_ssh_pubkey "$k" || continue
    chroot "$TARGET" /usr/local/bin/agentos-config add-ssh-key "$k" || die "could not add a GitHub key"
  done <<< "$ghkeys"
  v=$(get AGENTOS_PASSWORD_HASH)
  [ -z "$v" ] || usermod -R "$TARGET" -p "$v" agent || die "could not set the password"
  if [ -n "$(get AGENTOS_NET_ADDRESS)" ]; then
    network_file "$(get AGENTOS_NET_IFACE)" "$(get AGENTOS_NET_ADDRESS)" "$(get AGENTOS_NET_GATEWAY)" "$(get AGENTOS_NET_DNS)" \
      > "$TARGET/etc/systemd/network/10-agentos-static.network"
  fi
  touch "$TARGET/etc/cloud/cloud-init.disabled"
  sync
  cleanup_mounts; trap - EXIT
  echo "AGENTOS INSTALL OK ($disk)"
}

auto() {
  local fat="" src
  mkdir -p /run/agentos-data
  if [ -e "$DATA_DEV" ] && mount -o ro "$DATA_DEV" /run/agentos-data 2>/dev/null; then
    fat=/run/agentos-data/agentos.env
  fi
  src=$(autoinstall_source "$(cat /proc/cmdline)" "$fat") || die "invalid autoinstall settings on the kernel command line"
  # shellcheck disable=SC2086  # deliberate word splitting of "kind arg [sha]"
  set -- $src
  case $1 in
    none) echo "AGENTOS-INSTALLER READY (interactive)"; return 0 ;;
    file) install -m 600 "$2" /run/agentos-install.env ;;
    url)
      (umask 077; curl -fsS --proto =https --tlsv1.2 --retry 5 --max-time 60 -o /run/agentos-install.env "$2") ||
        die "could not download $2"
      if [ -n "${3:-}" ]; then
        echo "$3  /run/agentos-install.env" | sha256sum -c --quiet || die "autoinstall file does not match agentos.autoinstall_sha256"
      fi ;;
  esac
  install_from_env /run/agentos-install.env 2>&1 | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
  [ "$1" = file ] && echo "Remove the stick, then wipe agentos.env from its AGENTOS partition: it may contain secrets."
  if [ "$(parse_env /run/agentos-install.env | env_value AGENTOS_INSTALL_POWEROFF)" = 1 ]; then
    systemctl poweroff
  else
    systemctl reboot
  fi
}

case "${1:-}" in
  --auto) auto ;;
  --env)  install_from_env "${2:?usage: agentos-install --env FILE}" ;;
  *)      echo "usage: agentos-install --auto | --env FILE" >&2; exit 2 ;;
esac
```
Notes:
- `secrets_warning` in the test greps for `wipe agentos.env`, which matches the `echo` above.
- `usermod -R` requires shadow's chroot support (`passwd` package). If it fails, use `chroot "$TARGET" usermod -p "$v" agent` and report it.
- `| tee` loses the exit status under `set -e`, which is why `PIPESTATUS[0]` is checked right after.

- [ ] **Step 4: Build and test**

```bash
.superpowers/sdd/devvm.sh run 'shellcheck -S warning installer/mkosi.extra/usr/local/sbin/agentos-install test/install-test.sh test/smoke.sh test/checks/95-installed.sh && test/installer_test.sh && tools/build-installer.sh && TMPDIR=/var/tmp test/install-test.sh mkosi.output/agentos-installer.raw'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: all `PASS [install] …` lines, then the smoke output with `ALL CHECKS PASSED` (uefi and bios, including the `installed_*` checks), then `INSTALL TEST OK`.

Also re-run the normal suite to prove the `smoke.sh` changes didn't break it: `TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed` must still print `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add installer/mkosi.extra/usr/local/sbin/agentos-install test/install-test.sh test/smoke.sh test/checks/95-installed.sh
git commit -m "feat: installer engine with unattended install; end-to-end install test reuses the full smoke suite"
```

---

### Task 4: Interactive installer (whiptail TUI on tty1)

**Files:**
- Modify: `installer/mkosi.extra/usr/local/sbin/agentos-install` (add `--tui`)
- Create: `installer/mkosi.extra/usr/local/sbin/agentos-install-tty`, `installer/mkosi.extra/etc/systemd/system/getty@tty1.service.d/agentos.conf`, `installer/mkosi.extra/etc/systemd/system/getty@tty2.service.d/agentos.conf`
- Modify: `test/installer-boot-test.sh`

**Interfaces:**
- Consumes: `install_from_env` (Task 3) and the `lib.sh` validators (Task 1).
- Produces: `agentos-install --tui`. It collects the settings with whiptail, writes `/run/agentos-install.env` (0600) and calls `install_from_env`, so it uses the same engine as unattended mode. On success it reboots, and on failure it shows the error and the log path, then returns to the start.
- Produces: tty1 runs the TUI (no login). tty2 is a root shell for troubleshooting (Alt+F2).

- [ ] **Step 1: Failing check, via a screen-content marker**

The TUI is interactive, so the automated check verifies that tty1 actually starts it. Make the TUI log `AGENTOS-INSTALLER TUI STARTED` to the kernel log on start (`echo … > /dev/kmsg`), which appears on the serial console. In `test/installer-boot-test.sh`, add a second marker check to the USB boot. Change:
```bash
boot_until usb "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,if=virtio,readonly=on"
```
to:
```bash
boot_until usb "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,if=virtio,readonly=on"
boot_until usb-tui "AGENTOS-INSTALLER TUI STARTED" -drive "file=$INST,format=raw,if=virtio,readonly=on"
```
Run it and confirm that `usb-tui` FAILS.

- [ ] **Step 2: TTY wiring**

`installer/mkosi.extra/usr/local/sbin/agentos-install-tty`:
```bash
#!/bin/bash
# tty1 login program on the installer: the interactive installer, restarted by getty when it exits.
set -euo pipefail
export TERM=linux
echo "AGENTOS-INSTALLER TUI STARTED" > /dev/kmsg 2>/dev/null || true
exec /usr/local/sbin/agentos-install --tui
```

`installer/mkosi.extra/etc/systemd/system/getty@tty1.service.d/agentos.conf`:
```ini
[Unit]
After=agentos-install-auto.service

[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --skip-login --nonewline --noissue --login-program /usr/local/sbin/agentos-install-tty %I $TERM
```

`installer/mkosi.extra/etc/systemd/system/getty@tty2.service.d/agentos.conf`:
```ini
# Live installer: root shell on tty2 for troubleshooting (physical access already implies full control).
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --autologin root %I $TERM
```
Add `enable getty@tty2.service` to `10-agentos-installer.preset`. If systemd's getty generator only starts tty2 on demand (autovt), that's fine, since Alt+F2 activates it. Report what you observed.

- [ ] **Step 3: TUI**

In `installer/mkosi.extra/usr/local/sbin/agentos-install`, add before the final `case`:
```bash
W() { whiptail --backtitle "AgentOS installer" "$@" 3>&1 1>&2 2>&3; }
ask() {  # ask <title> <prompt> <default> <validator|-> : repeat until valid or empty-allowed
  local v
  while true; do
    v=$(W --title "$1" --inputbox "$2" 12 72 "$3") || return 1
    [ "$4" = - ] || [ -z "$v" ] || "$4" "$v" && { printf '%s' "$v"; return 0; }
    W --msgbox "That value is not valid. Please try again." 8 50
  done
}

tui() {
  local env=/run/agentos-install.env disk name size model type boot items=() conf hn mode iface addr gw dns
  local pw pw2 key gh ts lan k v cm
  boot=$(boot_disk)
  while read -r name type size model; do
    [ "$type" = disk ] && [ "$name" != "$boot" ] || continue
    items+=("/dev/$name" "$size ${model//\\x20/ }")
  done < <(lsblk -dnro NAME,TYPE,SIZE,MODEL)
  [ ${#items[@]} -gt 0 ] || { W --msgbox "No installable disk found (the installer stick itself is hidden)." 8 70; return 1; }

  disk=$(W --title "Disk" --menu "Install AgentOS on which disk?\nThe whole disk will be ERASED." 18 72 8 "${items[@]}") || return 1
  conf=$(W --title "Erase $disk?" --inputbox "Type the disk name ($(basename "$disk")) to confirm erasing it:" 10 72 "") || return 1
  [ "$conf" = "$(basename "$disk")" ] || { W --msgbox "Name did not match; nothing was changed." 8 60; return 1; }

  hn=$(ask Hostname "Hostname (lowercase letters, digits, dashes):" agentos valid_hostname) || return 1
  mode=$(W --title Network --menu "Network configuration" 12 60 2 dhcp "Automatic (DHCP)" static "Static IPv4") || return 1
  if [ "$mode" = static ]; then
    local nics=(); for k in /sys/class/net/*; do k=${k##*/}; [ "$k" = lo ] || nics+=("$k" ""); done
    iface=$(W --title Network --menu "Interface" 14 60 6 "${nics[@]}") || return 1
    addr=$(ask Network "Address with prefix, e.g. 192.168.1.50/24" "" valid_cidr) || return 1
    gw=$(ask Network "Gateway, e.g. 192.168.1.1" "" valid_ipv4) || return 1
    dns=$(W --title Network --inputbox "DNS servers, comma separated" 10 60 "1.1.1.1,9.9.9.9") || return 1
  fi
  pw=$(W --title Access --passwordbox "Password for user 'agent' (console + sudo). Empty = none, set later." 10 72) || return 1
  if [ -n "$pw" ]; then
    pw2=$(W --title Access --passwordbox "Repeat the password" 10 72) || return 1
    [ "$pw" = "$pw2" ] || { W --msgbox "Passwords did not match." 8 40; return 1; }
  fi
  key=$(ask Access "SSH public key to allow (optional, paste one line):" "" valid_ssh_pubkey) || return 1
  gh=$(W --title Access --inputbox "Also import SSH keys from GitHub user (optional):" 10 72 "") || return 1
  ts=$(W --title Tailscale --passwordbox "Tailscale auth key (optional). Use a single-use, pre-approved key tagged tag:agentos." 10 72) || return 1
  lan=0
  [ -n "$ts" ] || ! W --title "SSH from LAN" --yesno "No Tailscale key. Allow SSH (key-only) from your local network?" 8 70 || lan=1
  cm=$(W --title Console --menu "Local console after install" 12 70 2 headless "Status + login prompt" terminal "Full-screen terminal after login") || return 1
  W --title Summary --yesno "Disk:      $disk (ERASED)\nHostname:  $hn\nNetwork:   $mode${iface:+ $iface $addr}\nPassword:  ${pw:+set}${pw:-none}\nSSH key:   ${key:+yes}${key:-no}${gh:+ + GitHub $gh}\nTailscale: ${ts:+yes}${ts:-no}\nLAN SSH:   $lan\n\nInstall now?" 18 72 || return 1

  (umask 077
   {
     printf 'AGENTOS_INSTALL_DISK=%s\nAGENTOS_HOSTNAME=%s\nAGENTOS_CONSOLE=%s\nAGENTOS_LAN_SSH=%s\n' "$disk" "$hn" "$cm" "$lan"
     [ -z "$pw" ] || printf 'AGENTOS_PASSWORD_HASH=%s\n' "$(openssl passwd -6 -stdin <<< "$pw")"
     [ -z "$key" ] || printf 'AGENTOS_SSH_KEY=%s\n' "$key"
     [ -z "$gh" ] || printf 'AGENTOS_GITHUB_USER=%s\n' "$gh"
     [ -z "$ts" ] || printf 'TS_AUTHKEY=%s\n' "$ts"
     [ "$mode" != static ] || printf 'AGENTOS_NET_IFACE=%s\nAGENTOS_NET_ADDRESS=%s\nAGENTOS_NET_GATEWAY=%s\nAGENTOS_NET_DNS=%s\n' "$iface" "$addr" "$gw" "$dns"
     for k in ANTHROPIC_API_KEY OPENAI_API_KEY GROK_CODE_XAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
       v=$(W --title "API keys (optional)" --passwordbox "$k (empty = skip; can be set later with agentos-config)" 10 72) || v=""
       [ -z "$v" ] || printf '%s=%s\n' "$k" "$v"
     done
   } > "$env")
  clear
  if (install_from_env "$env") 2>&1 | tee -a "$LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
    rm -f "$env"
    W --msgbox "AgentOS is installed.\n\nRemove the USB stick, then press Enter to reboot." 10 60
    systemctl reboot
  else
    rm -f "$env"
    W --msgbox "Installation failed:\n\n$(grep 'INSTALL FAILED' "$LOG" | tail -1)\n\nFull log: $LOG (Alt+F2 for a shell)." 14 72
    return 1
  fi
}
```
and change the final `case` to:
```bash
case "${1:-}" in
  --auto) auto ;;
  --env)  install_from_env "${2:?usage: agentos-install --env FILE}" ;;
  --tui)  tui || true ;;
  *)      echo "usage: agentos-install --auto | --tui | --env FILE" >&2; exit 2 ;;
esac
```
The API-key prompts run inside the subshell that writes the file, so the values never sit in shell variables longer than one line. They're written to the 0600 file and removed after the install.

- [ ] **Step 4: Build and test**

```bash
chmod +x installer/mkosi.extra/usr/local/sbin/agentos-install-tty
.superpowers/sdd/devvm.sh run 'shellcheck -S warning installer/mkosi.extra/usr/local/sbin/agentos-install installer/mkosi.extra/usr/local/sbin/agentos-install-tty && tools/build-installer.sh && test/installer-boot-test.sh mkosi.output/agentos-installer.raw && TMPDIR=/var/tmp test/install-test.sh mkosi.output/agentos-installer.raw'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `INSTALLER BOOT OK` (including `PASS [usb-tui]`) and `INSTALL TEST OK`.

- [ ] **Step 5: Manual walkthrough (once, record the result in the report)**

The interactive flow can't be scripted cheaply. Walk it once in QEMU with a VNC display on devvm, viewed through an SSH tunnel:
```bash
# on devvm
qemu-img create -f qcow2 /var/tmp/manual-target.qcow2 40G
cp /usr/share/OVMF/OVMF_VARS_4M.fd /var/tmp/manual-vars.fd
qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd -drive if=pflash,format=raw,file=/var/tmp/manual-vars.fd \
  -drive file=/root/agentos/mkosi.output/agentos-installer.raw,format=raw,if=virtio,readonly=on \
  -drive file=/var/tmp/manual-target.qcow2,format=qcow2,if=virtio -nic user,model=virtio-net-pci -vnc 127.0.0.1:9
# then capture screens without a viewer: echo 'screendump /var/tmp/s1.ppm' via -monitor, or attach a VNC client through ssh -L 5909:127.0.0.1:5909
```
Walk through: the disk list (the stick is absent), a wrong confirmation name (aborts, nothing changed), the full happy path with DHCP plus a password, and a reboot into the installed system. Save 3–4 screenshots (PPM converted to PNG) under `/var/tmp` and list them in the report. If driving whiptail through VNC isn't possible for you, use QEMU's monitor `sendkey` to drive it. If that's impractical too, report the manual walkthrough as **not done**. Don't claim it.

- [ ] **Step 6: Commit**

```bash
git add installer/ test/installer-boot-test.sh
git commit -m "feat: interactive whiptail installer on tty1, root shell on tty2"
```

---

### Task 5: CI, release asset and spec update

**Files:**
- Modify: `.github/workflows/build.yml`, `tools/convert.sh`, `docs/superpowers/specs/2026-10-21-agentos-design.md`

**Interfaces:**
- Consumes: `tools/build-installer.sh`, `test/installer_test.sh`, `test/installer-boot-test.sh`, `test/install-test.sh`.
- Produces: `tools/convert.sh <raw> <version> <outdir> [installer.raw]`. When the 4th argument is given, it adds `agentos-installer-<ver>.img.zst` before checksumming and splitting, so the existing split, SHA256SUMS and README logic covers it.
- Produces: CI runs installer unit tests in lint, then builds the installer, runs the boot test and the install test, and releases the installer asset.

- [ ] **Step 1: `convert.sh`**

In `tools/convert.sh`:
- Change the usage line to accept an optional 4th argument: `INSTALLER=${4:-}`.
- Right after `zstd -q -T0 -10 -o "$base.raw.zst" "$RAW"` (or whatever the current raw.zst line is; keep its level), add:
```bash
if [ -n "$INSTALLER" ]; then
  zstd -q -T0 -10 -o "$OUT/agentos-installer-$VER.img.zst" "$INSTALLER"
fi
```
- Make sure README-download.txt mentions the installer: "agentos-installer-<ver>.img.zst: decompress (`zstd -d`), then write the .img to a USB stick (dd, Etcher or Rufus DD mode) or attach it as a virtual CD (UEFI)." Put this in the README generation block.

Test locally on devvm: `tools/convert.sh mkosi.output/agentos.raw test /var/tmp/release mkosi.output/agentos-installer.raw && ls -l --block-size=M /var/tmp/release && (cd /var/tmp/release && grep installer SHA256SUMS README-download.txt)`. Expected: the installer asset is listed (split into parts if it's over 1900 MiB), and checksums are present.

- [ ] **Step 2: Workflow**

In `.github/workflows/build.yml`:
- Host setup: add `mtools` to the `apt-get install` list.
- Lint/unit step: add `test/installer_test.sh` and add the installer scripts to the shellcheck list (`tools/build-installer.sh test/installer-boot-test.sh test/install-test.sh installer/mkosi.extra/usr/local/sbin/*`). `lib.sh` is covered through `test/installer_test.sh`'s `source=` directive; add it explicitly as well.
- After the smoke step, add:
```yaml
      - name: Build installer
        run: tools/build-installer.sh

      - name: Installer boot test (USB + CD)
        run: test/installer-boot-test.sh mkosi.output/agentos-installer.raw

      - name: Installer end-to-end test
        run: TMPDIR=${{ runner.temp }} test/install-test.sh mkosi.output/agentos-installer.raw
```
- Convert step: pass `mkosi.output/agentos-installer.raw` as the 4th argument.
- `timeout-minutes`: raise to `240`.
- Validate: `python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/build.yml"))'`.

If `ElTorito` was disabled in Task 2, the boot test step runs with `SKIP_CD=1`.

- [ ] **Step 3: Spec update**

In `docs/superpowers/specs/2026-10-21-agentos-design.md` Section 4, replace the install bullet that describes `systemd-repart --empty=force … grub-install …` with:
```
   - Verify the embedded image (`sha256sum -c`), wipe the disk, write the tested `agentos.raw` verbatim (`zstd -dc | dd`), move the backup GPT to the disk end (`sgdisk -e`). The result is byte-identical to the VM images: ESP + BIOS boot + root, UEFI and BIOS bootable, Secure Boot via the signed shim; the root partition and filesystem grow at first boot (systemd-repart + x-systemd.growfs).
   - Mount the new root and apply settings with the target's own `agentos-config` (chroot); write the SSH key(s), password hash, optional static networkd file, and `/etc/cloud/cloud-init.disabled`.
```
Also, in "Unattended mode", mention the data partition's `agentos.env.example`, and that `AGENTOS_INSTALL_POWEROFF=1` powers off instead of rebooting. In "Error handling", add "the embedded image is checksum-verified before anything is written".

- [ ] **Step 4: Full verification and commit**

```bash
.superpowers/sdd/devvm.sh run 'shellcheck -S warning tools/*.sh test/*.sh installer/mkosi.extra/usr/local/sbin/* installer/mkosi.extra/usr/lib/agentos-installer/lib.sh && python3 -c "import yaml; yaml.safe_load(open(\".github/workflows/build.yml\"))" && test/installer_test.sh && rm -rf /var/tmp/release && tools/convert.sh mkosi.output/agentos.raw test /var/tmp/release mkosi.output/agentos-installer.raw && ls -l --block-size=M /var/tmp/release'
.superpowers/sdd/devvm.sh wait <JOB>
git add .github/workflows/build.yml tools/convert.sh docs/superpowers/specs/2026-10-21-agentos-design.md
git commit -m "ci: build, boot-test, install-test and release the AgentOS installer image"
```

---

## Spec coverage (Plan 3)

| Spec Section 4 item | Task |
|---|---|
| Live installer environment, boots straight into the installer on tty1, Alt+F2 shell | 2, 4 |
| One `.img` for USB and virtual CD (El Torito), UEFI-only installer | 2 |
| Disk list with model and size, boot medium excluded, typed-name confirmation | 4 (UI), 3 (enforced) |
| Hostname, network (DHCP/static), access (password / SSH key / GitHub), Tailscale, API keys, console mode | 4 (UI), 3 (applied) |
| Installed system: ESP + BIOS boot + root, UEFI+BIOS, root grows to fill the disk, byte-identical OS | 3 (via `dd` of agentos.raw; spec text updated in 5) |
| Unattended via the AGENTOS partition or an `https://` autoinstall URL with optional sha256; http refused | 1, 3 |
| Errors: nothing touched before writing; clear "disk erased" after; disks < 32 GiB refused | 3 (tested) |
| Secrets warning for the stick's agentos.env | 2 (README), 3 (message, tested) |
| CI builds the installer, runs an unattended install in QEMU, reboots, runs the same checks in UEFI and BIOS | 3, 5 |
| Release asset `agentos-installer-<ver>.img.zst` | 5 |
