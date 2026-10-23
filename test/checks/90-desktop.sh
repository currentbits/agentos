# shellcheck shell=bash
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
  vm 'sudo systemctl start agentos-desktop@3.service' && wait_x 3 &&
  vm 'pkill -KILL -u agent -x Xvnc ; sleep 2; sudo systemctl stop agentos-desktop@3.service 2>/dev/null; sudo systemctl reset-failed agentos-desktop@3.service 2>/dev/null; sudo systemctl start agentos-desktop@3.service' &&
  wait_x 3 && vm 'sudo systemctl stop agentos-desktop@3.service'
}
check_terminal_login_shell() { vm 'grep -qx "CommandLoginShell=TRUE" ~/.config/xfce4/terminal/terminalrc'; }
