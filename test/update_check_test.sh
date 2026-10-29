#!/bin/bash
# Unit test for agentos-update --check, --notice, --issue and --version: update available (notes cut
# to 4 KB, control bytes and C1 controls stripped, other UTF-8 kept), up to date, a bad signature,
# no network, a disabled source, no candidate in the index, an invalid candidate version, a
# half-configured package (a failed migration), a brief lock wait, and a running update. apt-get,
# apt-cache, dpkg-query and curl are fakes; dpkg (version compare) and jq are real.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=$R/package/usr/local/bin/agentos-update
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/state"
touch "$d/lock" "$d/checklock"
src=$d/agentos.sources
printf 'Types: deb\nURIs: https://example.github.io/agentos/apt/\nSuites: stable\nComponents: main\nSigned-By: /usr/share/keyrings/agentos-archive.gpg\n' > "$src"
cat > "$d/bin/apt-get" <<EOS
#!/bin/sh
echo "\$*" >> "$d/apt-get.calls"
case "\$(cat "$d/apt")" in
  ok) exit 0 ;;
  badsig) echo "W: An error occurred during the signature verification. The repository is not updated and the previous index files will be used."
          echo "E: Failed to fetch https://example.github.io/agentos/apt/dists/stable/InRelease  Sub-process /usr/bin/sqv returned an error code (1), error message is: Missing key 0123ABCD, which is needed to verify signature."
          echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100 ;;
  nonet)  echo "E: Failed to fetch https://example.github.io/agentos/apt/dists/stable/InRelease  Could not resolve 'example.github.io'"
          echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100 ;;
esac
EOS
printf '#!/bin/sh\nprintf "agentos:\\n  Installed: 1.0.0\\n  Candidate: %%s\\n" "$(cat %s/cand)"\n' "$d" > "$d/bin/apt-cache"
# -f '${Version}' (installed()) always reports 1.0.0; -f '${db:Status-Abbrev}' reports "$d/status"'s
# content, defaulting to "ii " (fully configured) when that file doesn't exist.
cat > "$d/bin/dpkg-query" <<EOS
#!/bin/sh
case "\$3" in
  *Status-Abbrev*) cat "$d/status" 2>/dev/null || printf 'ii ' ;;
  *) printf 1.0.0 ;;
esac
EOS
cat > "$d/bin/curl" <<EOS
#!/bin/bash
for a; do u=\$a; done
echo "\$u" >> "$d/curl.calls"
# Write the response in 1000-byte pieces via the printf builtin (no fork per write) with a short
# pause between them, so an early reader (head -c N) can hang up mid-stream and SIGPIPE kills us
# outright -- the same way real curl dies when the pipe closes while it is still writing the body.
content=\$(cat "$d/notes")
off=0
while [ "\$off" -lt "\${#content}" ]; do
  printf '%s' "\${content:\$off:1000}"
  off=\$((off+1000))
  sleep 0.1
done
EOS
chmod +x "$d/bin/"*
run() { env PATH="$d/bin:$PATH" AGENTOS_STATE="$d/state" AGENTOS_SOURCES="$src" AGENTOS_ISSUE="$d/issue.d/60-agentos-update.issue" \
          AGENTOS_UPDATE_LOCK="$d/lock" AGENTOS_UPDATE_CHECK_LOCK="$d/checklock" "$U" "$@"; }
j() { jq -r "$1" "$d/state/update.json"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
LINE='AgentOS 1.1.0 available: run agentos-update (or use the web UI)'

# An update is available: notes are fetched for the signed candidate and cut to 4 KB.
echo ok > "$d/apt"; echo 1.1.0 > "$d/cand"; { echo '<b>What is new</b>'; head -c 6000 /dev/zero | tr '\0' x; } > "$d/notes"
out=$(run --check)
[[ $out == "AgentOS 1.1.0 is available (installed: 1.0.0)"* ]] || fail "summary: $out"
[ "$(j '[.installed, .available, .notes_url, .error] | @json')" = '["1.0.0","1.1.0","https://example.github.io/agentos/apt/notes/1.1.0.md",null]' ] || fail "available: $(cat "$d/state/update.json")"
[ "$(j '.notes | length')" = 4096 ] && [ "$(j '.notes' | head -1)" = '<b>What is new</b>' ] || fail "notes"
[[ $(j .checked_at) =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "checked_at"
[ "$(stat -c %a "$d/state/update.json")" = 644 ] || fail "update.json mode"
[ "$(cat "$d/apt-get.calls")" = "update -qq --error-on=any -o Dir::Etc::sourcelist=$src -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0" ] || fail "apt-get args: $(cat "$d/apt-get.calls")"
[ "$(cat "$d/curl.calls")" = https://example.github.io/agentos/apt/notes/1.1.0.md ] || fail "curl url"
[ "$(run --notice)" = "$LINE" ] || fail "notice"
[ "$(cat "$d/issue.d/60-agentos-update.issue")" = "$LINE" ] || fail "issue"
[ "$(run --version)" = 1.0.0 ] || fail "--version"

# Control bytes (e.g. a real ESC) are stripped from notes once, before they're stored or printed.
printf 'clean\033[2Jtext\ttab\n' > "$d/notes"
run --check >/dev/null
[ "$(j '.notes')" = "$(printf 'clean[2Jtext\ttab')" ] || fail "control bytes: $(j '.notes')"

# C1 controls (U+0080-U+009F, UTF-8 \xC2\x80-\xC2\x9F) are stripped too, e.g. a NEL (\xC2\x85); an
# ordinary multi-byte UTF-8 character whose bytes fall in the same 0x80-0x9F range only as a
# continuation byte (e.g. \xC3\xA9, "e" with an acute accent) must survive untouched.
printf 'before\xc2\x85\xc3\xa9after\n' > "$d/notes"
run --check >/dev/null
[ "$(j '.notes')" = "$(printf 'before\xc3\xa9after')" ] || fail "C1 controls: $(j '.notes')"

# Up to date: no notes fetched, the notices go away.
echo 1.0.0 > "$d/cand"; : > "$d/curl.calls"
[ "$(run --check)" = "AgentOS 1.0.0 is up to date" ] || fail "up to date summary"
[ "$(j '[.available, .notes_url, .notes, .error] | @json')" = '[null,null,"",null]' ] || fail "up to date"
[ -z "$(run --notice)" ] && [ ! -e "$d/issue.d/60-agentos-update.issue" ] && [ ! -s "$d/curl.calls" ] || fail "up to date notices"

# A bad signature: an error with apt's cause, never "available" (the old lists still say 1.1.0).
echo badsig > "$d/apt"; echo 1.1.0 > "$d/cand"
[[ $(run --check) == "AgentOS update check failed: Failed to fetch"* ]] || fail "badsig summary"
[ "$(j .available)" = null ] && [[ $(j .error) == *"Missing key 0123ABCD, which is needed to verify signature."* ]] || fail "badsig: $(j .error)"
[ -z "$(run --notice)" ] || fail "badsig notice"

# No network.
echo nonet > "$d/apt"
run --check >/dev/null
[ "$(j .available)" = null ] && [[ $(j .error) == *"Could not resolve 'example.github.io'" ]] || fail "nonet: $(j .error)"

# A development build: the source is disabled, apt is not asked.
echo ok > "$d/apt"; : > "$d/apt-get.calls"; sed -i '1i Enabled: no' "$src"
run --check >/dev/null
[ "$(j .error)" = "the AgentOS update source is disabled (development build)" ] && [ ! -s "$d/apt-get.calls" ] || fail "disabled"
sed -i '1d' "$src"

# A failed migration leaves agentos half-configured: ${Version} already reports the new version,
# but ${db:Status-Abbrev} isn't "ii ". --check must say so (and never apt-get update), not "up to
# date" or attempt-and-silently-skip.
printf 'hF ' > "$d/status"
[[ $(run --check) == "AgentOS update check failed: agentos is not fully configured (a migration failed): run agentos-update"* ]] || fail "half-configured summary"
[ "$(j .available)" = null ] && [ "$(j .error)" = "agentos is not fully configured (a migration failed): run agentos-update" ] || fail "half-configured: $(j .error)"
rm -f "$d/status"

# A candidate that fails the version regex is an error ("invalid version"), never "up to date" or
# silently dropped back to it (it would otherwise reach /run/issue.d and the MOTD unvalidated).
printf '1.1.0\033[2J\n' > "$d/cand"
[[ $(run --check) == "AgentOS update check failed: the repo offers an invalid version"* ]] || fail "invalid candidate summary"
[ "$(j .available)" = null ] && [ "$(j .error)" = "the repo offers an invalid version" ] || fail "invalid candidate: $(j .error)"
printf '{"available":"9.9\\\\nroot"}' > "$d/state/update.json"
[ -z "$(run --notice)" ] || fail "hostile update.json"

# The repo is reachable but apt has no agentos candidate at all: an error, not "up to date".
echo '(none)' > "$d/cand"
[[ $(run --check) == "AgentOS update check failed:"* ]] || fail "no candidate summary"
[ "$(j .available)" = null ] && [ "$(j .error)" != null ] || fail "no candidate: $(j .error)"

# A brief holder of check()'s own lock (another check racing it: the daily timer vs. a web UI
# "Check now") doesn't make the check skip: it waits (flock -w 10) and still succeeds once the
# holder releases a couple of seconds later.
echo ok > "$d/apt"; echo 1.1.0 > "$d/cand"
( flock 9; sleep 2; ) 9<"$d/checklock" &
holder=$!
out=$(run --check)
wait "$holder"
[[ $out == "AgentOS 1.1.0 is available"* ]] || fail "brief lock: $out"

# An update is running (begin() holds both locks for longer than the 10 s wait): the check gives
# up and is skipped, update.json untouched -- and, separately, the web UI's "running" probe (a
# bare flock -n on just $d/lock) is unaffected by a check alone (asserted below), only by this.
cp "$d/state/update.json" "$d/before"
( flock 9; flock 8; run --check 2>"$d/err"; ) 9<"$d/lock" 8<"$d/checklock"
cmp -s "$d/state/update.json" "$d/before" && grep -qx 'agentos-update is running; check skipped' "$d/err" || fail "lock"

# The bug this is fixing: a check in progress (holding only its own lock) must not make the web
# UI's "running" probe (flock -n on $d/lock alone) report busy -- only a real update/rollback,
# which holds $d/lock too, does that.
( flock 9; sleep 2; ) 9<"$d/checklock" &
holder=$!
sleep 0.3
flock -n "$d/lock" true || fail "a check in progress made the update lock look held"
wait "$holder"
echo "update check OK"
