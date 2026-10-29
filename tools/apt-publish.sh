#!/bin/bash
# Add an agentos .deb to the apt repo in SITE/apt (the gh-pages tree) and re-sign it.
#   tools/apt-publish.sh <agentos_V_amd64.deb> <notes.md> <SITE>
# Layout: apt/pool/main/a/agentos/*.deb, apt/dists/stable/{InRelease,Release,Release.gpg},
# apt/dists/stable/main/binary-amd64/Packages{,.gz}, apt/notes/<V>.md, apt/latest.json and
# apt/agentos-archive.gpg (the public key, for the one-time bootstrap of older boxes).
# Signs with the only secret key in $GNUPGHOME. Refuses: a development build (source disabled); a
# package whose keyring is not the signing key (boxes could not verify the next release); a version
# already published under different content; and a version old enough to be pruned the moment it
# lands (AGENTOS_APT_KEEP, default 10 — a box that just installed it would find it gone).
# Republishing the exact same .deb for a version already published is a no-op.
# ponytail: keeps the newest AGENTOS_APT_KEEP (10) versions for rollback; GitHub Pages sites are
# capped at 1 GB and a release is ~26 MB.
set -euo pipefail
die() { echo "apt-publish: $*" >&2; exit 1; }
DEB=$(realpath "${1:?usage: apt-publish.sh <deb> <notes.md> <site>}") NOTES=${2:?} SITE=${3:?}
KEEP=${AGENTOS_APT_KEEP:-10}
[[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "AGENTOS_APT_KEEP must be a positive integer, got: $KEEP"
A=$SITE/apt P=$SITE/apt/pool/main/a/agentos
V=$(dpkg-deb -f "$DEB" Version)
[ "$(dpkg-deb -f "$DEB" Package)" = agentos ] || die "$DEB is not the agentos package"
[ -s "$NOTES" ] || die "no release notes: $NOTES"

x=$(mktemp -d); trap 'rm -rf "$x"' EXIT
dpkg-deb -x "$DEB" "$x"
s=$x/etc/apt/sources.list.d/agentos.sources
grep -qiE '^Enabled:[[:space:]]*no' "$s" && die "$V is a development build (its AgentOS source is disabled)"
grep -q 'OWNER\.github\.io/REPO' "$s" && die "$V still has the placeholder repo URL"
fpr() { gpg --batch --with-colons "$@" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}'; }
want=$(fpr --list-secret-keys)
[ -n "$want" ] || die "no signing key in GNUPGHOME"
[ "$(fpr --show-keys "$x/usr/share/keyrings/agentos-archive.gpg")" = "$want" ] || die "$V ships a keyring that is not the signing key ($want)"

# Republishing the same version: identical content is a no-op, different content refuses (it
# would silently replace what boxes already fetched).
existing="$P/agentos_${V}_amd64.deb"
if [ -e "$existing" ]; then
  if cmp -s "$DEB" "$existing"; then
    echo "apt-publish: $V is already published, unchanged"
    exit 0
  fi
  die "$V is already published"
fi

# A version only published to be pruned immediately (older than the newest $KEEP) is refused
# before anything is written.
old_versions=()
for f in "$P"/agentos_*_amd64.deb; do
  [ -e "$f" ] || continue
  b=$(basename "$f"); b=${b#agentos_}; old_versions+=("${b%_amd64.deb}")
done
if [ "${#old_versions[@]}" -gt 0 ]; then
  printf '%s\n' "${old_versions[@]}" "$V"
else
  printf '%s\n' "$V"
fi | sort -V | tail -n "$KEEP" | grep -qx "$V" \
  || die "$V is older than the newest $KEEP published versions and would be pruned immediately"

mkdir -p "$P" "$A/notes" "$A/dists/stable/main/binary-amd64"
cp "$DEB" "$P/agentos_${V}_amd64.deb"
# Keep the newest $KEEP versions (sort -V orders Debian versions like 1.10.0 > 1.9.0 and ~ first).
mapfile -t old < <(ls "$P" | sed -n 's/^agentos_\(.*\)_amd64\.deb$/\1/p' | sort -V | head -n "-$KEEP")
for o in "${old[@]}"; do rm -f "$P/agentos_${o}_amd64.deb" "$A/notes/$o.md"; done

cp "$NOTES" "$A/notes/$V.md"
(cd "$A" && apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages)
gzip -9nkf "$A/dists/stable/main/binary-amd64/Packages"
# Drop the previous run's Release/InRelease/Release.gpg first: apt-ftparchive release walks the
# whole dists/stable tree, and would otherwise hash and list its own prior output.
rm -f "$A/dists/stable/Release" "$A/dists/stable/InRelease" "$A/dists/stable/Release.gpg"
apt-ftparchive -o APT::FTPArchive::Release::Origin=AgentOS -o APT::FTPArchive::Release::Label=AgentOS \
  -o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 -o APT::FTPArchive::Release::Components=main \
  release "$A/dists/stable" > "$x/Release"
mv "$x/Release" "$A/dists/stable/Release"
gpg --batch --yes -u "$want" --clearsign -o "$A/dists/stable/InRelease" "$A/dists/stable/Release"
gpg --batch --yes -u "$want" -abs -o "$A/dists/stable/Release.gpg" "$A/dists/stable/Release"
gpg --batch --yes --export -o "$A/agentos-archive.gpg" "$want"
base=$(sed -n 's/^URIs:[[:space:]]*//p' "$s" | head -1); base=${base%/}
latest=$(ls "$P" | sed -n 's/^agentos_\(.*\)_amd64\.deb$/\1/p' | sort -V | tail -1)
jq -n --arg v "$latest" --arg u "$base/notes/$latest.md" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: $v, notes_url: $u, published: $t}' > "$A/latest.json"
touch "$SITE/.nojekyll"   # Pages serves the files as they are, without a Jekyll build
echo "published agentos $V to $A"
