# shellcheck shell=bash
# Only run against disks written by the installer (smoke.sh with SMOKE_DISK set).
installed_cloud_init_disabled()   { vm 'test -f /etc/cloud/cloud-init.disabled'; }
installed_no_installer_keys()     { vm '! sudo grep -qE "^(AGENTOS_INSTALL_|AGENTOS_SSH_KEY|AGENTOS_PASSWORD_HASH|AGENTOS_NET_|AGENTOS_GITHUB_USER)" /etc/agentos/agentos.env'; }
installed_hostname_from_env()     { vm 'test "$(hostname)" = agentos-test'; }
installed_three_partitions_only() { vm 'test "$(lsblk -nro PARTLABEL /dev/vda | grep -c .)" = 3 && ! lsblk -nro PARTLABEL /dev/vda | grep -qx AGENTOS'; }
installed_password_set()          { vm 'test "$(sudo passwd -S agent | cut -d" " -f2)" = P'; }
installed_static_network()        { vm 'grep -qx "Address=10.0.2.15/24" /etc/systemd/network/10-agentos-static.network && ip -4 -o addr show | grep "10.0.2.15/24" | grep -vq dynamic'; }  # slirp DHCP gives the same IP: must not be a lease
