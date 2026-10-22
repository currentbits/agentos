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
