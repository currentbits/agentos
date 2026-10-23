# shellcheck shell=bash
check_agent_manages_desktop_without_sudo() {
  vm 'systemctl --no-ask-password start agentos-desktop@5.service &&
      systemctl is-active agentos-desktop@5.service &&
      systemctl --no-ask-password stop agentos-desktop@5.service'
}
check_agent_cannot_manage_other_units() {
  vm '! systemctl --no-ask-password start systemd-tmpfiles-clean.service 2>/dev/null'
}
check_desktop_number_bounds() {
  vm 'systemctl --no-ask-password start agentos-desktop@1.service' && wait_x 1 &&
  vm 'before=$(stat -c %Y /tmp/.X1-lock) &&
      for u in agentos-desktop@0.service agentos-desktop@01.service agentos-desktop@17.service; do
        ! systemctl --no-ask-password start "$u" 2>/dev/null || { echo "$u should have been rejected"; exit 1; }
      done &&
      test "$(stat -c %Y /tmp/.X1-lock)" = "$before"' &&
  vm 'systemctl --no-ask-password stop agentos-desktop@1.service'
}
check_desktop_oom_priority() {
  vm 'systemctl --no-ask-password start agentos-desktop@8.service' && wait_x 8 &&
  vm 'test "$(systemctl show agentos-desktop@8 -p OOMScoreAdjust --value)" = 500' &&
  vm 'systemctl --no-ask-password stop agentos-desktop@8.service'
}
check_vnc_token_lifecycle() {
  vm 'systemctl --no-ask-password start agentos-desktop@6.service && sleep 2 &&
      grep -qE "^[0-9a-f]{32}: localhost:5906$" /run/agentos/vnc/6 &&
      test "$(stat -c "%a %U %G" /run/agentos/vnc/6)" = "640 root agent" &&
      systemctl --no-ask-password stop agentos-desktop@6.service && sleep 1 &&
      test ! -e /run/agentos/vnc/6'
}
check_vnc_tokens_differ() {
  vm 'systemctl --no-ask-password start agentos-desktop@6.service agentos-desktop@7.service && sleep 2 &&
      a=$(cut -d: -f1 /run/agentos/vnc/6) && b=$(cut -d: -f1 /run/agentos/vnc/7) && test "$a" != "$b";
      rc=$?; systemctl --no-ask-password stop agentos-desktop@6.service agentos-desktop@7.service; exit $rc'
}
check_novnc_serves_locally() {
  vm 'systemctl is-active agentos-novnc.service && curl -sf -m 5 http://127.0.0.1:6080/vnc.html | grep -qi novnc'
}
check_novnc_not_reachable_from_lan() {
  vm 'curl -sf -m 5 "http://$(hostname -I | awk "{print \$1}"):6080/vnc.html" >/dev/null' &&
  ! curl -s -m 5 "http://127.0.0.1:$HOSTPORT_NOVNC/vnc.html" >/dev/null
}
check_novnc_unit_hardened() {
  # Checked property-by-property (not a sorted/joined blob): systemd lists Requires= members
  # (our explicit one plus the unit's implicit slice dependency) in a hash order that varies
  # between boots, so anchoring on their exact position flakes ~50% of the time.
  vm 'p=$(systemctl show agentos-novnc.service -p User -p NoNewPrivileges -p ProtectSystem -p Requires) &&
      echo "$p" | grep -qx "User=agent" &&
      echo "$p" | grep -qx "NoNewPrivileges=yes" &&
      echo "$p" | grep -qx "ProtectSystem=strict" &&
      echo "$p" | grep -qw "agentos-firewall.service"'
}
check_desktop_conf_published() {
  vm 'grep -qx "MAX_DESKTOPS=8" /etc/agentos/desktop.conf && grep -qx "SCREENSHOT_WIDTH=1366" /etc/agentos/desktop.conf &&
      test "$(stat -c %a /etc/agentos/desktop.conf)" = 644'
}
check_desktop_conf_follows_config() {
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 3 && sudo agentos-config set AGENTOS_SCREENSHOT_WIDTH 99999 &&
      sudo agentos-config apply && grep -qx MAX_DESKTOPS=3 /etc/agentos/desktop.conf &&
      grep -qx SCREENSHOT_WIDTH=1366 /etc/agentos/desktop.conf;
      rc=$?; sudo agentos-config set AGENTOS_MAX_DESKTOPS 8; sudo agentos-config set AGENTOS_SCREENSHOT_WIDTH 1366;
      sudo agentos-config apply; exit $rc'
}
