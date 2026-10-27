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
