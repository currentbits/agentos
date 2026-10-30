#!/bin/bash
# Unit test for tools/convert.sh's checksums and download notes: SHA256SUMS carries an
# agentos-installer-<v>.iso line (the uncompressed installer's SHA-256; the .iso itself is served
# from dl.currentbits.net, not uploaded), `sha256sum -c --ignore-missing` still passes on the
# release directory, and README-download.txt points to the download page. qemu-img, sudo, lsblk and
# cp (for the manifest copy out of the image's mounted root only) are fakes; zstd and sha256sum are real.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$d/bin"
# qemu-img convert ... <in> <out>: write a stand-in for the output image.
printf '#!/bin/sh\nfor a; do out=$a; done\necho "image $out" > "$out"\n' > "$d/bin/qemu-img"
# sudo: losetup --find prints a loop device; mount, umount, udevadm and losetup -d do nothing.
printf '#!/bin/sh\n[ "$1" = losetup ] && [ "$2" = --find ] && echo /dev/loop9\nexit 0\n' > "$d/bin/sudo"
printf '#!/bin/sh\necho "/dev/loop9p1 root-x86-64"\n' > "$d/bin/lsblk"
cat > "$d/bin/cp" <<'EOS'
#!/bin/sh
[ "$1" = /mnt/agentos-root/var/lib/agentos-manifest.txt ] && { echo "agentos 9.9.9" > "$2"; exit 0; }
exec /bin/cp "$@"
EOS
chmod +x "$d/bin"/*
head -c 3000000 /dev/urandom > "$d/installer.raw"
echo raw > "$d/agentos.raw"
PATH=$d/bin:$PATH "$R/tools/convert.sh" "$d/agentos.raw" 9.9.9 "$d/out" "$d/installer.raw" >/dev/null

want="$(sha256sum < "$d/installer.raw" | cut -d' ' -f1)  agentos-installer-9.9.9.iso"
grep -qxF "$want" "$d/out/SHA256SUMS" || fail "no .iso line in SHA256SUMS: $(cat "$d/out/SHA256SUMS")"
[ ! -e "$d/out/agentos-installer-9.9.9.iso" ] || fail "the .iso must not be a release asset"
grep -q '  agentos-installer-9.9.9.img.zst$' "$d/out/SHA256SUMS" || fail "no .img.zst line"
(cd "$d/out" && sha256sum -c --ignore-missing --quiet SHA256SUMS) || fail "sha256sum -c on the release directory"
zstd -dc "$d/out/agentos-installer-9.9.9.img.zst" | sha256sum | grep -q "^${want%% *} " || fail ".img.zst does not decompress to the .iso's hash"
grep -qF 'https://dl.currentbits.net/agentos/index.html' "$d/out/README-download.txt" || fail "README-download.txt has no download page link"
grep -qF 'agentos-installer-9.9.9.iso' "$d/out/README-download.txt" || fail "README-download.txt does not name the .iso"
echo "convert OK"
