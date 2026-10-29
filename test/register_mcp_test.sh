#!/bin/bash
# Unit test for register-mcp: a fresh registration, a plain run leaving existing entries alone, and
# --update rewriting AgentOS's own entries (a changed tool_timeout_sec) while keeping the user's
# entries byte for byte, idempotently. claude and agentos-ci are fakes.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
RM=$R/package/usr/local/lib/agentos/register-mcp
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
h=$d/home; mkdir -p "$h" "$d/bin"
# claude: "mcp get|add|remove" against a "name command" list in $d/claude.
cat > "$d/bin/claude" <<EOS
#!/bin/bash
db=$d/claude; touch "\$db"
case "\$2" in
  get) grep -q "^\$3 " "\$db" ;;
  add) [ "\$3 \$4" = "--scope user" ] && ! grep -q "^\$5 " "\$db" && echo "\$5 \$7" >> "\$db" ;;
  remove) grep -v "^\$5 " "\$db" > "\$db.t" || true; mv "\$db.t" "\$db" ;;
esac
EOS
printf '#!/bin/sh\necho "$*" >> %s/skill\n' "$d" > "$d/bin/agentos-ci"
chmod +x "$d/bin/"*
run() { env -i HOME="$h" PATH="$d/bin:/usr/bin:/bin" AGENTOS_CI="$d/bin/agentos-ci" "$RM" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fresh box: every CLI gets both servers; Codex's agentos-ci has the timeout.
run
[ "$(cat "$d/claude")" = $'agentos-computer /usr/local/bin/agentos-computer\nagentos-ci /usr/local/bin/agentos-ci-mcp' ] || fail "claude fresh"
grep -A2 '^\[mcp_servers\.agentos-ci\]$' "$h/.codex/config.toml" | grep -qx 'tool_timeout_sec = 1900' || fail "codex fresh"
grep -qx '\[mcp\]' "$h/.grok/config.toml" || fail "grok [mcp]"
jq -e '.mcp["agentos-ci"].command == ["/usr/local/bin/agentos-ci-mcp"] and .mcp["agentos-computer"].enabled' "$h/.config/opencode/opencode.json" >/dev/null || fail "opencode fresh"
[ "$(cat "$d/skill")" = install-skill ] || fail "skill"

# A box from an older release: old values in AgentOS's entries, the user's own entries around them.
cat > "$h/.codex/config.toml" <<'T'
model = "gpt-5"

[mcp_servers.mine]
command = "/opt/mine"

[mcp_servers.agentos-ci]
command = "/usr/local/bin/agentos-ci-mcp"
tool_timeout_sec = 1800

[mcp_servers.agentos-ci.env]
OLD = "1"

[mcp_servers.agentos-computer]
command = "/usr/local/bin/agentos-computer"

[profiles.fast]
model = "gpt-5-mini"
T
printf '{"$schema":"x","mcp":{"mine":{"type":"local","command":["/opt/mine"]},"agentos-ci":{"type":"local","command":["/old"],"enabled":false}},"theme":"dark"}\n' > "$h/.config/opencode/opencode.json"
printf 'agentos-ci /old\nmine /opt/mine\n' > "$d/claude"
cp "$h/.codex/config.toml" "$d/codex.before"

# Without --update nothing of ours changes.
run
cmp -s "$h/.codex/config.toml" "$d/codex.before" || fail "plain run changed codex"
grep -qx 'agentos-ci /old' "$d/claude" || fail "plain run changed claude"

# --update rewrites only AgentOS's entries; running it again changes nothing.
run --update
want='model = "gpt-5"

[mcp_servers.mine]
command = "/opt/mine"

[profiles.fast]
model = "gpt-5-mini"

[mcp_servers.agentos-computer]
command = "/usr/local/bin/agentos-computer"

[mcp_servers.agentos-ci]
command = "/usr/local/bin/agentos-ci-mcp"
tool_timeout_sec = 1900'
[ "$(cat "$h/.codex/config.toml")" = "$want" ] || { diff <(echo "$want") "$h/.codex/config.toml"; fail "codex --update"; }
cp "$h/.codex/config.toml" "$d/codex.once"
run --update
cmp -s "$h/.codex/config.toml" "$d/codex.once" || fail "--update not idempotent"
grep -qx 'mine /opt/mine' "$d/claude" && grep -qx 'agentos-ci /usr/local/bin/agentos-ci-mcp' "$d/claude" || fail "claude --update: $(cat "$d/claude")"
jq -e '.mcp.mine.command == ["/opt/mine"] and .theme == "dark" and .mcp["agentos-ci"] == {type: "local", command: ["/usr/local/bin/agentos-ci-mcp"], enabled: true}' \
  "$h/.config/opencode/opencode.json" >/dev/null || fail "opencode --update"
[ "$(grep -c '^\[mcp\]$' "$h/.grok/config.toml")" = 1 ] || fail "grok [mcp] duplicated"
[ "$(wc -l < "$d/skill")" = 4 ] || fail "skill install runs every time"
echo "register-mcp OK"
