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
weird='a b $(touch /tmp/agentos-pwned) "q" $HOME'
env_set "$f" WEIRD "$weird";        [ "$(env_get "$f" WEIRD)" = "$weird" ]
# NOTE: "! env_get ... 'BAD.KEY'" (as worded in the brief) would not abort this
# script on failure: under `set -e`, a bare `! cmd` is exempt from errexit, so a
# wrongly-successful env_get would be silently ignored. Use an explicit guard instead.
env_get "$f" 'BAD.KEY' >/dev/null 2>&1 && { echo "env_get accepted invalid key" >&2; exit 1; }
is_secret_key ANTHROPIC_API_KEY; is_secret_key CLAUDE_CODE_OAUTH_TOKEN; is_secret_key GEMINI_API_KEY
! is_secret_key TS_AUTHKEY; ! is_secret_key AGENTOS_LAN_SSH
echo "env.sh OK"

# profile.d secrets parsing: values ending in "=" (a single trailing "=" is what `IFS== read` drops) and a last line without newline
h=$(mktemp -d); trap 'rm -rf "$f" "$h"' EXIT
mkdir -p "$h/.config/agentos"; printf 'PAD_TOKEN=abc==\nPAD1_TOKEN=abc=\nNOEOL_TOKEN=x' > "$h/.config/agentos/secrets.env"
for sh in sh bash; do  # dash and bash split "read" fields differently; the agent's login shell is bash
  got=$(HOME=$h AGENTOS_LIB="$(dirname "$0")/../mkosi.extra/usr/local/lib/agentos" $sh -c '. "$1"; printf "%s|%s|%s" "$PAD_TOKEN" "$PAD1_TOKEN" "$NOEOL_TOKEN"' sh "$(dirname "$0")/../mkosi.extra/etc/profile.d/agentos.sh")
  [ "$got" = 'abc==|abc=|x' ] || { echo "profile.d parse ($sh): got '$got'" >&2; exit 1; }
done
echo "profile.d OK"

# validate_setting: the values agentos-config accepts (empty = default, always accepted)
ok()  { validate_setting "$1" "$2" || { echo "should accept $1='$2'" >&2; exit 1; }; }
bad() { if validate_setting "$1" "$2" 2>/dev/null; then echo "should reject $1='$2'" >&2; exit 1; fi; }
ok AGENTOS_LAN_SSH 1; ok AGENTOS_LAN_SSH 0; ok AGENTOS_LAN_SSH ''; bad AGENTOS_LAN_SSH yes; bad AGENTOS_WEB 2
ok AGENTOS_CONSOLE terminal; bad AGENTOS_CONSOLE gui
ok AGENTOS_MAX_DESKTOPS 16; bad AGENTOS_MAX_DESKTOPS 17; bad AGENTOS_MAX_DESKTOPS 0; bad AGENTOS_MAX_DESKTOPS 08
ok AGENTOS_SCREENSHOT_WIDTH 640; ok AGENTOS_SCREENSHOT_WIDTH 1920; bad AGENTOS_SCREENSHOT_WIDTH 639; bad AGENTOS_SCREENSHOT_WIDTH 1921
ok AGENTOS_DESKTOP_IDLE_MINUTES 0; ok AGENTOS_DESKTOP_IDLE_MINUTES 999999; bad AGENTOS_DESKTOP_IDLE_MINUTES 1000000; bad AGENTOS_DESKTOP_IDLE_MINUTES -1
ok AGENTOS_WEB_USERS a@b.com; ok AGENTOS_WEB_USERS 'a@b.com,C@github'; bad AGENTOS_WEB_USERS 'a@b.com, c@d'; bad AGENTOS_WEB_USERS nobody
bad AGENTOS_WEB_USERS 'a@b,'; bad AGENTOS_WEB_USERS $'a@b\nc@d'
ok SOME_OTHER_KEY anything
[ "$(validate_setting AGENTOS_WEB x 2>&1)" = "AGENTOS_WEB must be 0 or 1" ]
echo "validate_setting OK"
