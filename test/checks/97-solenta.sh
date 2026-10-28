# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

# --- Mode A: Solenta headless on the box -------------------------------------------------------
SOLENTA_LIBS='libnss3 libnspr4 libgtk-3-0t64 libgbm1 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64
  libatspi2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libxfixes3
  libpango-1.0-0 libcairo2 libdbus-1-3 libexpat1 libxext6 libx11-6 libxcb1 libglib2.0-0t64'
check_solenta_libs_installed() {
  # shellcheck disable=SC2086 # word-split the list on purpose
  test "$(vm "dpkg-query -W -f '\${db:Status-Status}\n' $(echo $SOLENTA_LIBS) | grep -cx installed")" = 23
}
check_solenta_units_idle_without_install() {
  # Guest-side proof first: the units exist and are enabled; then, with no ~/solenta, inactive.
  vm 'systemctl is-enabled --quiet agentos-solenta.path && systemctl is-enabled --quiet agentos-solenta.service &&
      systemctl is-active --quiet agentos-solenta.path && test ! -e ~/solenta &&
      sudo systemctl start agentos-solenta.service &&
      test "$(systemctl show agentos-solenta.service -p ConditionResult --value)" = no &&
      ! systemctl is-active --quiet agentos-solenta.service'
}
# A stand-in for the Linux build: answers on --serve-web=PORT through python's http.server. It
# stays the parent of the server (no exec), so its own command line keeps Solenta's pkill pattern.
SOLENTA_STUB='#!/bin/bash
port=4620; for a in "$@"; do case $a in --serve-web=*) port=${a#*=};; esac; done
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 & child=$!
trap "kill $child; exit 0" TERM
wait'
solenta_install_stub() {  # the way Solenta installs: unpack beside, then rename into place
  vm "rm -rf ~/.solenta-new ~/solenta && mkdir -p ~/.solenta-new/pkg && printf '%s\n' '$SOLENTA_STUB' > ~/.solenta-new/pkg/solenta &&
      chmod +x ~/.solenta-new/pkg/solenta && mv ~/.solenta-new/pkg ~/solenta && rm -rf ~/.solenta-new"
}
solenta_cleanup() { vm 'sudo systemctl stop agentos-solenta.service; rm -rf ~/solenta ~/solenta.old'; }
check_solenta_stub_survives_logout_and_pkill() {
  local rc=0 pid1 pid2
  solenta_install_stub &&
  vm 'for _ in $(seq 1 30); do curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && exit 0; sleep 1; done; exit 1' &&
  pid1=$(vm 'systemctl show agentos-solenta.service -p MainPID --value') && test "$pid1" -gt 0 &&
  # A new SSH session (the last one has logged out): the same process still serves.
  test "$(vm 'systemctl show agentos-solenta.service -p MainPID --value')" = "$pid1" &&
  vm 'curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && ps -o args= -p "$(systemctl show agentos-solenta.service -p MainPID --value)" | grep -q "^/bin/bash /home/agent/solenta/solenta --headless --serve-web=4620 --no-sandbox$"' &&
  # Solenta's upgrade stops the old build exactly like this; Restart=always brings one back.
  vm 'pkill -TERM -f "$HOME/solenta/solenta[a-z-]* --headless"' &&
  vm 'for _ in $(seq 1 30); do sleep 1; p=$(systemctl show agentos-solenta.service -p MainPID --value)
        [ "$p" -gt 0 ] && [ "$p" != '"$pid1"' ] && curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && exit 0; done; exit 1' || rc=1
  pid2=$(vm 'systemctl show agentos-solenta.service -p MainPID --value') || rc=1
  [ "$pid2" != "$pid1" ] || rc=1
  solenta_cleanup
  return "$rc"
}
check_solenta_upgrade_rename_restarts() {
  # An upgrade renames a new ~/solenta into place: the .path unit (PathChanged) starts the service.
  local rc=0
  vm 'sudo systemctl stop agentos-solenta.service' && solenta_install_stub &&
  vm 'for _ in $(seq 1 30); do systemctl is-active --quiet agentos-solenta.service && exit 0; sleep 1; done; exit 1' || rc=1
  solenta_cleanup
  return "$rc"
}
CRASH_STUB='#!/bin/bash
exit 1'
solenta_install_crash_stub() {
  vm "rm -rf ~/.solenta-new ~/solenta && mkdir -p ~/.solenta-new/pkg && printf '%s\n' '$CRASH_STUB' > ~/.solenta-new/pkg/solenta &&
      chmod +x ~/.solenta-new/pkg/solenta && mv ~/.solenta-new/pkg ~/solenta && rm -rf ~/.solenta-new"
}
check_solenta_backoff_recovers_without_resetfailed() {
  # A crashing build must keep retrying, never land in a terminal "failed" state: StartLimitIntervalSec=0
  # means no reset-failed is ever needed, so a later upgrade's PathChanged can always restart it
  # straight away. RestartSteps/RestartMaxDelaySec do back off on this systemd (257): verified by hand
  # with a throwaway /bin/false unit outside the image -- NRestarts grows roughly every 5s, then 10s,
  # then 20s, confirming the ramp -- so a count of restarts in a short window isn't a stable
  # assertion. Check only what the growing delay can't break: never "failed", and a rename-triggered
  # upgrade (the .path unit, not this check) brings it back without any reset-failed call.
  local rc=0
  vm 'sudo systemctl stop agentos-solenta.service' &&
  solenta_install_crash_stub &&
  vm 'sudo systemctl start agentos-solenta.service' &&
  vm 'for _ in $(seq 1 15); do
        test "$(systemctl show agentos-solenta.service -p ActiveState --value)" != failed || exit 1
        sleep 1
      done' || rc=1
  solenta_install_stub &&
  vm 'for _ in $(seq 1 30); do systemctl is-active --quiet agentos-solenta.service && exit 0; sleep 1; done; exit 1' || rc=1
  solenta_cleanup
  return "$rc"
}
check_solenta_skips_when_port_taken() {
  # Solenta's own nohup copy already serves 4620: the unit stays out of the way (no restart loop).
  local rc=0
  solenta_install_stub && vm 'sudo systemctl stop agentos-solenta.service &&
    (setsid python3 -m http.server 4620 --bind 127.0.0.1 </dev/null >/dev/null 2>&1 &) &&
    for _ in $(seq 1 20); do curl -s -o /dev/null -m 1 http://127.0.0.1:4620/ && break; sleep 0.5; done &&
    n=$(systemctl show agentos-solenta.service -p NRestarts --value) &&
    sudo systemctl start agentos-solenta.service; sleep 8
    ! systemctl is-active --quiet agentos-solenta.service &&
    test "$(systemctl show agentos-solenta.service -p NRestarts --value)" = "$n"' || rc=1
  vm 'pkill -f "http.server 4620" || true'
  solenta_cleanup
  return "$rc"
}
check_solenta_setting_off_and_on() {
  local rc=0
  vm 'sudo agentos-config set AGENTOS_SOLENTA 0 && sudo agentos-config apply &&
      ! systemctl is-enabled --quiet agentos-solenta.path && ! systemctl is-enabled --quiet agentos-solenta.service' || rc=1
  vm 'sudo agentos-config set AGENTOS_SOLENTA 1 && sudo agentos-config apply &&
      systemctl is-enabled --quiet agentos-solenta.path && systemctl is-active --quiet agentos-solenta.path' || rc=1
  return "$rc"
}
check_solenta_real_tarball() {
  # Optional: the real Linux build, installed by the same steps remoteConnections.js runs, answers
  # on 4620 under the unit. Needs GitHub; SKIP offline.
  # Pinned to v0.27.0: 0.26.0's Linux build always creates a BrowserWindow, even under --headless,
  # and Electron 35 SIGSEGVs creating that window with no X display -- AgentOS requires >= 0.27.
  local url sha
  vm 'curl -s -o /dev/null -m 10 https://api.github.com' || { echo "SKIP: no network to api.github.com"; return 0; }
  read -r url sha < <(vm 'curl -fsS -m 20 https://api.github.com/repos/currentbits/solenta/releases/tags/v0.27.0 |
    jq -r ".assets[] | select(.name | test(\"linux-x64\")) | \"\(.browser_download_url) \(.digest | ltrimstr(\"sha256:\"))\""') ||
    { echo "SKIP: no v0.27.0 linux-x64 release asset"; return 0; }
  local rc=0
  vm "rm -rf ~/.solenta-new && mkdir -p ~/.solenta-new && curl -fsSL -o ~/.solenta-download.tar.gz '$url' &&
      test \"\$(sha256sum ~/.solenta-download.tar.gz | cut -d ' ' -f 1)\" = '$sha' &&
      tar -xzf ~/.solenta-download.tar.gz -C ~/.solenta-new && rm -f ~/.solenta-download.tar.gz &&
      for d in ~/.solenta-new/*/; do [ -x \"\$d/solenta\" ] && src=\${d%/}; done && rm -rf ~/solenta && mv \"\$src\" ~/solenta &&
      test -z \"\$(ldd ~/solenta/solenta | grep 'not found')\" &&
      for _ in \$(seq 1 90); do curl -s -o /dev/null -m 2 http://127.0.0.1:4620/ && exit 0; sleep 1; done; exit 1" || rc=1
  # Task 3 adds solenta-pair; until then, only check it if it's there, so this still passes today
  # on the web-token assertion alone.
  vm 'test -s ~/.config/Solenta/web-token && { test ! -e /usr/local/lib/agentos/solenta-pair ||
      /usr/local/lib/agentos/solenta-pair status | jq -e ".modeA.version == \"0.27.0\" and .modeA.webToken"; }' >/dev/null || rc=1
  vm 'sudo systemctl stop agentos-solenta.service; rm -rf ~/solenta ~/.solenta-new ~/.config/Solenta ~/.solenta-headless.log'
  return "$rc"
}
