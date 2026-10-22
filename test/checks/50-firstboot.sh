# shellcheck shell=bash
check_firstboot_succeeded() { vm 'systemctl is-active agentos-firstboot.service'; }
check_hostname_applied()    { vm 'test "$(hostname)" = agentos-test'; }
check_env_mode()            { vm 'test "$(sudo stat -c %a /etc/agentos/agentos.env)" = 600'; }
check_secret_moved()        { vm '! sudo grep -q ANTHROPIC_API_KEY /etc/agentos/agentos.env &&
                                  test "$(stat -c %a ~/.config/agentos/secrets.env)" = 600'; }
check_secret_in_login_env() { vml 'test "$ANTHROPIC_API_KEY" = sk-test-dummy'; }
check_mcp_token()           { vm 'test "$(sudo stat -c %a /etc/agentos/mcp-token)" = 600 &&
                                  test "$(sudo cat /etc/agentos/mcp-token | wc -c)" -ge 40'; }
check_no_tskey_ok()         { vm '! sudo grep -q "^TS_AUTHKEY=" /etc/agentos/agentos.env'; }
check_firstboot_rerun_idempotent() {
  vm 'sudo /usr/local/sbin/agentos-firstboot && test "$(grep -c ANTHROPIC_API_KEY ~/.config/agentos/secrets.env)" = 1'
}
check_secret_value_not_evaluated() {
  vm 'sudo agentos-firstboot >/dev/null; printf "%s\n" "WEIRD_TOKEN=a b \$(touch /tmp/agentos-pwned)" >> ~/.config/agentos/secrets.env'
  vml 'test "$WEIRD_TOKEN" = "a b \$(touch /tmp/agentos-pwned)" && test ! -e /tmp/agentos-pwned'
}
