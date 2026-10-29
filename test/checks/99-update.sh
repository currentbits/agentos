# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

check_agentos_package_installed() {  # sorts before check_agentos_update and check_update_*
  # The image carries the .deb this build made, untouched, and no unit files in the old place.
  local want; want=$(dpkg-deb -f "$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb)" Version) || return 1
  vm 'test "$(dpkg-query -W -f "\${Version}" agentos)" = "'"$want"'" && test -z "$(sudo dpkg -V agentos)" &&
      test -z "$(find /etc/systemd/system -maxdepth 1 -name "agentos-*" -print -quit)" &&
      test ! -e /etc/systemd/system/docker.service.d/10-agentos.conf'
}
