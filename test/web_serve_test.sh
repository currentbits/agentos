#!/bin/bash
# Unit test for web-serve (the firstboot `tailscale serve` step) against a fake tailscale.
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)/mkosi.extra/usr/local/lib/agentos/web-serve
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/tailscale" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$FAKE_MODE:$1" in
  down:status) exit 1 ;;
  nohttps:serve) [ "$2" = --bg ] && { echo "Serve is not enabled on your tailnet."; echo "To enable, visit: https://login.tailscale.com/f/serve?node=x"; exit 1; } ;;
  hang:serve) [ "$2" = --bg ] && { echo "To enable, visit: https://login.tailscale.com/f/serve?node=y"; sleep 30; } ;;
esac
exit 0
FAKE
chmod +x "$d/tailscale"
export TAILSCALE=$d/tailscale FAKE_LOG=$d/log WEB_SERVE_TIMEOUT=2
run() { : > "$d/log"; FAKE_MODE=$1 "$S" "$2"; }

[ "$(run up 1)" = ok ]
grep -qx 'serve --bg --https=443 http://127.0.0.1:7070' "$d/log"
[ "$(run up 0)" = off ]
grep -qx 'serve --https=443 off' "$d/log"
[ "$(run down 1)" = tailscale-down ]
if grep -q '^serve' "$d/log"; then echo 'serve ran while tailscale was down' >&2; exit 1; fi
out=$(run nohttps 1); [[ $out == 'failed: Serve is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/serve?node=x' ]] || { echo "got: $out" >&2; exit 1; }
out=$(run hang 1); [[ $out == 'failed: To enable, visit: https://login.tailscale.com/f/serve?node=y'* ]] || { echo "got: $out" >&2; exit 1; }
echo "web-serve OK"
