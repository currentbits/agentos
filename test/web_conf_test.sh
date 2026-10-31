#!/bin/bash
# Unit test for web-conf (firstboot's web UI step) with fake passwd, ip, tailscale, web-serve and
# web-lan-cert.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/lib" "$d/bin" "$d/etc"
ln -s "$R/env.sh" "$d/lib/env.sh"
FP=B4:A0:73:5F:85:CC:CE:06:76:AE:B3:64:CA:36:6A:F8:BC:6B:EF:B4:BC:FD:7F:9C:0E:CB:D9:6E:DE:D2:A9:B8
cat > "$d/lib/web-serve" <<'FAKE'
#!/bin/bash
if [ "$1" = 0 ]; then echo off; else echo "$FAKE_SERVE"; fi
FAKE
cat > "$d/lib/web-lan-cert" <<'FAKE'
#!/bin/bash
echo cert >> "$FAKE_LOG"; [ "$FAKE_CERT" = ok ] && echo "$FP"
FAKE
cat > "$d/bin/passwd" <<'FAKE'
#!/bin/bash
echo "agent $FAKE_PW 2026-10-31 0 99999 7 -1"
FAKE
cat > "$d/bin/ip" <<'FAKE'
#!/bin/bash
printf '%s\n' '2: enp1s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic enp1s0' \
  '3: tailscale0    inet 100.64.0.9/32 scope global tailscale0' '4: docker0    inet 172.17.0.1/16 scope global docker0' \
  '5: wlan0    inet 10.0.0.7/24 scope global wlan0' '6: enp2s0    inet 10.0.1.7/24 scope global enp2s0'
FAKE
cat > "$d/bin/tailscale" <<'FAKE'
#!/bin/bash
echo '{"Self":{"DNSName":"box.tail1234.ts.net."}}'
FAKE
chmod +x "$d/lib/"web-* "$d/bin/"*
export PATH=$d/bin:$PATH AGENTOS_LIB=$d/lib AGENTOS_ETC=$d/etc ISSUE_DIR=$d/issue.d FAKE_LOG=$d/log FP
ISSUE=$d/issue.d/50-agentos-web.issue
# run <AGENTOS_WEB_LAN> <passwd -S state> <serve> [cert ok|fail] [AGENTOS_WEB]: prints web-conf's stdout
run() {
  printf 'AGENTOS_WEB_USERS=a@b.com\nAGENTOS_WEB_LAN=%s\nAGENTOS_WEB=%s\n' "$1" "${5:-1}" > "$d/etc/agentos.env"
  : > "$FAKE_LOG"
  FAKE_PW=$2 FAKE_SERVE=$3 FAKE_CERT=${4:-ok} "$R/web-conf" 2> "$d/err"
}
fail() { echo "FAIL: $*"; echo "--- web.conf"; cat "$d/etc/web.conf"; echo "--- issue"; cat "$ISSUE" 2>/dev/null; echo "--- stderr"; cat "$d/err"; exit 1; } >&2
conf() { cat "$d/etc/web.conf"; }

# On, with a password: LAN=1 and the fingerprint; the first run changes the listener, the next doesn't.
[ "$(run 1 P tailscale-down)" = restart ] || fail "first run: restart"
[ "$(conf)" = "$(printf 'USERS=a@b.com\nENABLED=1\nSERVE=tailscale-down\nLAN=1\nFINGERPRINT=%s' "$FP")" ] || fail "web.conf, LAN on"
[ "$(stat -c %a "$d/etc/web.conf")" = 644 ] || fail "web.conf mode"
[ -z "$(run 1 P tailscale-down)" ] || fail "second run: no restart"
[ -z "$(run 1 P ok)" ] || fail "a serve change is no LAN change"
# No usable password (locked or none): refused, and it says how to fix it; no certificate is made.
for pw in L NP; do
  run 1 "$pw" tailscale-down >/dev/null
  grep -qx 'LAN=0' "$d/etc/web.conf" && grep -qx 'FINGERPRINT=' "$d/etc/web.conf" || fail "no password ($pw): LAN stays off"
  grep -q 'needs a password for agent (sudo agentos-config password)' "$d/err" || fail "no password ($pw): warning"
  [ ! -s "$FAKE_LOG" ] || fail "no password ($pw): certificate made anyway"
done
# Turning it on again changes the listener; turning it off too.
[ "$(run 1 P tailscale-down)" = restart ] || fail "on again: restart"
[ "$(run 0 P tailscale-down)" = restart ] || fail "off: restart"
grep -qx 'LAN=0' "$d/etc/web.conf" || fail "off: LAN=0"
# The certificate can't be made: off, with a warning.
run 1 P tailscale-down fail >/dev/null
grep -qx 'LAN=0' "$d/etc/web.conf" && grep -q 'could not make the LAN certificate' "$d/err" || fail "cert failure"
# The web UI off (AGENTOS_WEB=0) turns LAN access off too.
run 1 P ok ok 0 >/dev/null
grep -qx 'ENABLED=0' "$d/etc/web.conf" && grep -qx 'LAN=0' "$d/etc/web.conf" && grep -qx 'SERVE=off' "$d/etc/web.conf" || fail "web off"
# tailscale serve failed: a warning, and the console says why.
run 0 P 'failed: Serve is not enabled on your tailnet.' >/dev/null
grep -q 'warning: web UI: tailscale serve failed' "$d/err" || fail "serve failed warning"
grep -qx 'Web UI: tailscale serve failed: Serve is not enabled on your tailnet.' "$ISSUE" || fail "serve failed line"
# An invalid AGENTOS_WEB_LAN is the default (off).
printf 'AGENTOS_WEB_LAN=yes\n' > "$d/etc/agentos.env"; FAKE_PW=P FAKE_SERVE=off FAKE_CERT=ok "$R/web-conf" >/dev/null 2>&1
grep -qx 'LAN=0' "$d/etc/web.conf" || fail "invalid value"
echo "web-conf OK"
