# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
# Only run against disks written by the installer (smoke.sh with SMOKE_DISK set).
installed_cloud_init_disabled()   { vm 'test -f /etc/cloud/cloud-init.disabled'; }
installed_no_installer_keys()     { vm '! sudo grep -qE "^(AGENTOS_INSTALL_|AGENTOS_SSH_KEY|AGENTOS_PASSWORD_HASH|AGENTOS_NET_|AGENTOS_GITHUB_USER)" /etc/agentos/agentos.env'; }
installed_hostname_from_env()     { vm 'test "$(hostname)" = agentos-test'; }
installed_three_partitions_only() { vm 'test "$(lsblk -nro PARTLABEL /dev/vda | grep -c .)" = 3 && ! lsblk -nro PARTLABEL /dev/vda | grep -qx AGENTOS'; }
installed_password_set()          { vm 'test "$(sudo passwd -S agent | cut -d" " -f2)" = P'; }
# The installer's password logs in on the console: /bin/login + PAM, driven through a pty like agetty does.
installed_console_login() {
  vm 'sudo python3 -' <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0: os.execv("/bin/login", ["login", "agent"])
buf = b""
def until(p, t=30):
    global buf
    end = time.time() + t
    while p not in buf and time.time() < end:
        if select.select([fd], [], [], 1)[0]:
            # login hangs up its tty around authentication: the master briefly reads EIO.
            try: buf += os.read(fd, 4096)
            except OSError: time.sleep(0.5)
    return p in buf
ok = until(b"assword:")
if ok:
    os.write(fd, b"agentos-test-password\n")
    time.sleep(5)  # let the shell start before typing at it
    os.write(fd, b"echo LOGIN-OK-$(id -un); exit\n")
    ok = until(b"LOGIN-OK-agent")
if not ok: print(buf.decode(errors="replace")[-500:])
sys.exit(0 if ok else 1)
PY
}
installed_static_network()        { vm 'grep -qx "Address=10.0.2.15/24" /etc/systemd/network/10-agentos-static.network && ip -4 -o addr show | grep "10.0.2.15/24" | grep -vq dynamic'; }  # slirp DHCP gives the same IP: must not be a lease
# The installer gives each install new GUIDs: booted root PARTUUID != the image's, and cmdline + fstab follow it.
installed_root_partuuid_unique()  { [ -n "${SMOKE_ORIG_PARTUUID:-}" ] && vm "u=\$(lsblk -no PARTUUID \"\$(findmnt -no SOURCE /)\") && test -n \"\$u\" && test \"\$u\" != $SMOKE_ORIG_PARTUUID && grep -qw \"root=PARTUUID=\$u\" /proc/cmdline && grep -q \"^PARTUUID=\$u[[:space:]]\" /etc/fstab"; }
