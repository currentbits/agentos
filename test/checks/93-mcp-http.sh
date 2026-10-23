# shellcheck shell=bash
check_mcp_http_rejects_missing_or_wrong_token() {
  vm 'systemctl is-active agentos-mcp-http.service &&
      test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST http://127.0.0.1:8765/mcp)" = 401 &&
      test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST -H "Authorization: Bearer wrong" http://127.0.0.1:8765/mcp)" = 401 &&
      test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST -H "Authorization: bearer $(printf %064d 0)" http://127.0.0.1:8765/mcp)" = 401'
}
check_mcp_http_end_to_end() {
  vm 'cat > /tmp/mcp_client.py' < "$HERE/mcp_client.py" &&
  vm 't=$(sudo cat /etc/agentos/mcp-token) && /usr/local/lib/agentos/venv/bin/python /tmp/mcp_client.py http http://127.0.0.1:8765/mcp "$t"'
}
check_mcp_http_not_reachable_from_lan() {
  vm 'test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST "http://$(hostname -I | awk "{print \$1}"):8765/mcp")" = 401' &&
  ! curl -s -m 5 -X POST "http://127.0.0.1:$HOSTPORT_MCP/mcp" >/dev/null
}
check_mcp_http_unit_hardened() {
  # systemd lists Requires= members in a random order per boot, so each property is asserted
  # independently rather than via one grep over sorted `systemctl show` output.
  vm 'test "$(systemctl show agentos-mcp-http.service -p User --value)" = agent &&
      test "$(systemctl show agentos-mcp-http.service -p NoNewPrivileges --value)" = yes &&
      test "$(systemctl show agentos-mcp-http.service -p ProtectSystem --value)" = strict &&
      systemctl show agentos-mcp-http.service -p Requires --value | grep -qw agentos-firewall.service &&
      ! systemctl cat agentos-mcp-http.service | grep -q "^Environment=.*TOKEN"'
}
check_mcp_http_accepts_tailnet_host() {
  # Real tailnet clients send Host: agentos-xyz:8765, not localhost. mcp's DNS-rebinding Host-header
  # check must not reject that; bearer auth is our gate, not the Host header.
  vm 't=$(sudo cat /etc/agentos/mcp-token) &&
      code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" -X POST http://127.0.0.1:8765/mcp \
        -H "Authorization: Bearer $t" -H "Host: agentos-test:8765" \
        -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
        --data-raw "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}") &&
      test "$code" != 421 && test "$code" != 403'
}
