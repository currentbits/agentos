#!/bin/bash
# Unit test for agentos-update --check, --notice, --issue and --version: update available (notes cut
# to 4 KB), up to date, a bad signature, no network, a disabled source, a hostile version string,
# and a running update. apt-get, apt-cache, dpkg-query and curl are fakes; dpkg (version compare)
# and jq are real.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=$R/package/usr/local/bin/agentos-update
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/state"
touch "$d/lock"
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
printf '#!/bin/sh\nprintf 1.0.0\n' > "$d/bin/dpkg-query"
printf '#!/bin/sh\nfor a; do u=$a; done\necho "$u" >> %s/curl.calls\ncat %s/notes\n' "$d" "$d" > "$d/bin/curl"
chmod +x "$d/bin/"*
run() { env PATH="$d/bin:$PATH" AGENTOS_STATE="$d/state" AGENTOS_SOURCES="$src" AGENTOS_ISSUE="$d/issue.d/60-agentos-update.issue" \
          AGENTOS_UPDATE_LOCK="$d/lock" "$U" "$@"; }
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

# A candidate that isn't a plain version is never offered (it would reach /run/issue.d and the MOTD).
printf '1.1.0\\e[2J\n' > "$d/cand"; run --check >/dev/null
[ "$(j .available)" = null ] || fail "hostile candidate"
printf '{"available":"9.9\\\\nroot"}' > "$d/state/update.json"
[ -z "$(run --notice)" ] || fail "hostile update.json"

# An update is running (it holds the lock): the check is skipped, update.json untouched.
cp "$d/state/update.json" "$d/before"
( flock 9; run --check 2>"$d/err"; ) 9<"$d/lock"
cmp -s "$d/state/update.json" "$d/before" && grep -qx 'agentos-update is running; check skipped' "$d/err" || fail "lock"
echo "update check OK"
