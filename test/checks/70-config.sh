# shellcheck shell=bash
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
check_autologin_when_no_access() {
  vm 'mv ~/.ssh/authorized_keys ~/.ssh/ak.bak
      sudo agentos-console-apply; r=0; test -e /etc/systemd/system/getty@tty1.service.d/agentos.conf || r=1
      mv ~/.ssh/ak.bak ~/.ssh/authorized_keys; sudo agentos-console-apply
      test ! -e /etc/systemd/system/getty@tty1.service.d/agentos.conf && exit $r'
}
check_terminal_mode_profile() { vm 'grep -q "cage -- foot" /etc/profile.d/agentos.sh && command -v cage && command -v foot'; }
check_issue_banner()          { vm 'grep -q "agentos-config" /etc/issue'; }

# Automated stand-in for the brief's manual Step 5 (no attached display in the smoke harness,
# and tty1's VT output is not mirrored to the serial console this harness captures): assert the
# getty@tty1 drop-in content and that systemd actually wires it to agentos-config-tty.
check_autologin_dropin_wired_to_config_tty() {
  vm 'mv ~/.ssh/authorized_keys ~/.ssh/ak.bak
      sudo agentos-console-apply
      sudo grep -qF "/usr/local/sbin/agentos-config-tty" /etc/systemd/system/getty@tty1.service.d/agentos.conf
      r=$?
      sudo systemctl cat getty@tty1.service | grep -qF "/usr/local/sbin/agentos-config-tty" || r=1
      mv ~/.ssh/ak.bak ~/.ssh/authorized_keys; sudo agentos-console-apply
      exit $r'
}
