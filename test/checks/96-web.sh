# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.
check_web_service_loopback_only() {
  # Type=simple reports "active" the instant systemd forks node, before fastify finishes loading
  # and calls listen(); measured ~300-400ms on devvm. The preceding check_web_disable_and_enable
  # exits its wait loop at that same instant, so give the bind a few seconds' grace here too.
  vm 'for _ in $(seq 1 50); do
        systemctl is-active --quiet agentos-web.service && ss -Htln "sport = :7070" | grep -q . && break
        sleep 0.1
      done
      systemctl is-active --quiet agentos-web.service &&
      test "$(ss -Htln "sport = :7070" | awk "{print \$4}")" = 127.0.0.1:7070'
}
check_web_unit_shape() {
  vm 'for p in User=agent KillMode=process NoNewPrivileges=no PrivateTmp=no ProtectHome=no Restart=on-failure SyslogIdentifier=agentos-web; do
        test "$(systemctl show agentos-web.service -p "${p%%=*}" --value)" = "${p#*=}" || { echo "want $p"; exit 1; }
      done'
}
check_web_conf_published() {
  # No tailnet in the smoke VM: serve is skipped, and no console warning is shown.
  vm 'test "$(stat -c %a /etc/agentos/web.conf)" = 644 && grep -qx ENABLED=1 /etc/agentos/web.conf &&
      grep -qx SERVE=tailscale-down /etc/agentos/web.conf && test ! -e /run/issue.d/50-agentos-web.issue'
}
check_web_disable_and_enable() {
  local rc=0
  vm 'sudo agentos-config set AGENTOS_WEB 0 && sudo agentos-config apply &&
      for _ in $(seq 1 30); do systemctl is-active --quiet agentos-web.service || break; sleep 1; done &&
      ! systemctl is-active --quiet agentos-web.service && ! systemctl is-enabled --quiet agentos-web.service &&
      grep -qx ENABLED=0 /etc/agentos/web.conf && grep -qx SERVE=off /etc/agentos/web.conf' || rc=1
  vm 'sudo agentos-config set AGENTOS_WEB 1 && sudo agentos-config apply &&
      for _ in $(seq 1 30); do systemctl is-active --quiet agentos-web.service && exit 0; sleep 1; done; exit 1' || rc=1
  return "$rc"
}
check_web_size() {
  local mb; mb=$(vm 'du -sm /usr/local/lib/agentos/web | cut -f1')
  echo "web UI: ${mb} MiB (spec budget: +60-100 MB)"; [ "$mb" -le 100 ]
}
check_manifest_lists_web() {
  vm 'grep -qx "# agentos-web npm" /var/lib/agentos-manifest.txt && grep -qx "fastify@5.12.7" /var/lib/agentos-manifest.txt'
}
noseed_web_active() { qga 'systemctl is-active agentos-web.service'; }

# API checks. $WEB is prepended to remote commands: U = base URL, w = authenticated curl, wm = w plus
# the CSRF headers a browser sends on a mutating request, code = HTTP status only, up = wait for 200.
WEB='U=http://127.0.0.1:7070
w()    { curl -sS -m 120 -H "Tailscale-User-Login: smoke@example.com" "$@"; }
wm()   { w -H "Origin: http://127.0.0.1:7070" -H "X-AgentOS: 1" -H "Content-Type: application/json" "$@"; }
code() { curl -s -o /dev/null -m 30 -w "%{http_code}" "$@"; }
up()   { for _ in $(seq 1 30); do test "$(code -H "Tailscale-User-Login: smoke@example.com" $U/api/sessions)" = 200 && return 0; sleep 1; done; return 1; }
'
web_users() {  # allowlist smoke@example.com; idempotent, because apply is slow
  vm 'grep -qx "USERS=smoke@example.com" /etc/agentos/web.conf ||
      { sudo agentos-config set AGENTOS_WEB_USERS smoke@example.com && sudo agentos-config apply; }' &&
  vm "$WEB"'up'
}
check_web_identity_codes() {
  web_users && vm "$WEB"'
    test "$(code $U/api/sessions)" = 401 &&
    test "$(code -H "Tailscale-User-Login: eve@example.com" $U/api/sessions)" = 403 &&
    test "$(code -H "Tailscale-User-Login: Smoke@Example.COM" $U/api/sessions)" = 200 &&
    test "$(code -H "Tailscale-User-Login: smoke@example.com" -H "Host: evil.example:7070" $U/api/sessions)" = 403'
}
check_web_loopback_uids() {
  # Only root (tailscaled) and agent may connect to 7070: nobody gets a TCP reset (curl exit 7),
  # while agent and root still reach the app (401 without identity).
  web_users && vm "$WEB"'
    sudo nft list chain inet agentos output | grep -q "tcp dport 7070" &&
    { sudo runuser -u nobody -- curl -s -o /dev/null -m 3 $U/; test $? = 7; } &&
    test "$(code $U/api/sessions)" = 401 &&
    test "$(sudo curl -s -o /dev/null -m 3 -w "%{http_code}" $U/api/sessions)" = 401'
}
check_web_novnc_files_only() {
  # /novnc/ serves core/ (and vendor/) for DesktopView, never noVNC'\''s own vnc.html app.
  web_users && vm "$WEB"'
    test "$(code -H "Tailscale-User-Login: smoke@example.com" $U/novnc/core/rfb.js)" = 200 &&
    ! w $U/novnc/vnc.html | grep -qi novnc'
}
check_web_csrf() {
  web_users && vm "$WEB"'
    L="Tailscale-User-Login: smoke@example.com"
    test "$(code -X POST -H "$L" -H "Origin: $U" $U/api/desktops)" = 403 &&
    test "$(code -X POST -H "$L" -H "X-AgentOS: 1" -H "Origin: https://evil.example" $U/api/desktops)" = 403 &&
    test "$(code -X POST -H "$L" -H "X-AgentOS: 1" $U/api/desktops)" = 403'
}
check_web_not_configured_page() {
  local rc=0
  vm "$WEB"'sudo agentos-config set AGENTOS_WEB_USERS "" && sudo agentos-config apply &&
    test "$(code -H "Tailscale-User-Login: smoke@example.com" $U/api/sessions)" = 403 &&
    w $U/ | grep -q "sudo agentos-config set AGENTOS_WEB_USERS smoke@example.com"' || rc=1
  web_users || rc=1
  return "$rc"
}
check_web_session_terminal() {
  # Create via the API, type through the terminal WebSocket, survive a service restart
  # (KillMode=process), stop (sidecar stays, marked ended), remove.
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" && vm "$WEB"'
    wm -X POST -d "{\"cli\":\"shell\",\"name\":\"smoke\"}" $U/api/sessions | grep -q "\"id\":\"ag-smoke\"" &&
    tmux has-session -t =ag-smoke &&
    node /tmp/web_ws.mjs term ag-smoke "echo smoke-\$((40+2))" smoke-42 &&
    tmux has-session -t =ag-smoke &&
    sudo systemctl restart agentos-web.service && up && tmux has-session -t =ag-smoke &&
    wm -X POST $U/api/sessions/ag-smoke/stop | grep -q "\"ok\":true" &&
    ! tmux has-session -t =ag-smoke 2>/dev/null &&
    w $U/api/sessions | grep -q "\"id\":\"ag-smoke\"[^}]*\"state\":\"ended\"" &&
    wm -X DELETE $U/api/sessions/ag-smoke | grep -q "\"ok\":true"'
}
check_web_desktop_thumbnail_vnc_destroy() {
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" && vm "$WEB"'
    n=$(wm -X POST $U/api/desktops | sed -n "s/.*\"id\":\([0-9]*\).*/\1/p") && test -n "$n" &&
    systemctl is-active --quiet "agentos-desktop@$n.service" &&
    w -o /tmp/thumb.png "$U/api/desktops/$n/thumbnail" &&
    python3 -c "import struct; d=open(\"/tmp/thumb.png\",\"rb\").read(); assert d[:8]==b\"\x89PNG\r\n\x1a\n\"; assert struct.unpack(\">II\", d[16:24])==(480,270), d[16:24]" &&
    node /tmp/web_ws.mjs vnc "$n" &&
    wm -X DELETE "$U/api/desktops/$n" | grep -q "\"ok\":true" &&
    ! systemctl is-active --quiet "agentos-desktop@$n.service"'
}
check_web_settings_roundtrip_and_secrets() {
  local rc=0
  web_users && vm "$WEB"'
    wm -X PUT -d "{\"values\":{\"AGENTOS_MAX_DESKTOPS\":\"6\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    w $U/api/settings | grep -q "\"AGENTOS_MAX_DESKTOPS\":\"6\"" &&
    wm -X PUT -d "{\"values\":{\"AGENTOS_MAX_DESKTOPS\":\"99\"}}" $U/api/settings | grep -q "\"field\":\"AGENTOS_MAX_DESKTOPS\"" &&
    wm -X PUT -d "{\"values\":{\"GROK_CODE_XAI_API_KEY\":\"sk-smoke-SECRET-7\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    grep -qx GROK_CODE_XAI_API_KEY=sk-smoke-SECRET-7 ~/.config/agentos/secrets.env &&
    s=$(w $U/api/settings) && echo "$s" | grep -q "\"GROK_CODE_XAI_API_KEY\":true" && ! echo "$s" | grep -q sk-smoke &&
    ! sudo journalctl -b --no-pager | grep -q sk-smoke-SECRET-7 &&
    wm -X PUT -d "{\"values\":{\"GROK_CODE_XAI_API_KEY\":\"\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    w $U/api/settings | grep -q "\"GROK_CODE_XAI_API_KEY\":false"' || rc=1
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 8 && sudo agentos-config apply' || rc=1
  return "$rc"
}
check_web_audit_line() {
  web_users && vm "$WEB"'
    wm -X PUT -d "{\"values\":{\"AGENTOS_DESKTOP_IDLE_MINUTES\":\"120\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    for _ in 1 2 3 4 5; do
      sudo journalctl -b -t agentos-web -p notice --no-pager -o cat |
        grep -qx "smoke@example.com config-set AGENTOS_DESKTOP_IDLE_MINUTES" && exit 0
      sleep 1
    done; exit 1'
}
check_web_e2e() {
  web_users && vm 'cat > /tmp/web_e2e.mjs' < "$HERE/web_e2e.mjs" &&
  vm 'LOGIN=smoke@example.com PLAYWRIGHT=$HOME/.local/lib/node_modules/playwright node /tmp/web_e2e.mjs'
}
