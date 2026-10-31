#!/bin/bash
# Unit test for web-lan-cert (the web UI's LAN certificate) in a temporary directory.
set -euo pipefail
export AGENTOS_LIB; AGENTOS_LIB=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos
S=$AGENTOS_LIB/web-lan-cert
# shellcheck source=../package/usr/local/lib/agentos/env.sh
. "$AGENTOS_LIB/env.sh"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export WEB_LAN_DIR=$d/web-lan WEB_LAN_GROUP; WEB_LAN_GROUP=$(id -gn)
FP_RE='^([0-9A-F]{2}:){31}[0-9A-F]{2}$'

fp=$("$S"); [[ $fp =~ $FP_RE ]] || { echo "bad fingerprint: $fp" >&2; exit 1; }
[ "$(stat -c '%a' "$WEB_LAN_DIR")" = 750 ]
[ "$(stat -c '%a %G' "$WEB_LAN_DIR/key.pem")" = "640 $WEB_LAN_GROUP" ]
[ "$(stat -c '%a' "$WEB_LAN_DIR/cert.pem")" = 644 ]
txt=$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -text)
grep -q 'ASN1 OID: prime256v1' <<< "$txt"
grep -q 'TLS Web Server Authentication' <<< "$txt"
h=$(hostname); grep -q "DNS:$h, DNS:$h.local" <<< "$txt"
for ip in $(lan_ipv4s); do
  grep -q "IP Address:$ip" <<< "$txt" || { echo "SAN lacks $ip" >&2; exit 1; }
done
openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -checkend $((824 * 86400)) >/dev/null
if openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -checkend $((826 * 86400)) >/dev/null; then echo "valid beyond 825 days" >&2; exit 1; fi
# The key matches the certificate.
[ "$(openssl pkey -in "$WEB_LAN_DIR/key.pem" -pubout)" = "$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -pubkey)" ]
# Kept: a second run prints the same fingerprint and leaves the files alone.
[ "$("$S")" = "$fp" ]
# Deleted: made again, with a new fingerprint.
rm "$WEB_LAN_DIR/cert.pem"; fp2=$("$S"); [[ $fp2 =~ $FP_RE ]]; [ "$fp2" != "$fp" ]
# Expiring within 30 days: made again.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 10 -subj /CN=old \
  -keyout "$WEB_LAN_DIR/key.pem" -out "$WEB_LAN_DIR/cert.pem" 2>/dev/null
old=$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')
fp3=$("$S"); [ "$fp3" != "$old" ]; openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -checkend $((800 * 86400)) >/dev/null
# A mismatched pair (as if caught between the two renames that swap key.pem and cert.pem into
# place) is detected and fixed, not kept.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WEB_LAN_DIR/key.pem" 2>/dev/null
fp4=$("$S"); [[ $fp4 =~ $FP_RE ]] || { echo "bad fingerprint after a mismatch: $fp4" >&2; exit 1; }
[ "$(openssl pkey -in "$WEB_LAN_DIR/key.pem" -pubout)" = "$(openssl x509 -in "$WEB_LAN_DIR/cert.pem" -noout -pubkey)" ] \
  || { echo "mismatched key/cert pair was not fixed" >&2; exit 1; }
echo "web-lan-cert OK"
