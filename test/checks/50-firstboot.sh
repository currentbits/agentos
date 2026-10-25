# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_firstboot_ordering() {
  vm 'systemctl cat cloud-config.target >/dev/null || { echo "no cloud-config.target unit"; exit 1; }
      a=$(systemctl show -p After --value agentos-firstboot); for u in cloud-config.target network-online.target tailscaled.service; do
        echo " $a " | grep -q " $u " || { echo "missing After=$u"; exit 1; }; done'
}
check_pad_token_survives() {  # values ending in "=" must survive the agentos.env -> secrets.env move
  vm 'grep -qx "PAD_TOKEN=abc==" ~/.config/agentos/secrets.env && grep -qx "PAD1_TOKEN=abc=" ~/.config/agentos/secrets.env' &&
    vml 'test "$PAD_TOKEN" = "abc==" && test "$PAD1_TOKEN" = "abc="'
}
check_firstboot_succeeded() { vm 'systemctl is-active agentos-firstboot.service'; }
check_hostname_applied()    { vm 'test "$(hostname)" = agentos-test'; }
check_env_mode()            { vm 'test "$(sudo stat -c %a /etc/agentos/agentos.env)" = 600'; }
check_secret_moved()        { vm '! sudo grep -q ANTHROPIC_API_KEY /etc/agentos/agentos.env &&
                                  test "$(stat -c %a ~/.config/agentos/secrets.env)" = 600'; }
check_secret_in_login_env() { vml 'test "$ANTHROPIC_API_KEY" = sk-test-dummy'; }
check_mcp_token()           { vm 'test "$(sudo stat -c %a /etc/agentos/mcp-token)" = 600 &&
                                  test "$(sudo cat /etc/agentos/mcp-token | wc -c)" -eq 64'; }
check_no_tskey_ok()         { vm '! sudo grep -q "^TS_AUTHKEY=" /etc/agentos/agentos.env'; }
check_tailscale_authkey_via_file() {
  # The auth key must go through tailscale's `--auth-key=file:...` form, never interpolated
  # straight onto the command line (where `ps`/process logging could capture it).
  vm 'grep -q "auth-key=\"file:" /usr/local/sbin/agentos-firstboot &&
      ! grep -F -- "--auth-key=\"\$k\"" /usr/local/sbin/agentos-firstboot &&
      ! grep -E -- "--auth-key=\\\$[a-zA-Z_]" /usr/local/sbin/agentos-firstboot'
}
check_firstboot_rerun_idempotent() {
  vm 'sudo /usr/local/sbin/agentos-firstboot && test "$(grep -c ANTHROPIC_API_KEY ~/.config/agentos/secrets.env)" = 1'
}
check_secret_value_not_evaluated() {
  vm 'sudo agentos-firstboot >/dev/null; printf "%s\n" "WEIRD_TOKEN=a b \$(touch /tmp/agentos-pwned)" >> ~/.config/agentos/secrets.env;
      printf "NOEOL_TOKEN=x" >> ~/.config/agentos/secrets.env'
  vml 'test "$WEIRD_TOKEN" = "a b \$(touch /tmp/agentos-pwned)" && test ! -e /tmp/agentos-pwned && test "$NOEOL_TOKEN" = x'
}
