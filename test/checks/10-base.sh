# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_boot_mode_matches() {
  if [ "$MODE" = uefi ]; then vm 'test -d /sys/firmware/efi'; else vm 'test ! -d /sys/firmware/efi'; fi
}
check_agent_user()        { vm 'test "$(id -u)" = 1000 && id -nG | grep -qw sudo'; }
check_passwordless_sudo() { vm 'sudo -n true'; }
check_password_ssh_refused() {
  ! ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no agent@127.0.0.1 true 2>/dev/null
}
check_sshd_hardening() {
  vm 'sudo sshd -T | grep -qx "passwordauthentication no" &&
      sudo sshd -T | grep -qx "permitrootlogin no" &&
      sudo sshd -T | grep -qx "allowusers agent"'
}
check_root_grown()        { vm 'test "$(df --output=size -BG / | tail -1 | tr -dc 0-9)" -ge 35'; }
check_networkd_dhcp()     { vm 'networkctl status >/dev/null && for i in $(seq 1 10); do getent hosts deb.debian.org >/dev/null && exit 0; sleep 2; done; exit 1'; }
check_libpam_systemd()    { vm 'dpkg -s libpam-systemd >/dev/null'; }
check_no_bashrc_backup()  { vm 'test -z "$(ls -A ~ | grep "^\.bashrc\.bak")"'; }
check_sudoers_mode()      { vm 'sudo stat -c %a /etc/sudoers.d/agent | grep -qx 440'; }

# No cloud-init seed: cloud-init stays disabled, so only systemd-repart + growfs can have grown root.
noseed_cloud_init_disabled() { qga 'cloud-init status' | grep -q disabled; }
noseed_root_grown() {
  local g; g=$(qga 'df --output=size -BG / | tail -1 | tr -dc 0-9')
  echo "root size: ${g}G (want >= 35)"; [ "$g" -ge 35 ]
}
check_audit_off()         { vm 'grep -qw audit=0 /proc/cmdline'; }  # kauditd_printk_skb lines flood the console otherwise
