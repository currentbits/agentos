# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_nft_table()       { vm 'sudo nft list table inet agentos | grep -q "policy drop"'; }
check_lan_ssh_open()    { vm 'sudo nft list set inet agentos public_tcp | grep -qw 22'; }
check_no_flush_ruleset(){ vm 'sudo nft list tables | grep -q "ip filter\|ip nat"'; }  # docker's tables survived
check_docker_default_localhost() {
  vm 'docker rm -f ag-web >/dev/null 2>&1; docker run -d --name ag-web -p 8080:80 nginx:alpine >/dev/null && sleep 3'
  vm 'for i in $(seq 1 20); do curl -sf -m 2 http://127.0.0.1:8080/ >/dev/null && exit 0; sleep 1; done; exit 1'
  ! curl -s -m 5 "http://127.0.0.1:$HOSTPORT_HTTP/" >/dev/null
}
check_docker_explicit_public_blocked() {
  vm 'docker rm -f ag-web >/dev/null 2>&1; docker run -d --name ag-web -p 0.0.0.0:8080:80 nginx:alpine >/dev/null && sleep 3'
  vm 'ip=$(hostname -I | awk "{print \$1}"); for i in $(seq 1 20); do curl -sf -m 2 "http://$ip:8080/" >/dev/null && exit 0; sleep 1; done; exit 1'
  local rc=0; curl -s -m 5 "http://127.0.0.1:$HOSTPORT_HTTP/" >/dev/null || rc=$?
  vm 'docker rm -f ag-web >/dev/null; curl -sf -m 5 http://127.0.0.1:8080/ >/dev/null || true'
  [ "$rc" -ne 0 ]
}
check_docker_live_restore() { vm 'test "$(sudo docker info --format "{{.LiveRestoreEnabled}}")" = true'; }
check_sysctl()        { vm 'test "$(/usr/sbin/sysctl -n kernel.kptr_restrict)" = 2 && test "$(/usr/sbin/sysctl -n kernel.unprivileged_bpf_disabled)" -ge 1'; }
check_unattended()      { vm 'systemctl is-enabled apt-daily-upgrade.timer && sudo unattended-upgrade --dry-run -d 2>&1 | grep -q "Allowed origins.*Debian-Security"'; }
check_noreboot_honored(){ vm 'test -f /etc/apt/apt.conf.d/53agentos-noreboot'; }
