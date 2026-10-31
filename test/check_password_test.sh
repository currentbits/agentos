#!/bin/bash
# Unit test for check-password (the LAN login's password check) against a fake shadow file.
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos/check-password
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export AGENTOS_SHADOW=$d/shadow
PW='correct horse:battery$staple'
# A yescrypt hash (passwd/chpasswd's default on trixie) and a SHA-512 one (the installer's).
y=$(perl -e 'print crypt($ARGV[0], q($y$j9T$) . q(F5Jx5fExrKuPp53xLKQ..1))' "$PW")
s6=$(perl -e 'print crypt($ARGV[0], q($6$saltsaltsalt$))' "$PW")
[[ $y == '$y$j9T$'* && $s6 == '$6$'* ]] || { echo "this libcrypt cannot make the test hashes: $y $s6" >&2; exit 1; }
shadow() { printf 'root:*:20000:0:99999:7:::\nagent:%s:20000:0:99999:7:::\nother:%s:20000::::::\n' "$1" "$y" > "$AGENTOS_SHADOW"; }
rc() { local r=0; "$S" "$@" || r=$?; echo "$r"; }

for h in "$y" "$s6"; do
  shadow "$h"
  [ "$(printf '%s\n' "$PW" | rc)" = 0 ]                  # right, with the newline the server sends
  [ "$(printf '%s' "$PW" | rc)" = 0 ]                    # right, no newline
  [ "$(printf '%s\n' "${PW}x" | rc)" = 1 ]               # wrong
  [ "$(printf '%s\n' "${PW%?}" | rc)" = 1 ]              # a prefix
  [ "$(printf '\n' | rc)" = 1 ]                          # empty
  [ "$(rc </dev/null)" = 1 ]                             # nothing on stdin
  [ "$(printf '%s\nextra\n' "$PW" | rc)" = 0 ]           # only the first line counts
  [ "$(head -c 2000 /dev/zero | tr '\0' a | rc)" = 1 ]   # longer than 1024 bytes
done
# No usable password: none, locked, empty (which would accept anything), no agent line.
for h in '!' '*' "!$y" ''; do shadow "$h"; [ "$(printf '%s\n' "$PW" | rc)" = 2 ]; [ "$(printf '\n' | rc)" = 2 ]; done
printf 'root:*:20000::::::\n' > "$AGENTOS_SHADOW"; [ "$(printf '%s\n' "$PW" | rc)" = 2 ]
[ "$(printf '%s\n' "$PW" | AGENTOS_SHADOW=$d/missing rc)" = 2 ]
# Never takes the password in argv: any argument is refused before stdin is read.
shadow "$y"; [ "$(printf '%s\n' "$PW" | rc "$PW")" = 64 ]
# Prints nothing, on any outcome.
[ -z "$(printf '%s\n' "$PW" | "$S" 2>&1)" ]
[ -z "$(printf 'x\n' | "$S" 2>&1 || true)" ]
echo "check-password OK"
