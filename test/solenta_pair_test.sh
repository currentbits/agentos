#!/bin/bash
# Unit test for solenta-pair against fake host keys, a fake tailscale and fake CLIs.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
P=$R/mkosi.extra/usr/local/lib/agentos/solenta-pair
W=$R/mkosi.extra/usr/local/lib/agentos/cli-wrapper
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
h=$d/home; mkdir -p "$h/.config/Solenta" "$h/solenta/resources/app" "$d/ssh" "$d/bin" "$d/real" "$d/fake"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$d/ssh/ssh_host_ed25519_key"
fp=$(ssh-keygen -l -f "$d/ssh/ssh_host_ed25519_key.pub" | awk '{print $2}')
printf '#!/bin/sh\necho "{\\"Self\\":{\\"DNSName\\":\\"box.tail.ts.net.\\",\\"TailscaleIPs\\":[\\"100.64.0.9\\"],\\"sshHostKeys\\":[\\"x\\"]}}"\n' > "$d/fake/tailscale"
printf '#!/bin/sh\necho inactive\nexit 3\n' > "$d/fake/systemctl"
echo 'SUPERSECRET-web-token' > "$h/.config/Solenta/web-token"
echo '{"version":"0.27.0"}' > "$h/solenta/resources/app/package.json"
# The wrappers come first on the preflight PATH; the real CLIs sit behind them (grok is missing).
for c in claude codex opencode grok; do ln -s "$W" "$d/bin/$c"; done
for c in claude codex opencode; do printf '#!/bin/sh\n' > "$d/real/$c"; chmod +x "$d/real/$c"; done
for c in git bash; do ln -s "$(command -v "$c")" "$d/bin/$c"; done
printf '#!/bin/sh\n' > "$d/bin/node"; chmod +x "$d/bin/node"
git init -q "$h/work-repo"
chmod +x "$d/fake/"*
pair() { HOME=$h PATH="$d/fake:$PATH" TAILSCALE="$d/fake/tailscale" \
         AGENTOS_SSH_DIR="$d/ssh" AGENTOS_WRAPPER="$W" AGENTOS_PREFLIGHT_PATH="$d/bin:$d/real:/usr/bin:/bin" "$P" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(pair status -- "$h/work-repo")
! grep -q SUPERSECRET <<< "$out" || fail "token printed"
jq -e --arg fp "$fp" --arg wr "$h/work-repo" '
  .host == "box.tail.ts.net" and .remoteHost == "agent@box.tail.ts.net" and .remotePath == $wr and
  .tailscaleSsh == true and .hostKeys == [{type: "ssh-ed25519", fingerprint: $fp}] and
  .keyscan == "ssh-keyscan -t ed25519 box.tail.ts.net >> ~/.ssh/known_hosts" and
  .modeA == {enabled: false, service: "inactive", version: "0.27.0", webToken: true}' <<< "$out" >/dev/null || fail "status: $out"
jq -e --arg d "$d" '([.preflight[] | {(.item): .ok}] | add) == {git: true, bash: true, node: true, claude: true,
  codex: true, opencode: true, grok: false, ".solenta writable": true, "git checkout": true}
  and (.preflight[] | select(.item == "claude") | .detail) == "\($d)/real/claude"
  and (.preflight[] | select(.item == "grok") | .detail | test("grok is not installed"))' <<< "$out" >/dev/null || fail "preflight: $out"
pair status -- "$d" | jq -e '.preflight[] | select(.item == "git checkout") | .ok == false' >/dev/null || fail "non-repo passed"
pair status | jq -e '.remotePath == null and ([.preflight[].item] | index("git checkout") == null)' >/dev/null || fail "no path"
for bad in 'file:///etc' '-uhttps://x' 'https://a b' 'ext::sh -c id'; do
  if pair clone "$bad" demo 2>/dev/null; then fail "clone accepted $bad"; fi
done
if pair clone https://example.invalid/x.git '../x' 2>/dev/null; then fail "clone accepted a bad name"; fi
echo "solenta-pair OK"
