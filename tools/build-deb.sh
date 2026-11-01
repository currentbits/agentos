#!/bin/bash
# Build the agentos .deb into mkosi.packages/, where mkosi finds it (a local repository) and installs
# it into the image (mkosi.conf.d/50-agentos.conf). Release builds publish the same file to the apt repo.
#   tools/build-deb.sh                     version: the v* tag on HEAD, else <last v* tag>+git<date>.<sha>
#                                          (0.0.0+git<date>.<sha> with no tag at all)
#   AGENTOS_VERSION=1.4.0 tools/build-deb.sh
#   AGENTOS_DEV=1 tools/build-deb.sh       allowed while the repo URL or the signing key is not set
#                                          yet: the AgentOS apt source ships disabled (Enabled: no)
# The tree is package/ plus what is built here: the Python venv, the web UI, act and the bridge. It is
# built in a debian:trixie container, so the venv's Python (3.13) and node-pty's Node ABI (NodeSource
# 24, the image's apt source) match the image.
#
# Reproducible: the container is a pinned digest, not a floating tag; the Node package and every
# pip dependency are pinned by exact version (pip's by hash too, tools/requirements.txt); umask and
# every staged file's mtime are fixed; and the working directories act/the web UI build in are fixed
# paths rather than mktemp -d's random ones (node-pty's compiled addon embeds its build path).
# Building the same commit twice must produce byte-identical .debs; if it ever doesn't, find the
# differing bytes before assuming it's fine. Not (yet) checked by CI on every build -- verified by
# hand when this was last touched: build twice, diff the two .debs' sha256sum.
set -euo pipefail
die() { echo "build-deb: $*" >&2; exit 1; }
umask 022

# Pinned by digest, not the floating "trixie" tag, so the base image itself is identical on every
# build. This does not make every input identical: apt inside this pinned image still resolves
# against whatever is current in the live trixie archive right now (ca-certificates, python3,
# python3-venv, build-essential/gcc, curl are installed unpinned below) -- only nodejs and the pip
# packages are pinned to an exact version. If that archive drift ever needs pinning too, snapshot
# an old trixie archive at a fixed timestamp via snapshot.debian.org and point apt's sources at it
# inside inside(); not done, since it hasn't been needed yet.
# Bump: docker pull debian:trixie && docker inspect --format '{{index .RepoDigests 0}}' debian:trixie.
DEBIAN_TRIXIE_DIGEST=sha256:2dc419c6d7fe3dad0a2f9fd469c34cc90b0f9ba642d8fde837fe3d7d34a0e7f1

# Debian packages AgentOS's own code needs (moved here from mkosi.conf.d, so a release can add one).
# The image's base (kernel, systemd, toolchains, docker, tailscale) stays in mkosi.conf.d.
DEPENDS=(
  # agetty execs /bin/login; trixie no longer pulls it in, so boxes before 1.0.4 had no console login.
  login
  # The venv in /usr/local/lib/agentos/venv is built against this exact Python.
  python3.13
  # node-pty in the web UI is compiled for this Node major.
  'nodejs (>= 24~)' 'nodejs (<< 25~)'
  # Desktops and computer use (was mkosi.conf.d/30-desktop.conf).
  tigervnc-standalone-server xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfce4-terminal
  xfconf dbus-x11 adwaita-icon-theme xdotool scrot xclip chromium fonts-dejavu fonts-noto-color-emoji
  novnc websockify polkitd
  # Electron runtime libraries for Solenta's Linux build (was mkosi.conf.d/40-solenta.conf). Solenta's
  # Remote Connections installs it over SSH and checks it with ldd. Trixie names (t64 ABI renames).
  libnss3 libnspr4 libgtk-3-0t64 libgbm1 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64
  libatspi2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libxfixes3
  libpango-1.0-0 libcairo2 libdbus-1-3 libexpat1 libxext6 libx11-6 libxcb1 libglib2.0-0t64
  # Solenta 0.27 --headless still needs an X display (GTK aborts without one): solenta-start's Xvfb.
  xvfb
)

# act runs .github/workflows for agentos-ci. Pinned by version and sha256 (the release's
# checksums.txt); Docker pulls its runner images on first use, they are never baked in.
ACT_VERSION=0.2.89
ACT_SHA256=0191d6f1f3b716b5c55820032605d05fc3c1cdbf581ebeff655019e5dd1524c0

# Pin the exact version so two builds don't silently get different bytes when NodeSource publishes
# a new 24.x build. Consequence: NodeSource's apt repo keeps only the latest build of each major,
# so once it ships a newer one, installing this exact version starts failing closed (apt: "no
# installation candidate") at every build, until NODEJS_VERSION below is bumped to match.
# Bump: inside the pinned container (DEBIAN_TRIXIE_DIGEST above), run `apt-cache madison nodejs`
# after adding the nodesource source, and take the newest nodesource line.
NODEJS_VERSION=24.13.1-1nodesource1

inside() {  # runs in the container: /src (the repo, read-only) -> /out/agentos_<version>_amd64.deb
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  install -d /etc/apt/keyrings
  cp /src/apt/keyrings/nodesource.gpg /etc/apt/keyrings/
  cp /src/apt/sources.list.d/nodesource.sources /etc/apt/sources.list.d/
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends "nodejs=$NODEJS_VERSION" python3 python3-venv build-essential curl >/dev/null
  node -e 'process.exit(process.versions.node.startsWith("24.") ? 0 : 1)' || { echo "build-deb: Node $(node --version) is not 24.x" >&2; exit 1; }

  local S=/build/root W wb at
  mkdir -p /build
  cp -a /src/package "$S"

  # agentos-computer and agentos-ci deps, isolated from the system and the agent's own Python. Built
  # at its final path: a venv is not relocatable. Exact versions and hashes for mcp/pillow/pyyaml and
  # their full dependency closure (tools/requirements.txt, header documents how to regenerate it);
  # --require-hashes --no-deps installs exactly that set and nothing pip's own resolver might pick
  # differently between runs.
  python3 -m venv /usr/local/lib/agentos/venv
  /usr/local/lib/agentos/venv/bin/pip install -q --no-cache-dir --disable-pip-version-check \
    --require-hashes --no-deps -r /src/tools/requirements.txt
  # --no-deps installed exactly the pinned set and nothing else, but never checked that set is
  # internally consistent; pip check catches a stale/incompatible pin (e.g. requirements.txt
  # regenerated by hand and missing a version bump) that --require-hashes alone would not.
  /usr/local/lib/agentos/venv/bin/pip check
  cp -a /usr/local/lib/agentos/venv "$S/usr/local/lib/agentos/venv"

  # Fixed paths, not mktemp -d's random ones: node-pty's compiled addon and act's binary can embed
  # their build directory, which must be identical across builds for the resulting .deb to match.
  at=/build/act
  mkdir -p "$at"
  curl -fsSL -o "$at/act.tgz" "https://github.com/nektos/act/releases/download/v$ACT_VERSION/act_Linux_x86_64.tar.gz"
  echo "$ACT_SHA256  $at/act.tgz" | sha256sum -c --quiet -
  tar -xzf "$at/act.tgz" -C "$at" act
  install -D -m 755 "$at/act" "$S/usr/local/bin/act"

  # The Mac-side Solenta bridge (Mode B), served for download by the web UI's Solenta card.
  install -D -m 755 /src/tools/solenta-bridge "$S/usr/local/share/agentos/solenta-bridge"

  # The web UI: only the build output and production node_modules ship. node-pty compiles against
  # this Node with node-gyp. Host node_modules/dist are excluded: a macOS checkout must not leak
  # darwin binaries into the package.
  W=$S/usr/local/lib/agentos/web
  wb=/build/web
  mkdir -p "$wb"
  tar -C /src/web --exclude=node_modules --exclude=dist -cf - . | tar -C "$wb" -xf -
  # One command per line: set -e ignores a failure anywhere in an && chain except its last command.
  (
    cd "$wb/ui"
    npm ci --no-audit --no-fund
    npm run build
    cd "$wb/server"
    npm ci --no-audit --no-fund
    npm run build
    npm prune --omit=dev --no-audit --no-fund
    # node-pty also ships Windows/macOS prebuilds and its C++ sources; Linux loads build/Release only.
    rm -rf node_modules/node-pty/prebuilds node_modules/node-pty/third_party node_modules/node-pty/deps node_modules/node-pty/src
  )
  install -d "$W/server"
  cp -a "$wb/server/dist" "$wb/server/node_modules" "$wb/server/package.json" "$W/server/"
  cp -a "$wb/ui/dist" "$W/ui"

  # The package's units, for postinst's "new units" step (templates can't be enabled by name).
  (cd "$S/usr/lib/systemd/system" && ls agentos-*.service agentos-*.timer agentos-*.path) | grep -v @ > "$S/usr/local/lib/agentos/units.new"

  if [ "$AGENTOS_DEV_SOURCE" = 1 ]; then
    sed -i 's/^Types: deb$/# Development build: no repo URL or signing key yet (tools\/build-deb.sh, AGENTOS_DEV=1).\nEnabled: no\nTypes: deb/' \
      "$S/etc/apt/sources.list.d/agentos.sources"
    grep -qx 'Enabled: no' "$S/etc/apt/sources.list.d/agentos.sources" || { echo "build-deb: could not disable the dev apt source" >&2; exit 1; }
  fi
  chmod 0440 "$S/etc/sudoers.d/agent"
  # Everything in /etc is a conffile: a local edit is kept on upgrade (the new file lands as .dpkg-dist).
  (cd "$S" && find etc -type f | sort | sed 's|^|/|') > "$S/DEBIAN/conffiles"
  local deps size
  deps=$(printf '%s, ' "${DEPENDS[@]}"); deps=${deps%, }
  size=$(du -sk --exclude=DEBIAN "$S" | cut -f1)
  sed -i -e "s/^Version: .*/Version: $AGENTOS_VERSION/" -e "s/^Depends: .*/Depends: $deps/" \
    -e "s/^Installed-Size: .*/Installed-Size: $size/" "$S/DEBIAN/control"
  # Pin every staged file's mtime to the commit's own timestamp (-h: a symlink's own mtime, not
  # its target's), the last source of non-determinism once content, owner and umask are fixed.
  find "$S" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  dpkg-deb --root-owner-group -b "$S" "/out/agentos_${AGENTOS_VERSION}_amd64.deb" >/dev/null
  chown "$OWNER_UID:$OWNER_GID" "/out/agentos_${AGENTOS_VERSION}_amd64.deb"
}

# stdout: $AGENTOS_VERSION if set; else the exact tag on HEAD; else the last v* tag (anywhere in
# the repo, not just HEAD's ancestry) plus +git<date>.<sha>, or 0.0.0+git<date>.<sha> if there is no
# tag at all. The +git form sorts above that last tag and below the next one (dpkg --compare-versions:
# "1.0.0+git..." gt "1.0.0", lt "1.0.1"), so an untagged build is never offered as a downgrade once
# the repo has real releases. ~git (sorts *below* the last tag) would do the opposite.
compute_version() {
  local v tag last
  v=${AGENTOS_VERSION:-}
  if [ -n "$v" ]; then echo "$v"; return; fi
  tag=$(git describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || true)
  if [ -n "$tag" ]; then echo "${tag#v}"; return; fi
  last=$(git tag --list 'v[0-9]*' | sed 's/^v//' | sort -V | tail -1)
  echo "${last:-0.0.0}+git$(date -u +%Y%m%d).$(git rev-parse --short=8 HEAD 2>/dev/null || echo local)"
}

if [ "${1:-}" = --inside ]; then inside; exit 0; fi

cd "$(dirname "$0")/.."
if [ "${1:-}" = --print-version ]; then compute_version; exit 0; fi
SRC=package/etc/apt/sources.list.d/agentos.sources
KEY=package/usr/share/keyrings/agentos-archive.gpg
dev=0
[ -f "$SRC" ] || die "missing $SRC"
if grep -q '^URIs: https://OWNER\.github\.io/REPO/apt$' "$SRC" || [ ! -s "$KEY" ]; then
  [ "${AGENTOS_DEV:-0}" = 1 ] || die "the AgentOS apt repo is not set up yet: set its URL in $SRC and commit its public key as $KEY (docs/updates.md, owner steps), or build with AGENTOS_DEV=1 for a development image whose AgentOS update source is disabled"
  dev=1
fi
V=$(compute_version)
[[ $V =~ ^[0-9][A-Za-z0-9.+~]*$ ]] || die "not a usable package version: $V"
mkdir -p mkosi.packages
rm -f mkosi.packages/agentos_*.deb
# Every staged file's mtime is pinned to the commit's own timestamp (reproducibility: see the file
# header), not the build's wall-clock time. A caller-provided SOURCE_DATE_EPOCH (the
# reproducible-builds.org convention) wins, same as every other tool that honors it -- also how a
# tree without .git (e.g. rsynced to a build host without history) can still build reproducibly.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}
docker run --rm -e AGENTOS_VERSION="$V" -e AGENTOS_DEV_SOURCE="$dev" -e OWNER_UID="$(id -u)" -e OWNER_GID="$(id -g)" \
  -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  -v "$PWD:/src:ro" -v "$PWD/mkosi.packages:/out" "debian@$DEBIAN_TRIXIE_DIGEST" bash /src/tools/build-deb.sh --inside
echo "mkosi.packages/agentos_${V}_amd64.deb"
