#!/bin/bash
# Unit test for the CLI wrappers (cli-wrapper + load-secrets.sh), run as any user: AGENTOS_AGENT_USER
# names the current user as "the agent". Needs bash >= 4.4.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
LIB=$R/package/usr/local/lib/agentos
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
h=$d/home; mkdir -p "$h/.local/bin" "$h/.grok/bin" "$h/.config/agentos" "$d/bin" "$d/bin2" "$d/sys"
printf 'ANTHROPIC_API_KEY=sk-ant-1==\nXAI_API_KEY=xai-2\nnot a line\nlower=x\n' > "$h/.config/agentos/secrets.env"
for c in claude codex opencode grok; do ln -s "$LIB/cli-wrapper" "$d/bin/$c"; done
ln -s "$LIB/cli-wrapper" "$d/bin2/codex"                       # a second wrapper copy elsewhere on PATH
printf '#!/bin/sh\necho "real-claude key=$ANTHROPIC_API_KEY args=$*"\n' > "$h/.local/bin/claude"
printf '#!/bin/sh\necho "real-grok xai=$XAI_API_KEY"\n' > "$h/.grok/bin/grok"
printf '#!/bin/sh\necho "system-opencode key=${ANTHROPIC_API_KEY:-none}"\n' > "$d/sys/opencode"
chmod +x "$h/.local/bin/claude" "$h/.grok/bin/grok" "$d/sys/opencode"
me=$(id -un)
run() { env -i HOME="$h" PATH="$d/bin:$d/bin2:$d/sys:/usr/bin:/bin" AGENTOS_LIB="$LIB" "$@"; }
as_agent() { run AGENTOS_AGENT_USER="$me" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# agent: keys loaded (trailing "=" kept), real binary from the tool dirs, argv passed through
[ "$(as_agent bash -c 'claude -p "a b"')" = 'real-claude key=sk-ant-1== args=-p a b' ] || fail claude
[ "$(as_agent bash -c grok)" = 'real-grok xai=xai-2' ] || fail grok
# found on PATH (after skipping the wrapper itself), still with keys
[ "$(as_agent bash -c opencode)" = 'system-opencode key=sk-ant-1==' ] || fail opencode-path
# missing everywhere: no self-loop (two wrapper copies on PATH), clear message, 127
set +e; out=$(as_agent timeout 5 bash -c codex 2>&1); rc=$?; set -e
[ "$rc" = 127 ] && [ "$out" = "agentos: codex is not installed for user $me" ] || fail "codex rc=$rc out=$out"
# AGENTOS_WHICH prints the resolved binary
[ "$(as_agent AGENTOS_WHICH=1 bash -c claude)" = "$h/.local/bin/claude" ] || fail which
set +e; as_agent AGENTOS_WHICH=1 bash -c codex 2>/dev/null; rc=$?; set -e; [ "$rc" = 127 ] || fail which-missing
# inside a CI run: no keys from secrets.env
[ "$(as_agent AGENTOS_CI_RUN=x bash -c claude)" = 'real-claude key= args=' ] || fail ci
# another user: no keys, no agent tool dirs, only their own PATH
[ "$(run AGENTOS_AGENT_USER=someone-else bash -c opencode)" = 'system-opencode key=none' ] || fail other-user
set +e; out=$(run AGENTOS_AGENT_USER=someone-else bash -c claude 2>&1); rc=$?; set -e
[ "$rc" = 127 ] && [[ $out == "agentos: claude is not installed for user $me" ]] || fail "other-user claude: $out"
# profile.d shares the parser: same keys and tool dirs, under sh and bash
for sh in sh bash; do
  got=$(HOME=$h AGENTOS_LIB=$LIB $sh -c '. "$1"; printf "%s|%s" "$ANTHROPIC_API_KEY" "$PATH"' sh "$R/package/etc/profile.d/agentos.sh")
  [[ $got == "sk-ant-1==|$h/.grok/bin:$h/.local/bin:"* ]] || fail "profile.d ($sh): $got"
done
echo "wrapper OK"
