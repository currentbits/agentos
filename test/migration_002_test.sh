#!/bin/bash
# Unit test for migration 002: GROK_CODE_XAI_API_KEY in secrets.env becomes XAI_API_KEY (the name
# Grok reads), keeping the file's mode; an existing XAI_API_KEY wins; nothing else changes.
set -euo pipefail
M=$(cd "$(dirname "$0")/.." && pwd)/package/usr/local/lib/agentos/migrations/002-grok-key-name.sh
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; S=$d/secrets.env
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { AGENTOS_SECRETS=$S "$M"; }

printf 'ANTHROPIC_API_KEY=a\nGROK_CODE_XAI_API_KEY=xai-1==\n' > "$S"; chmod 600 "$S"
run && [ "$(cat "$S")" = $'ANTHROPIC_API_KEY=a\nXAI_API_KEY=xai-1==' ] || fail "rename: $(cat "$S")"
[ "$(stat -c %a "$S" 2>/dev/null || stat -f %Lp "$S")" = 600 ] || fail "mode changed"
run && [ "$(cat "$S")" = $'ANTHROPIC_API_KEY=a\nXAI_API_KEY=xai-1==' ] || fail "not idempotent"

printf 'XAI_API_KEY=new\nGROK_CODE_XAI_API_KEY=old\n' > "$S"
run && [ "$(cat "$S")" = 'XAI_API_KEY=new' ] || fail "existing XAI_API_KEY must win: $(cat "$S")"

rm -f "$S"; run || fail "missing file must be a no-op"
echo "migration 002 OK"
