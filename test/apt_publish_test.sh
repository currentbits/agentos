#!/bin/bash
# Unit test for tools/apt-publish.sh with a throwaway signing key and stand-in agentos packages:
# signed InRelease and Release.gpg, every kept version listed, notes and latest.json, pruning to
# AGENTOS_APT_KEEP, republishing (no-op on identical content, refusal on different content), and
# the refusals (development build, foreign keyring, missing notes, placeholder URL, no signing
# key, bad AGENTOS_APT_KEEP, a backport that would be pruned on arrival).
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export GNUPGHOME=$d/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg -q --batch --passphrase '' --quick-gen-key 'AgentOS test <test@invalid>' ed25519 sign never 2>/dev/null
gpg -q --batch --export > "$d/key.gpg"
G2=$d/other; mkdir -m 700 "$G2"
GNUPGHOME=$G2 gpg -q --batch --passphrase '' --quick-gen-key 'Other <o@invalid>' ed25519 sign never 2>/dev/null
GNUPGHOME=$G2 gpg -q --batch --export > "$d/other.gpg"
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdeb() {  # mkdeb VERSION [KEYRING] [extra sources line] [URI]
  local t=$d/pkg-$1
  mkdir -p "$t/DEBIAN" "$t/etc/apt/sources.list.d" "$t/usr/share/keyrings"
  printf 'Package: agentos\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@t>\nDescription: t\n' "$1" > "$t/DEBIAN/control"
  printf '%sTypes: deb\nURIs: %s\nSuites: stable\nComponents: main\n' "${3:-}" "${4:-https://o.github.io/agentos/apt}" > "$t/etc/apt/sources.list.d/agentos.sources"
  cp "${2:-$d/key.gpg}" "$t/usr/share/keyrings/agentos-archive.gpg"
  dpkg-deb --root-owner-group -b "$t" "$d/agentos_$1_amd64.deb" >/dev/null
}
echo "What's new" > "$d/notes.md"
pub() { AGENTOS_APT_KEEP=3 "$R/tools/apt-publish.sh" "$d/agentos_$1_amd64.deb" "$d/notes.md" "$d/site" >/dev/null; }
A=$d/site/apt

for v in 1.0.0 1.1.0; do mkdeb $v; pub $v; done
gpgv -q --keyring "$d/key.gpg" "$A/dists/stable/InRelease" 2>/dev/null || fail "InRelease signature"
gpgv -q --keyring "$d/key.gpg" "$A/dists/stable/Release.gpg" "$A/dists/stable/Release" 2>/dev/null || fail "Release.gpg signature"
! gpgv -q --keyring "$d/other.gpg" "$A/dists/stable/InRelease" 2>/dev/null || fail "verified with the wrong key"
[ "$(grep '^Version:' "$A/dists/stable/main/binary-amd64/Packages" | sort | tr '\n' ' ')" = 'Version: 1.0.0 Version: 1.1.0 ' ] || fail "Packages lists both versions"
grep -qx 'Origin: AgentOS' "$A/dists/stable/Release" && grep -qx 'Suite: stable' "$A/dists/stable/Release" || fail "Release fields"
sha=$(sha256sum "$A/dists/stable/main/binary-amd64/Packages" | cut -d' ' -f1)
grep -q " $sha .* main/binary-amd64/Packages$" "$A/dists/stable/Release" || fail "Release hash of Packages"
shagz=$(sha256sum "$A/dists/stable/main/binary-amd64/Packages.gz" | cut -d' ' -f1)
grep -q " $shagz .* main/binary-amd64/Packages\.gz$" "$A/dists/stable/Release" || fail "Release hash of Packages.gz"
! grep -qE ' (In)?Release(\.gpg)?$' "$A/dists/stable/Release" || fail "Release lists InRelease/Release/Release.gpg"
cmp -s "$A/agentos-archive.gpg" "$d/key.gpg" || fail "public key export"
[ "$(cat "$A/notes/1.1.0.md")" = "What's new" ] || fail "notes"
jq -e '.version == "1.1.0" and .notes_url == "https://o.github.io/agentos/apt/notes/1.1.0.md" and (.published | test("Z$"))' "$A/latest.json" >/dev/null || fail "latest.json"
[ -e "$d/site/.nojekyll" ] || fail ".nojekyll"

# Pruning: with KEEP=3, publishing 1.2.0, 1.10.0 drops 1.0.0 (and its notes); 1.10.0 sorts last.
for v in 1.2.0 1.10.0; do mkdeb $v; pub $v; done
[ "$(ls "$A/pool/main/a/agentos" | sort -V | tr '\n' ' ')" = 'agentos_1.1.0_amd64.deb agentos_1.2.0_amd64.deb agentos_1.10.0_amd64.deb ' ] || fail "prune: $(ls "$A/pool/main/a/agentos")"
[ ! -e "$A/notes/1.0.0.md" ] && [ "$(jq -r .version "$A/latest.json")" = 1.10.0 ] || fail "prune notes / latest"

# Republishing an existing version: identical content is a no-op; different content refuses.
cp "$A/dists/stable/InRelease" "$d/before"
pub 1.10.0
cmp -s "$A/dists/stable/InRelease" "$d/before" || fail "identical republish changed the repo"
mkdeb 1.10.0 "$d/key.gpg" $'# retry\n'
pub 1.10.0 2>/dev/null && fail "republished 1.10.0 with different content"
cmp -s "$A/dists/stable/InRelease" "$d/before" || fail "a rejected republish changed the repo"

# Refusals: nothing changes.
mkdeb 2.0.0 "$d/key.gpg" $'Enabled: no\n'; pub 2.0.0 2>/dev/null && fail "published a development build"
mkdeb 2.0.1 "$d/other.gpg"; pub 2.0.1 2>/dev/null && fail "published with a foreign keyring"
mkdeb 2.0.2; AGENTOS_APT_KEEP=3 "$R/tools/apt-publish.sh" "$d/agentos_2.0.2_amd64.deb" "$d/none.md" "$d/site" 2>/dev/null && fail "published without notes"
mkdeb 2.0.3 "" "" "https://OWNER.github.io/REPO/apt"; pub 2.0.3 2>/dev/null && fail "published with the placeholder repo URL"
mkdeb 2.0.4
G3=$d/nokey; mkdir -m 700 "$G3"
GNUPGHOME=$G3 AGENTOS_APT_KEEP=3 "$R/tools/apt-publish.sh" "$d/agentos_2.0.4_amd64.deb" "$d/notes.md" "$d/site" 2>/dev/null && fail "published without a signing key in GNUPGHOME"
mkdeb 2.0.5
AGENTOS_APT_KEEP=0 "$R/tools/apt-publish.sh" "$d/agentos_2.0.5_amd64.deb" "$d/notes.md" "$d/site" 2>/dev/null && fail "published with AGENTOS_APT_KEEP=0"
AGENTOS_APT_KEEP=abc "$R/tools/apt-publish.sh" "$d/agentos_2.0.5_amd64.deb" "$d/notes.md" "$d/site" 2>/dev/null && fail "published with a non-numeric AGENTOS_APT_KEEP"
mkdeb 1.0.5; pub 1.0.5 2>/dev/null && fail "published a backport that would be pruned immediately"
cmp -s "$A/dists/stable/InRelease" "$d/before" && [ ! -e "$A/pool/main/a/agentos/agentos_2.0.0_amd64.deb" ] || fail "a refusal changed the repo"
echo "apt-publish OK"
