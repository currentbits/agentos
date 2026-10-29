#!/bin/bash
# Unit test for tools/solenta-bridge: port parsing from sample Solenta JSON (tokens never read
# out or printed), the tunnel argv, and install/uninstall with a fake launchctl. Runs on Linux
# and on macOS's bash 3.2.
set -euo pipefail
B=$(cd "$(dirname "$0")/.." && pwd)/tools/solenta-bridge
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
TOKEN=tok-SUPERSECRET-0123456789abcdef
mkdir -p "$d/sol"
printf '{\n  "port": 53121,\n  "token": "%s"\n}\n' "$TOKEN" > "$d/sol/orch-server.json"
printf '{"dbPath":"/x/port\\"s.db","token":"%s","port":61002}' "$TOKEN" > "$d/sol/memory-server.json"
export SOLENTA_DIR=$d/sol SOLENTA_BRIDGE_CONF=$d/conf SOLENTA_BRIDGE_PLIST=$d/la/x.plist HOME=$d/home LAUNCHCTL=$d/launchctl
mkdir -p "$HOME"
printf '#!/bin/sh\necho "$*" >> %s/launchctl.log\n' "$d" > "$d/launchctl"; chmod +x "$d/launchctl"

out=$(bash -x "$B" ports 2>"$d/trace")
[ "$out" = $'53121\n61002' ] || fail "ports: $out"
if grep -q SUPERSECRET "$d/trace"; then fail "token visible in the shell trace"; fi
# shellcheck source=../tools/solenta-bridge
. "$B"
[ "$(port_of /nonexistent)" = "" ] || fail missing
printf '{"port": 99999, "token": "x"}' > "$d/big.json"; [ "$(port_of "$d/big.json")" = "" ] || fail range
printf '{"port": 655350, "token": "x"}' > "$d/big2.json"; [ "$(port_of "$d/big2.json")" = "" ] || fail "range truncation"
printf '{"token": "x"}' > "$d/none.json"; [ "$(port_of "$d/none.json")" = "" ] || fail none
[ "$(ssh_argv agent@box.ts.net 53121 61002 | tr '\n' ' ')" = \
  "ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:53121:127.0.0.1:53121 -R 127.0.0.1:61002:127.0.0.1:61002 -- agent@box.ts.net " ] || fail argv

if bash "$B" install 'agent@box;rm -rf /' 2>/dev/null; then fail "accepted a bad box"; fi
if bash "$B" install '-oProxyCommand=x@y' 2>/dev/null; then fail "accepted an option as a box"; fi
if bash "$B" install '-x@y' 2>/dev/null; then fail "accepted a leading dash"; fi
bash "$B" install agent@box1.ts.net agent@100.64.0.2 >/dev/null
[ "$(cat "$d/conf")" = $'agent@box1.ts.net\nagent@100.64.0.2' ] || fail conf
# install copies itself somewhere launchd can always reach (not wherever it was downloaded to, and
# not broken if that original is later moved) and points the plist at the copy, not at $B.
COPY="$HOME/Library/Application Support/AgentOS/solenta-bridge"
[ -x "$COPY" ] || fail "no stable copy at $COPY"
cmp -s "$COPY" "$B" || fail "copy differs from source"
grep -q "<string>$COPY</string><string>run</string>" "$d/la/x.plist" || fail plist
grep -q "bootstrap gui/$(id -u) $d/la/x.plist" "$d/launchctl.log" || fail bootstrap
if grep -rq SUPERSECRET "$d/conf" "$d/la" "$d/launchctl.log"; then fail "token written out"; fi
# The loop: one ssh per box with both forwards, retried after a drop.
mkdir -p "$d/fakebin"; : > "$d/ssh.log"
printf '#!/bin/sh\necho "$*" >> %s/ssh.log\nexit 1\n' "$d" > "$d/fakebin/ssh"; chmod +x "$d/fakebin/ssh"
PATH="$d/fakebin:$PATH" bash "$B" run 2>/dev/null & rp=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ "$(grep -c 'agent@box1.ts.net' "$d/ssh.log" || true)" -ge 2 ] && break; sleep 0.25
done
kill "$rp"; wait "$rp" 2>/dev/null || true
grep -qx -- "-N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:53121:127.0.0.1:53121 -R 127.0.0.1:61002:127.0.0.1:61002 -- agent@100.64.0.2" "$d/ssh.log" || fail "run argv: $(cat "$d/ssh.log")"
[ "$(grep -c 'agent@box1.ts.net' "$d/ssh.log")" -ge 2 ] || fail "no retry"
# Reinstalling by running the already-installed copy itself (src and dest are the same file) must
# still work: BSD `cp` onto itself fails ("identical, not copied"), so the copy step must be
# skipped (or done via a temp file + mv) rather than attempted verbatim.
bash "$COPY" install agent@box1.ts.net agent@box3.ts.net >/dev/null || fail "reinstall from the installed copy failed"
[ "$(cat "$d/conf")" = $'agent@box1.ts.net\nagent@box3.ts.net' ] || fail "reinstall didn't update conf"
[ -x "$COPY" ] || fail "reinstall removed the stable copy"
cmp -s "$COPY" "$B" || fail "copy differs from source after reinstall"
bash "$B" uninstall >/dev/null
[ ! -e "$d/la/x.plist" ] && grep -q "bootout gui/$(id -u)/os.agent.solenta-bridge" "$d/launchctl.log" || fail uninstall
[ ! -e "$COPY" ] || fail "uninstall left the stable copy behind"

# A $HOME containing XML-special characters must not corrupt the plist: install escapes & < >.
# All three in one path: on bash 5.2's patsub_replacement (default on), an unquoted "&" in a
# ${s//pat/rep} replacement means "the matched text", so ${s//</&lt;} silently becomes "<lt;"
# instead of "&lt;" (the "&" and ">" substitutions happen to come out right by coincidence, so a
# HOME with only "&" would not have caught this).
d2="$d/ho&m<e>x"; mkdir -p "$d2"
HOME=$d2 SOLENTA_BRIDGE_CONF=$d/amp-conf SOLENTA_BRIDGE_PLIST=$d/la/amp.plist \
  bash "$B" install agent@box1.ts.net >/dev/null
grep -q '&amp;' "$d/la/amp.plist" || fail "HOME's & not escaped in plist"
grep -q '&lt;' "$d/la/amp.plist" || fail "HOME's < not escaped in plist"
grep -q '&gt;' "$d/la/amp.plist" || fail "HOME's > not escaped in plist"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$d/la/amp.plist" >/dev/null || fail "plutil -lint rejected the escaped plist"
fi
echo "solenta-bridge OK"
