# shellcheck shell=bash
check_claude_mcp_registered()   { vml 'claude mcp get agentos-computer 2>&1 | grep -q /usr/local/bin/agentos-computer'; }
check_claude_mcp_connects()     { vml 'claude mcp list 2>&1 | grep agentos-computer | grep -qi connected'; }
check_codex_mcp_registered()    { vml 'codex mcp list 2>&1 | grep -q agentos-computer'; }
check_grok_mcp_registered()     { vml 'grok mcp list 2>&1 | grep -q agentos-computer' && vm 'grep -qx "max_output_bytes = 4000000" ~/.grok/config.toml'; }
check_opencode_mcp_registered() {
  vm 'jq -e ".mcp[\"agentos-computer\"] == {\"type\":\"local\",\"command\":[\"/usr/local/bin/agentos-computer\"],\"enabled\":true}" ~/.config/opencode/opencode.json >/dev/null'
}
check_register_idempotent() {
  vm 'sudo agentos-config apply &&
      test "$(grep -c "^\[mcp_servers\.agentos-computer\]" ~/.codex/config.toml)" = 1 &&
      test "$(grep -c "^\[mcp_servers\.agentos-computer\]" ~/.grok/config.toml)" = 1 &&
      test "$(grep -c "^\[mcp\]" ~/.grok/config.toml)" = 1'
}
check_register_keeps_user_config() {
  vm 'printf "\n[mcp_servers.mine]\ncommand = \"/bin/true\"\n" >> ~/.codex/config.toml &&
      sudo agentos-config apply && grep -q "^\[mcp_servers\.mine\]" ~/.codex/config.toml'
}
