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
