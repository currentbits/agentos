#!/bin/bash
set -euo pipefail
# shellcheck source=../mkosi.extra/usr/local/lib/agentos/env.sh
. "$(dirname "$0")/../mkosi.extra/usr/local/lib/agentos/env.sh"
f=$(mktemp); trap 'rm -f "$f"' EXIT

env_set "$f" FOO bar;               [ "$(env_get "$f" FOO)" = bar ]
env_set "$f" FOO 'baz=qux&x/y';     [ "$(env_get "$f" FOO)" = 'baz=qux&x/y' ]; [ "$(grep -c '^FOO=' "$f")" = 1 ]
env_set "$f" OTHER 1;               [ "$(env_get "$f" OTHER)" = 1 ]
env_unset "$f" FOO;                 [ -z "$(env_get "$f" FOO)" ]; [ "$(env_get "$f" OTHER)" = 1 ]
! env_set "$f" 'bad-key' x 2>/dev/null
! env_set "$f" GOOD $'two\nlines' 2>/dev/null
is_secret_key ANTHROPIC_API_KEY; is_secret_key CLAUDE_CODE_OAUTH_TOKEN; is_secret_key GEMINI_API_KEY
! is_secret_key TS_AUTHKEY; ! is_secret_key AGENTOS_LAN_SSH
echo "env.sh OK"
