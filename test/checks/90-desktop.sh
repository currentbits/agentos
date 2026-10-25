# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
# Desktops are started with sudo here; Task 2 adds the polkit rule that lets agent do it directly.
wait_x() {  # wait_x <N>: wait up to 60 s for display :N to answer
  vm "for i in \$(seq 1 60); do DISPLAY=:$1 xdotool getdisplaygeometry 2>/dev/null | grep -qx '1920 1080' && exit 0; sleep 1; done; exit 1"
}
check_desktop_packages() { vm 'command -v Xvnc startxfce4 xdotool scrot xclip chromium >/dev/null'; }
check_two_desktops_independent() {
  vm 'sudo systemctl start agentos-desktop@1.service agentos-desktop@2.service' &&
  wait_x 1 && wait_x 2 && vm 'sleep 10' &&
  vm 'for n in 1 2; do DISPLAY=:$n xdotool search --class xfce4-panel | grep -q . || { echo "no panel on :$n"; exit 1; }; done' &&
  vm 'test "$(pgrep -u agent -c -x xfconfd)" -ge 2 || { echo "expected one xfconfd per desktop, got $(pgrep -u agent -c -x xfconfd)"; exit 1; }' &&
  vm 'for n in 1 2; do ! DISPLAY=:$n xdotool search --onlyvisible --name "^Panel$" | grep -q . || { echo "first-run panel dialog on :$n"; exit 1; }; done' &&
  vm 'sudo systemctl stop agentos-desktop@1.service && sleep 2 &&
      ! DISPLAY=:1 xdotool getdisplaygeometry 2>/dev/null &&
      DISPLAY=:2 xdotool search --class xfce4-panel | grep -q . || { echo "stopping :1 affected :2"; exit 1; }' &&
  vm 'sudo systemctl stop agentos-desktop@2.service && sleep 1 && ! pgrep -u agent -x Xvnc'
}
check_desktop_restart_after_crash() {
  # -x Xvnc would kill every desktop's Xvnc; -f '^Xvnc :3 ' targets only :3's argv0+arg -
  # proven below by starting :2 alongside and asserting it survives the kill.
  vm 'sudo systemctl start agentos-desktop@2.service agentos-desktop@3.service' && wait_x 2 && wait_x 3 &&
  vm "pkill -KILL -u agent -f '^Xvnc :3 '; sleep 2; DISPLAY=:2 xdotool getdisplaygeometry >/dev/null || { echo ':2 died too'; exit 1; }" &&
  vm 'sudo systemctl stop agentos-desktop@3.service 2>/dev/null; sudo systemctl reset-failed agentos-desktop@3.service 2>/dev/null; sudo systemctl start agentos-desktop@3.service' &&
  wait_x 3 && vm 'sudo systemctl stop agentos-desktop@2.service agentos-desktop@3.service'
}
check_terminal_login_shell() { vm 'grep -qx "CommandLoginShell=TRUE" ~/.config/xfce4/terminal/terminalrc'; }
check_xvnc_loopback_only() {
  # ss is at /usr/bin/ss in this image (not /usr/sbin as iproute2 ships on some distros); the
  # non-login PATH here is /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin so the
  # plain name would resolve fine too, but the full path removes any doubt.
  vm 'sudo systemctl start agentos-desktop@9.service' && wait_x 9 &&
  vm '! /usr/bin/ss -Hltn | grep -E ":59[0-9]{2}\b" | grep -vE "127\.0\.0\.1|\[::1\]"' &&
  vm 'sudo systemctl stop agentos-desktop@9.service'
}
