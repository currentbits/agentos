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
I=mkosi.output/agentos-installer.raw
die() { echo "build-installer: $I: $*" >&2; exit 1; }
part() { partx -g -o START,"$2" "$1" | awk -v v="$3" '$2==v{print $1 * 512; exit}'; }  # part <img> <col> <value>: byte offset
# A CD is read in 2048-byte blocks (installer/mkosi.postoutput pads the image).
[ $(($(stat -c %s "$I") % 2048)) = 0 ] || die "size is not a multiple of 2048"
# agetty on tty2 (root shell) execs /bin/login.
o=$(part "$I" NAME agentos-installer); [ -n "$o" ] || die "no root partition"
has() { debugfs -R "stat $1" "$I?offset=$o" 2>/dev/null | grep -q '^Inode:'; }
has /usr/bin/login || die "no /usr/bin/login (tty2 shell)"
has /etc/systemd/system/getty.target.wants/getty@tty2.service || die "getty@tty2 is not enabled (tty2 shell)"
# Booted as a CD, GRUB picks the ESP by FAT serial (search --fs-uuid): it must differ from the one an
# installed system (a copy of agentos.raw) carries, or GRUB could boot the installed disk's ESP instead.
esp_uuid() { local o; o=$(part "$1" TYPE c12a7328-f81f-11d2-ba4b-00a0c93ec93b) && [ -n "$o" ] && blkid -p -O "$o" -s UUID -o value "$1"; }
a=$(esp_uuid "$I") || a=""; b=$(esp_uuid mkosi.output/agentos.raw) || b=""
[ -n "$a" ] && [ -n "$b" ] || die "cannot read the ESP FAT serials"
[ "$a" != "$b" ] || die "ESP FAT serial $a equals agentos.raw's; rebuild the installer (the serial is random per build)"
ls -lh "$I"
