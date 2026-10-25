# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_config_set_get() {
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 4 && test "$(sudo agentos-config get AGENTOS_MAX_DESKTOPS)" = 4'
}
check_config_secret_routed() {
  vm 'sudo agentos-config set OPENAI_API_KEY sk-o-test &&
      grep -qx OPENAI_API_KEY=sk-o-test ~/.config/agentos/secrets.env &&
      ! sudo grep -q OPENAI_API_KEY /etc/agentos/agentos.env'
}
check_config_get_refuses_secret() { vm '! sudo agentos-config get OPENAI_API_KEY 2>/dev/null'; }
check_config_rejects_bad_key()    { vm '! sudo agentos-config set bad-key x 2>/dev/null'; }
check_add_ssh_key() {
  vm 'k="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestOnly0000000000000000000000 t@t";
      sudo agentos-config add-ssh-key "$k" && grep -qF "$k" ~/.ssh/authorized_keys &&
      sudo agentos-config add-ssh-key "$k" && test "$(grep -cF "$k" ~/.ssh/authorized_keys)" = 1'
}
check_mcp_token_shown() { vm 'test "$(sudo agentos-config show-mcp-token)" = "$(sudo cat /etc/agentos/mcp-token)"'; }
check_add_ssh_key_rejects_multiline() { vm '! sudo agentos-config add-ssh-key "$(printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestOnly0000000000000000000000 a\ncommand=\"x\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestOnly0000000000000000000000 b")" 2>/dev/null && ! grep -q "command=" ~/.ssh/authorized_keys'; }
check_no_autologin_when_key_present() {
  vm 'sudo agentos-console-apply && test ! -e /etc/systemd/system/getty@tty1.service.d/agentos.conf'
}
check_autologin_when_only_comment_in_authorized_keys() {
  # A non-empty authorized_keys that holds no actual key line (just a comment) must not count as access.
  vm 'h=$(sudo getent shadow agent | cut -d: -f2); [ -n "$h" ] || exit 1
      mv ~/.ssh/authorized_keys ~/.ssh/ak.bak; echo "# not a key" > ~/.ssh/authorized_keys
      sudo usermod -p "!" agent
      sudo agentos-console-apply; r=0; test -e /etc/systemd/system/getty@tty1.service.d/agentos.conf || r=1
      sudo usermod -p "$h" agent; mv ~/.ssh/ak.bak ~/.ssh/authorized_keys; sudo agentos-console-apply
      test ! -e /etc/systemd/system/getty@tty1.service.d/agentos.conf && exit $r'
}
check_autologin_when_no_access() {
  # A password also counts as access (installer-written disks have one): lock it, restore the exact hash after.
  # An empty saved hash would make the restore leave a passwordless account: fail before changing anything.
  vm 'h=$(sudo getent shadow agent | cut -d: -f2); [ -n "$h" ] || exit 1
      mv ~/.ssh/authorized_keys ~/.ssh/ak.bak; sudo usermod -p "!" agent
      sudo agentos-console-apply; r=0; test -e /etc/systemd/system/getty@tty1.service.d/agentos.conf || r=1
      sudo usermod -p "$h" agent; mv ~/.ssh/ak.bak ~/.ssh/authorized_keys; sudo agentos-console-apply
      test ! -e /etc/systemd/system/getty@tty1.service.d/agentos.conf && exit $r'
}
check_terminal_mode_profile() { vm 'grep -q "cage -- foot" /etc/profile.d/agentos.sh && ! grep -q "exec cage" /etc/profile.d/agentos.sh && command -v cage && command -v foot'; }
check_config_apply_restarts_unit() {  # apply must run firstboot as its unit, not inside the caller (getty@tty1)
  vm 't0=$(systemctl show -p ActiveEnterTimestampMonotonic --value agentos-firstboot)
      sudo agentos-config apply &&
      test "$(systemctl show -p ActiveEnterTimestampMonotonic --value agentos-firstboot)" != "$t0"'
}
check_config_menu_survives_bad_input() {  # bad sshkey input: msgbox, back to the menu (not exit 2)
  vm 'bash -s' <<'EOF'
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
# Fake whiptail (answers go to stderr, like whiptail): menu -> sshkey, inputbox -> junk, menu -> done.
cat > "$d/whiptail" <<'W'
#!/bin/bash
d=$(dirname "$0"); echo "$*" >> "$d/log"
case "$*" in
  *--menu*)     if [ -e "$d/state" ]; then echo done >&2; else touch "$d/state"; echo sshkey >&2; fi ;;
  *--inputbox*) echo "not-a-key" >&2 ;;
esac
W
chmod +x "$d/whiptail"
sudo env PATH="$d:$PATH" agentos-config || { echo "menu exited rc=$?"; cat "$d/log"; exit 1; }
grep -q "SSH key not added: not an SSH public key" "$d/log" && test "$(grep -c -- --menu "$d/log")" = 2 || { cat "$d/log"; exit 1; }
EOF
}
check_issue_banner()        { vm 'grep -q "agentos-config" /etc/issue'; }
check_issue_no_blank_tailnet_parens() { vm '! grep -q "(tailnet:" /etc/issue'; }

# Automated stand-in for the brief's manual Step 5 (no attached display in the smoke harness,
# and tty1's VT output is not mirrored to the serial console this harness captures): assert the
# getty@tty1 drop-in content and that systemd actually wires it to agentos-config-tty.
check_autologin_dropin_wired_to_config_tty() {
  vm 'h=$(sudo getent shadow agent | cut -d: -f2); [ -n "$h" ] || exit 1
      mv ~/.ssh/authorized_keys ~/.ssh/ak.bak; sudo usermod -p "!" agent
      sudo agentos-console-apply
      sudo grep -qF "/usr/local/sbin/agentos-config-tty" /etc/systemd/system/getty@tty1.service.d/agentos.conf
      r=$?
      sudo systemctl cat getty@tty1.service | grep -qF "/usr/local/sbin/agentos-config-tty" || r=1
      sudo usermod -p "$h" agent; mv ~/.ssh/ak.bak ~/.ssh/authorized_keys; sudo agentos-console-apply
      exit $r'
}
