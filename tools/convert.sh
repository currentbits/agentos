#!/bin/bash
# Convert agentos.raw into all release formats + manifest + checksums.
set -euo pipefail
RAW=${1:?usage: convert.sh <agentos.raw> <version> <outdir>}; VER=${2:?}; OUT=${3:?}
mkdir -p "$OUT"
base="$OUT/agentos-$VER"

qemu-img convert -c -O qcow2 "$RAW" "$base.qcow2"
qemu-img convert -O vhdx -o subformat=dynamic "$RAW" "$base.vhdx"
qemu-img convert -O vmdk -o subformat=streamOptimized "$RAW" "$base.vmdk"
zstd -q -T0 -10 --rm "$base.vhdx" "$base.vmdk"
zstd -q -T0 -10 -o "$base.raw.zst" "$RAW"

# Manifest from the image's root partition
loop=$(sudo losetup --find --show --partscan "$RAW")
trap 'sudo umount /mnt/agentos-root 2>/dev/null || true; sudo losetup -d "$loop"' EXIT
sudo udevadm settle # partscan's partition nodes appear before udev tags PARTLABEL; avoid a race on the next line
root=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk 'tolower($2) ~ /root/ {print $1; exit}')
sudo mkdir -p /mnt/agentos-root && sudo mount -o ro "$root" /mnt/agentos-root
cp /mnt/agentos-root/var/lib/agentos-manifest.txt "$OUT/MANIFEST.txt"

(cd "$OUT" && sha256sum agentos-* MANIFEST.txt > SHA256SUMS)
ls -lh "$OUT"
