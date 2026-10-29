#!/bin/bash
# Unit test for tools/build-deb.sh's version computation (--print-version, a test-only hook that
# prints the version and exits before the repo-URL/signing-key/docker steps): $AGENTOS_VERSION
# wins; else the exact v* tag on HEAD; else the highest v* tag anywhere in the repo (sort -V, not
# just HEAD's ancestry) plus +git<date>.<sha>; else 0.0.0+git<date>.<sha> with no tag at all. Also
# locks in the dpkg version ordering the +git scheme depends on: it must sort above the tag it
# followed and below the next one, never as a downgrade of a real release.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }

# build-deb.sh resolves its repo root from its own path (dirname "$0")/..: give each scenario its
# own copy of the script inside a throwaway git repo, instead of running against the real,
# currently-tagged AgentOS checkout.
repo() {  # repo NAME -> prints $d/NAME, a fresh repo with tools/build-deb.sh copied in
  local r=$d/$1
  mkdir -p "$r/tools"
  cp "$R/tools/build-deb.sh" "$r/tools/build-deb.sh"
  git -C "$r" init -q
  echo "$r"
}

# AGENTOS_VERSION, when set, always wins (no git repo needed at all).
r=$(repo explicit)
[ "$(cd "$r" && AGENTOS_VERSION=9.9.9 tools/build-deb.sh --print-version)" = 9.9.9 ] || fail "explicit AGENTOS_VERSION"

# No tag at all: 0.0.0+git<date>.<sha>.
r=$(repo none)
git -C "$r" commit -q --allow-empty -m x
v=$(cd "$r" && tools/build-deb.sh --print-version)
[[ $v =~ ^0\.0\.0\+git[0-9]{8}\.[0-9a-f]{7,8}$ ]] || fail "no tag: $v"

# The tag on HEAD, exactly, no +git suffix.
r=$(repo tagged)
git -C "$r" commit -q --allow-empty -m x
git -C "$r" tag v1.2.3
[ "$(cd "$r" && tools/build-deb.sh --print-version)" = 1.2.3 ] || fail "tag on HEAD"

# Past the tag: <highest tag>+git<date>.<sha>, by version sort, not creation order or lexicographic
# order (v1.10.0 sorts above v1.2.0).
r=$(repo past)
git -C "$r" commit -q --allow-empty -m 1
git -C "$r" tag v1.2.0
git -C "$r" tag v1.10.0
git -C "$r" commit -q --allow-empty -m 2
v=$(cd "$r" && tools/build-deb.sh --print-version)
[[ $v =~ ^1\.10\.0\+git[0-9]{8}\.[0-9a-f]{7,8}$ ]] || fail "past the tag: $v"

# The version regex build-deb.sh (and agentos-update, web/server/src/update.ts) all enforce accepts
# the +git form.
[[ $v =~ ^[0-9][A-Za-z0-9.+~]*$ ]] || fail "version regex: $v"

# The dpkg ordering this scheme relies on: sorts above the tag it followed, below the next release.
dpkg --compare-versions "1.10.0+git20261030.abcdefg" gt 1.10.0 || fail "compare: not gt the last tag"
dpkg --compare-versions "1.10.0+git20261030.abcdefg" lt 1.10.1 || fail "compare: not lt the next tag"
dpkg --compare-versions "0.0.0+git20261030.abcdefg" gt 0.0.0 || fail "compare: not gt 0.0.0"

echo "build-deb version OK"
