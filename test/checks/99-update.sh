# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

check_agentos_package_installed() {  # sorts before check_agentos_update and check_update_*
  # The image carries the .deb this build made, untouched, and no unit files in the old place.
  local want; want=$(dpkg-deb -f "$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb)" Version) || return 1
  vm 'test "$(dpkg-query -W -f "\${Version}" agentos)" = "'"$want"'" && test -z "$(sudo dpkg -V agentos)" &&
      test -z "$(find /etc/systemd/system -maxdepth 1 -name "agentos-*" -print -quit)" &&
      test ! -e /etc/systemd/system/docker.service.d/10-agentos.conf'
}

check_update_notice_console_and_motd() {
  # A release in update.json shows on the console (firstboot rewrites /run/issue.d at every boot and
  # apply) and at the next SSH login (pam_motd runs /etc/update-motd.d); without one it goes away.
  vm 'sudo agentos-update --check >/dev/null && sudo cp /var/lib/agentos/update.json /var/tmp/update.json.orig &&
      printf "{\"installed\":\"0.1\",\"available\":\"9.9.9\",\"notes\":\"\",\"checked_at\":\"2026-10-29T00:00:00Z\",\"error\":null}\n" |
        sudo tee /var/lib/agentos/update.json >/dev/null &&
      sudo rm -f /run/issue.d/60-agentos-update.issue && sudo agentos-config apply &&
      grep -qx "AgentOS 9.9.9 available: run agentos-update (or use the web UI)" /run/issue.d/60-agentos-update.issue' &&
  vm 'grep -qx "AgentOS 9.9.9 available: run agentos-update (or use the web UI)" /run/motd.dynamic &&
      sudo cp /var/tmp/update.json.orig /var/lib/agentos/update.json && sudo agentos-update --issue &&
      test ! -e /run/issue.d/60-agentos-update.issue && test -z "$(agentos-update --notice)"'
}
