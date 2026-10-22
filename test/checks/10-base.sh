# shellcheck shell=bash
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
check_networkd_dhcp()     { vm 'networkctl status >/dev/null && getent hosts deb.debian.org >/dev/null'; }
check_sudoers_mode()      { vm 'sudo stat -c %a /etc/sudoers.d/agent | grep -qx 440'; }
