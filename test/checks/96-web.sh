# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.
# shellcheck disable=SC2154 # HOSTPORT_HTTPS, HOSTPORT_7443 come from smoke.sh
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
      grep -qx SERVE=tailscale-down /etc/agentos/web.conf && grep -qx LAN=0 /etc/agentos/web.conf &&
      grep -qx "Web UI: off. Enable it with sudo agentos-config (Tailscale or LAN access)" /run/issue.d/50-agentos-web.issue'
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
    wm -X PUT -d "{\"values\":{\"XAI_API_KEY\":\"sk-smoke-SECRET-7\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    grep -qx XAI_API_KEY=sk-smoke-SECRET-7 ~/.config/agentos/secrets.env &&
    s=$(w $U/api/settings) && echo "$s" | grep -q "\"XAI_API_KEY\":true" && ! echo "$s" | grep -q sk-smoke &&
    ! sudo journalctl -b --no-pager | grep -q sk-smoke-SECRET-7 &&
    wm -X PUT -d "{\"values\":{\"XAI_API_KEY\":\"\"}}" $U/api/settings | grep -q "\"ok\":true" &&
    w $U/api/settings | grep -q "\"XAI_API_KEY\":false"' || rc=1
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

# LAN access (AGENTOS_WEB_LAN), from the host: QEMU forwards $HOSTPORT_HTTPS to the guest's 443, and
# --connect-to keeps the guest's own address in the URL, so Host and Origin are what a LAN browser
# sends. The guest sees these connections come from 10.0.2.2. $HOSTPORT_7443 forwards straight to
# the guest's 7443, bypassing the redirect: a "LAN client" that skips port 443 (finding 2).
GIP=10.0.2.15   # the guest's address on QEMU's user network
LANPW='smoke LAN pw 7'
LANPW2='smoke LAN pw 8'   # a password change (finding 5): must differ from LANPW
lan()      { curl -sk -m 15 --connect-to "$GIP:443:127.0.0.1:$HOSTPORT_HTTPS" "$@"; }
lan_code() { lan -o /dev/null -w '%{http_code}' "$@"; }
lan_post() { lan_code -X POST -H "Origin: https://$GIP" -H 'X-AgentOS: 1' -H 'Content-Type: application/json' "$@"; }
# Plain http:// to the guest's port 80: "<code> <Location>".
lan_http() { curl -s -m 8 --connect-to "$GIP:80:127.0.0.1:$HOSTPORT_80" -o /dev/null -w '%{http_code} %{redirect_url}' "$@"; }
lan_up()   { vm 'for _ in $(seq 1 30); do ss -Htln "sport = :7443" | grep -q . && exit 0; sleep 1; done; exit 1'; }

check_web_lan_closed_when_off() {
  # Off (the default): no listener, nothing redirected, nothing answers on 443.
  vm 'grep -qx LAN=0 /etc/agentos/web.conf && s=$(sudo nft list set inet agentos lan_web) && ! grep -qw 443 <<< "$s" &&
      s=$(sudo nft list set inet agentos lan_http) && ! grep -qw 80 <<< "$s" &&
      ! ss -Htln "sport = :7443" | grep -q . && ! ss -Htln "sport = :7480" | grep -q .' &&
  [ "$(lan_code -m 8 "https://$GIP/")" = 000 ] && [ "$(lan_http "http://$GIP/")" = "000 " ]
}
check_web_lan_firewall_order() {
  # Finding 2: 7443 is reachable only as redirected from 443 (ct status dnat); that guard and the
  # explicit drop beneath it must come before the tailscale0 and lo accepts, or either would let a
  # direct (non-redirected) connection to 7443 through, including from a tailnet peer.
  vm 'r=$(sudo nft list chain inet agentos input) &&
      dnat=$(grep -n "tcp dport { 7443, 7480 } ct status dnat accept" <<< "$r" | cut -d: -f1) &&
      drop=$(grep -n "tcp dport { 7443, 7480 } drop" <<< "$r" | cut -d: -f1) &&
      ts=$(grep -n "iifname \"tailscale0\" accept" <<< "$r" | cut -d: -f1) &&
      lo=$(grep -n "iif \"lo\" accept" <<< "$r" | cut -d: -f1) &&
      [ -n "$dnat" ] && [ -n "$drop" ] && [ -n "$ts" ] && [ -n "$lo" ] &&
      [ "$dnat" -lt "$ts" ] && [ "$dnat" -lt "$lo" ] && [ "$drop" -lt "$ts" ] && [ "$drop" -lt "$lo" ]'
}
check_web_lan_refused_without_password() {
  # Without a usable password for agent, apply says so and LAN access stays off. Works on both the
  # smoke image (no password) and an installer-written disk (has one): lock it for the check and
  # restore the exact saved hash after (as check_autologin_when_no_access does). An empty saved
  # hash would make the restore leave a passwordless account: fail before changing anything.
  local rc=0
  vm 'h=$(sudo getent shadow agent | cut -d: -f2); [ -n "$h" ] || exit 1
      sudo usermod -p "!" agent; r=0
      { sudo agentos-config set AGENTOS_WEB_LAN 1 &&
        { out=$(sudo agentos-config apply 2>&1); test $? = 3; } &&
        echo "$out" | grep -q "set a password for agent first (sudo agentos-config password)" &&
        grep -qx LAN=0 /etc/agentos/web.conf && ! ss -Htln "sport = :7443" | grep -q .; } || r=1
      sudo usermod -p "$h" agent
      test "$(sudo getent shadow agent | cut -d: -f2)" = "$h" || r=1
      exit $r' || rc=1
  vm 'sudo agentos-config set AGENTOS_WEB_LAN 0 && sudo agentos-config apply' || rc=1
  return "$rc"
}
check_web_lan_login_end_to_end() {
  local rc=0 orig hdr cookie fp
  orig=$(vm 'sudo getent shadow agent | cut -d: -f2') || return 1
  # chpasswd: yescrypt, as `passwd` and `agentos-config password` write it.
  vm 'sudo chpasswd' <<< "agent:$LANPW" &&
  vm 'sudo agentos-config set AGENTOS_WEB_LAN 1 && sudo agentos-config apply && grep -qx LAN=1 /etc/agentos/web.conf' && lan_up || rc=1
  if [ "$rc" = 0 ]; then
    # Braced as one group: an assertion below with no "|| rc=1" of its own still short-circuits the
    # rest of the chain (as intended), but must not let the whole thing read back as a pass just
    # because the unrelated cleanup past "fi" succeeds on its own.
    {
    # Unauthenticated: the login page for a page, 401 for the API; a foreign Host is refused.
    lan "https://$GIP/" | grep -q 'Password of <code>agent</code>' &&
    # A bare IP typed into a browser is http:// on port 80: sent on to https, and only for this box.
    [ "$(lan_http "http://$GIP/")" = "301 https://$GIP/" ] &&
    [ "$(lan_http -H 'Host: evil.example' "http://$GIP/")" = "400 " ] &&
    [ "$(lan_code "https://$GIP/api/me")" = 401 ] &&
    [ "$(lan_code -H 'Host: evil.example' "https://$GIP/")" = 403 ] &&
    # 5 wrong passwords get 401, the 6th attempt 429, even with the right password.
    [ "$(lan_post -d '{"password":"wrong1"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong2"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong3"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong4"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d '{"password":"wrong5"}' "https://$GIP/api/lan/login")" = 401 ] &&
    [ "$(lan_post -d "{\"password\":\"$LANPW\"}" "https://$GIP/api/lan/login")" = 429 ] &&
    # Finding 2: 7443 directly, not through 443, is refused (the redirect's ct-status-dnat guard).
    # curl's own %{http_code} is already "000" on a failed connection; no fallback needed (or wanted:
    # it would double up, right after curl's own unterminated "000", into "000000").
    [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$HOSTPORT_7443/")" = 000 ] &&
    # Also on the guest's own loopback: the old ruleset accepted lo before the 7443 guard, the same
    # ordering flaw that let tailscale0 through, so this one fails on it while the LAN-side one can't.
    [ "$(vm 'curl -sk -m 5 -o /dev/null -w "%{http_code}" https://127.0.0.1:7443/')" = 000 ] &&
    # Finding 1: a container's outbound HTTPS reaches the real internet, not this box's own LAN
    # listener (the redirect must not catch forwarded traffic, only traffic addressed to this box).
    # The pull retries: the test network's DNS is now and then briefly "server misbehaving".
    vm 'docker rm -f ag-lan-curl >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do docker pull -q curlimages/curl >/dev/null && break; sleep 5; done
        docker run --rm --name ag-lan-curl curlimages/curl -sSI -m 15 https://example.com | head -1 | grep -q "^HTTP/"' &&
    # A restart forgets the failures (and every session), as documented.
    vm 'sudo systemctl restart agentos-web.service' && lan_up || rc=1
    hdr=$(lan -D - -o /dev/null -X POST -H "Origin: https://$GIP" -H 'X-AgentOS: 1' -H 'Content-Type: application/json' \
            -d "{\"password\":\"$LANPW\"}" "https://$GIP/api/lan/login") || rc=1
    cookie=$(printf '%s' "$hdr" | tr -d '\r' | sed -n 's/^set-cookie: \(__Host-agentos-session=[A-Za-z0-9_-]\{43\}\); Secure; HttpOnly; SameSite=Strict; Path=\/$/\1/ip')
    [ -n "$cookie" ] &&
    lan -H "Cookie: $cookie" "https://$GIP/api/me" | grep -q '"login":"agent@lan(10.0.2.2)".*"lan":true' &&
    # CSRF: an unsafe action needs X-AgentOS (and the Origin), then works. Creating a session is a
    # 201 (Created), not a 200: sessions.ts's reply.code(201).
    [ "$(lan_code -X POST -H "Cookie: $cookie" -H "Origin: https://$GIP" -H 'Content-Type: application/json' \
          -d '{"cli":"shell","name":"lan"}' "https://$GIP/api/sessions")" = 403 ] &&
    [ "$(lan_post -H "Cookie: $cookie" -d '{"cli":"shell","name":"lan"}' "https://$GIP/api/sessions")" = 201 ] &&
    # The terminal WebSocket, through the real 443 redirect (direct, unredirected 7443 is refused
    # by design: finding 2). This runs here, not on the guest, so it can dial the forwarded port
    # while still sending the guest's own address as Host/Origin.
    WS_COOKIE="$cookie" WS_HOST="$GIP" WS_CONNECT="127.0.0.1:$HOSTPORT_HTTPS" WS_MODULE_BASE="$HERE/../web/server/" \
      node "$HERE/web_ws.mjs" term ag-lan "echo lan-\$((40+2))" lan-42 &&
    [ "$(lan_post -H "Cookie: $cookie" "https://$GIP/api/sessions/ag-lan/stop")" = 200 ] &&
    [ "$(lan_code -X DELETE -H "Cookie: $cookie" -H "Origin: https://$GIP" -H 'X-AgentOS: 1' "https://$GIP/api/sessions/ag-lan")" = 200 ] &&
    # The fingerprint the console, agentos-config and the System page show is the served certificate's.
    fp=$(vm 'sudo agentos-config show-web-fingerprint') && [ -n "$fp" ] &&
    [ "$(openssl s_client -connect "127.0.0.1:$HOSTPORT_HTTPS" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | sed 's/^[^=]*=//')" = "$fp" ] &&
    lan -H "Cookie: $cookie" "https://$GIP/api/system/lan" | grep -q "\"fingerprint\":\"$fp\"" &&
    vm "grep -qx 'Web UI: https://$GIP  (LAN login)' /run/issue.d/50-agentos-web.issue &&
        grep -qx 'LAN certificate SHA-256: ${fp:0:47}' /run/issue.d/50-agentos-web.issue" &&
    # Logout ends the session; the audit log has every step and never the password.
    [ "$(lan_post -H "Cookie: $cookie" "https://$GIP/api/lan/logout")" = 200 ] &&
    [ "$(lan_code -H "Cookie: $cookie" "https://$GIP/api/me")" = 401 ] &&
    vm 'j=$(sudo journalctl -b -t agentos-web -p notice --no-pager -o cat) &&
        for l in "agent@lan(10.0.2.2) login-failed -" "agent@lan(10.0.2.2) login -" "agent@lan(10.0.2.2) logout -"; do
          echo "$j" | grep -qxF "$l" || { echo "no audit line: $l"; exit 1; }
        done' &&
    ! vm "sudo journalctl -b --no-pager | grep -qF '$LANPW'" || rc=1
    # Finding 5: changing agent's password drops any live LAN session (a restart).
    hdr2=$(lan -D - -o /dev/null -X POST -H "Origin: https://$GIP" -H 'X-AgentOS: 1' -H 'Content-Type: application/json' \
             -d "{\"password\":\"$LANPW\"}" "https://$GIP/api/lan/login") &&
    cookie2=$(printf '%s' "$hdr2" | tr -d '\r' | sed -n 's/^set-cookie: \(__Host-agentos-session=[A-Za-z0-9_-]\{43\}\); Secure; HttpOnly; SameSite=Strict; Path=\/$/\1/ip') &&
    [ -n "$cookie2" ] &&
    [ "$(lan_code -H "Cookie: $cookie2" "https://$GIP/api/me")" = 200 ] &&
    vm "printf '%s\n%s\n' '$LANPW2' '$LANPW2' | sudo agentos-config password" &&
    lan_up &&
    [ "$(lan_code -H "Cookie: $cookie2" "https://$GIP/api/me")" = 401 ]
    } || rc=1
  fi
  # Off again: the password goes back to what it was, and 443 is closed.
  vm 'sudo agentos-config set AGENTOS_WEB_LAN 0 && sudo agentos-config apply && grep -qx LAN=0 /etc/agentos/web.conf' || rc=1
  vm "sudo usermod -p '$orig' agent" || rc=1
  [ "$(lan_code -m 8 "https://$GIP/")" = 000 ] || rc=1
  return "$rc"
}
