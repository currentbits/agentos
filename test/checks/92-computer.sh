# shellcheck shell=bash
check_computer_venv() { vm '/usr/local/lib/agentos/venv/bin/python -c "import mcp, PIL"'; }
check_manifest_lists_python() {
  vm 'grep -q "^# agentos-computer python" /var/lib/agentos-manifest.txt && grep -qi "^mcp==1\." /var/lib/agentos-manifest.txt'
}
check_mcp_stdio_end_to_end() {
  vm 'cat > /tmp/mcp_client.py' < "$HERE/mcp_client.py" &&
  vm '/usr/local/lib/agentos/venv/bin/python /tmp/mcp_client.py stdio'
}
