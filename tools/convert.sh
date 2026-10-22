#!/bin/bash
# Convert agentos.raw into all release formats + manifest + checksums.
# GitHub rejects release assets over 2 GiB, so anything bigger gets split
# into <1900 MiB parts before SHA256SUMS is written.
set -euo pipefail
RAW=${1:?usage: convert.sh <agentos.raw> <version> <outdir>}; VER=${2:?}; OUT=${3:?}
mkdir -p "$OUT"
base="$OUT/agentos-$VER"

# zstd-compressed qcow2 clusters pack tighter than the default (zlib); fall
# back to plain -c if this qemu-img build doesn't support the option.
if qcow2_err=$(qemu-img convert -c -O qcow2 -o compression_type=zstd "$RAW" "$base.qcow2" 2>&1); then
  :
else
  echo "convert.sh: compression_type=zstd rejected, falling back to default qcow2 compression:" >&2
  echo "$qcow2_err" >&2
  rm -f "$base.qcow2"
  qemu-img convert -c -O qcow2 "$RAW" "$base.qcow2"
fi
qemu-img convert -O vhdx -o subformat=dynamic "$RAW" "$base.vhdx"
qemu-img convert -O vmdk -o subformat=streamOptimized "$RAW" "$base.vmdk"
zstd -q -T0 -10 --rm "$base.vhdx" "$base.vmdk"
zstd -q -T0 -10 -o "$base.raw.zst" "$RAW"

# Manifest from the image's root partition
loop=$(sudo losetup --find --show --partscan "$RAW")
trap 'sudo umount /mnt/agentos-root 2>/dev/null || true; sudo losetup -d "$loop"' EXIT
sudo udevadm settle # partscan's partition nodes appear before udev tags PARTLABEL; avoid a race on the next line

root=""
for _ in $(seq 1 20); do
  root=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk 'tolower($2) ~ /root/ {print $1; exit}')
  [[ -n "$root" ]] && break
  sleep 0.5
done
[[ -n "$root" ]] || { echo "convert.sh: root partition not found on $loop after 10s of retries" >&2; exit 1; }

sudo mkdir -p /mnt/agentos-root && sudo mount -o ro "$root" /mnt/agentos-root
cp /mnt/agentos-root/var/lib/agentos-manifest.txt "$OUT/MANIFEST.txt"

# Which images are over GitHub's 2 GiB release-asset limit? Checked now,
# while every agentos-* file is still whole, so SHA256SUMS below verifies
# the reassembled file rather than any individual part.
limit=$((1900 * 1024 * 1024))
split_files=()
for f in "$OUT"/agentos-*; do
  size=$(stat -c%s "$f")
  if (( size > limit )); then
    split_files+=("$(basename "$f")")
  fi
done

{
  echo "AgentOS release download notes"
  echo
  if (( ${#split_files[@]} > 0 )); then
    echo "These files were split into <1900 MiB parts for GitHub's 2 GiB release-asset limit:"
    for sf in "${split_files[@]}"; do
      echo "  - $sf  ->  ${sf}.part00, ${sf}.part01, ..."
    done
    echo
    echo "Reassemble before use:"
    for sf in "${split_files[@]}"; do
      echo "  cat ${sf}.part* > ${sf}"
    done
    echo
  fi
  echo "Then verify what you downloaded against the whole-file checksums"
  echo "(--ignore-missing skips the formats you did not download):"
  echo "  sha256sum -c --ignore-missing SHA256SUMS"
  echo
  echo "SHA256SUMS.parts (if present) checksums the individual .partNN files,"
  echo "for verifying a partial download before reassembly."
} > "$OUT/README-download.txt"

(cd "$OUT" && sha256sum agentos-* MANIFEST.txt README-download.txt > SHA256SUMS)

# Now actually split the oversized files and checksum the parts separately.
: > "$OUT/SHA256SUMS.parts"
for sf in "${split_files[@]}"; do
  f="$OUT/$sf"
  split -b 1900M -d -a 2 "$f" "$f.part"
  rm "$f"
  (cd "$OUT" && sha256sum "$sf".part*) >> "$OUT/SHA256SUMS.parts"
done
[[ -s "$OUT/SHA256SUMS.parts" ]] || rm -f "$OUT/SHA256SUMS.parts"

# Final guard: every resulting asset must fit GitHub's 2 GiB release-asset limit.
guard=$((1950 * 1024 * 1024))
for f in "$OUT"/*; do
  [[ -f "$f" ]] || continue
  size=$(stat -c%s "$f")
  if (( size > guard )); then
    echo "convert.sh: $f is $(( size / 1024 / 1024 )) MiB, over the 1950 MiB release-asset guard" >&2
    exit 1
  fi
done

ls -lh "$OUT"
