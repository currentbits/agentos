#!/bin/bash
# Unit tests for the installer's pure helpers. Run on Linux (bash 5): test/installer_test.sh
set -euo pipefail
# shellcheck source=../installer/mkosi.extra/usr/lib/agentos-installer/lib.sh
. "$(dirname "$0")/../installer/mkosi.extra/usr/lib/agentos-installer/lib.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# parse_env: comments, blanks, CRLF, values with '=', last line without newline
printf '# comment\n\nAGENTOS_HOSTNAME=x\r\nPAD_TOKEN=abc==\nLAST=1' > "$t/a.env"
[ "$(parse_env "$t/a.env")" = $'AGENTOS_HOSTNAME=x\nPAD_TOKEN=abc==\nLAST=1' ] || fail parse_env
printf 'GOOD=1\nnot a pair\n' > "$t/b.env"
if parse_env "$t/b.env" >/dev/null 2>"$t/err"; then fail "parse_env accepted a bad line"; fi
grep -q '^line 2:' "$t/err" || fail "parse_env error names the line"
printf 'lower=1\n' > "$t/c.env"
if parse_env "$t/c.env" 2>/dev/null; then fail "parse_env accepted a lowercase key"; fi

# env_value
[ "$(printf 'A=1\nB=x=y\nA=2\n' | env_value A)" = 2 ] || fail "env_value last wins"
[ "$(printf 'B=x=y\n' | env_value B)" = "x=y" ] || fail "env_value keeps ="
[ -z "$(printf 'A=1\n' | env_value Z)" ] || fail "env_value absent"

# installer keys
is_installer_key AGENTOS_INSTALL_DISK || fail is_installer_key
if is_installer_key AGENTOS_HOSTNAME; then fail "AGENTOS_HOSTNAME is not installer-only"; fi

# kernel command line
h64=$(printf 'a%.0s' $(seq 1 64))
cl="BOOT_IMAGE=/vmlinuz root=PARTUUID=x agentos.autoinstall=https://h.example/a.env agentos.autoinstall_sha256=$h64 quiet"
[ "$(cmdline_get agentos.autoinstall "$cl")" = "https://h.example/a.env" ] || fail cmdline_get
if cmdline_get agentos.nothere "$cl" >/dev/null; then fail "cmdline_get absent"; fi

# cmdline_get must not glob-expand the cmdline (URLs contain '?' and '*', and so do real filenames
# that can sit in the caller's CWD). Build a directory whose contents are exactly matched by the
# glob pattern that "https://h/x?y=1" becomes if word-split without quoting.
mkdir -p "$t/glob/agentos.autoinstall=https:/h"
touch "$t/glob/agentos.autoinstall=https:/h/xZy=1"
(cd "$t/glob" && [ "$(cmdline_get agentos.autoinstall "agentos.autoinstall=https://h/x?y=1")" = "https://h/x?y=1" ]) ||
  fail "cmdline_get glob-expanded a url"
(cd "$t" && [ "$(cmdline_get agentos.other "foo=1 * agentos.other=5")" = 5 ]) ||
  fail "cmdline_get: bare * token changed another key's value"

# validators
valid_https_url "https://h.example:8443/x?y=1" || fail url1
for bad in "http://h/x" "https://h/a b" "https://" "ftp://h/x" "https://user@host/x" "https://[::1]/x"; do
  if valid_https_url "$bad"; then fail "url accepted: $bad"; fi
done
valid_sha256 "$h64" || fail sha
if valid_sha256 ABC; then fail "sha accepted ABC"; fi
valid_hostname agentos-01 || fail hostname
for bad in -bad Bad "" "a_b" "$(printf 'a%.0s' $(seq 1 64))"; do
  if valid_hostname "$bad"; then fail "hostname accepted: $bad"; fi
done
valid_ipv4 10.0.0.1 || fail ipv4
valid_ipv4 0.0.0.0 || fail "ipv4 rejected 0.0.0.0"
for bad in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d 08.1.1.1 010.0.0.1 1.2.3.04; do
  if valid_ipv4 "$bad"; then fail "ipv4 accepted: $bad"; fi
done
# network_file's caller validates each DNS entry with valid_ipv4 before calling network_file;
# a rejected entry here is what keeps a ';'-laced DNS value out of the generated unit.
if valid_ipv4 "1.1.1.1;evil"; then fail "ipv4 accepted DNS injection"; fi
valid_cidr 192.168.1.10/24 || fail cidr
for bad in 192.168.1.10 192.168.1.10/33 300.1.1.1/24; do if valid_cidr "$bad"; then fail "cidr accepted: $bad"; fi; done
valid_gateway 192.168.2.225/24 192.168.2.254 || fail gateway
valid_gateway 10.1.2.3/8 10.200.0.1 || fail "gateway /8"
# The box's own address as gateway left an installed box with no IPv4 internet (GitHub has no IPv6).
for bad in "192.168.2.225/24 192.168.2.225" "192.168.2.225/24 192.168.3.1" "192.168.2.225/24 x" "192.168.2.225 192.168.2.1"; do
  if valid_gateway $bad; then fail "gateway accepted: $bad"; fi
done
valid_iface enp3s0 || fail iface
for bad in "en p" averyveryverylongname ""; do if valid_iface "$bad"; then fail "iface accepted: $bad"; fi; done
valid_password_hash '$6$salt$hash' || fail hash6
valid_password_hash '$y$j9T$a$b' || fail hashy
for bad in plain '$1$x$y' '$6$a b' '$6$a:b' "$(printf '$6$a\nb')"; do
  if valid_password_hash "$bad"; then fail "hash accepted: $bad"; fi
done
valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake test@x" || fail sshkey
for bad in "$(printf 'ssh-ed25519 AAAA a\ncommand="x" ssh-ed25519 AAAA b')" 'command="x" ssh-ed25519 AAAA' "ssh-dss AAAA"; do
  if valid_ssh_pubkey "$bad"; then fail "ssh key accepted: $bad"; fi
done

# network_file
nf=$(network_file enp1s0 10.0.0.5/24 10.0.0.1 1.1.1.1,9.9.9.9)
for want in "[Match]" "Name=enp1s0" "[Network]" "Address=10.0.0.5/24" "Gateway=10.0.0.1" "DNS=1.1.1.1" "DNS=9.9.9.9"; do
  grep -qxF "$want" <<< "$nf" || fail "network_file missing $want"
done
[ "$(network_file e0 10.0.0.5/24 10.0.0.1 "" | grep -c '^DNS=')" = 0 ] || fail "network_file empty DNS"

# autoinstall_source
[ "$(autoinstall_source "$cl" "")" = "url https://h.example/a.env $h64" ] || fail "source url"
[ "$(autoinstall_source "agentos.autoinstall=https://h/x" "")" = "url https://h/x " ] || fail "source url no sha"
if autoinstall_source "agentos.autoinstall=http://h/x" "" 2>/dev/null; then fail "source accepted http"; fi
if autoinstall_source "agentos.autoinstall=https://h/x agentos.autoinstall_sha256=zz" "" 2>/dev/null; then fail "source accepted bad sha"; fi
printf 'AGENTOS_INSTALL_DISK=/dev/vdb\n' > "$t/fat.env"
[ "$(autoinstall_source "quiet" "$t/fat.env")" = "file $t/fat.env" ] || fail "source fat"
printf 'AGENTOS_HOSTNAME=x\n' > "$t/fat2.env"
[ "$(autoinstall_source "quiet" "$t/fat2.env")" = none ] || fail "source fat without disk"
[ "$(autoinstall_source "quiet" "$t/missing.env")" = none ] || fail "source none"
[ "$(autoinstall_source "agentos.autoinstall=https://h/x" "$t/fat.env" | cut -d' ' -f1)" = url ] || fail "url wins over fat"

# disk_in_use: holders on the disk itself or on any of its partitions (LVM/RAID/dm)
mkdir -p "$t/sys/vda/holders" "$t/sys/vda/vda1/holders" "$t/sys/vda/vda2/holders"
if disk_in_use "$t/sys/vda"; then fail "disk_in_use: no holders"; fi
touch "$t/sys/vda/vda2/holders/dm-0"
disk_in_use "$t/sys/vda" || fail "disk_in_use: partition holder"
rm "$t/sys/vda/vda2/holders/dm-0"; touch "$t/sys/vda/holders/md0"
disk_in_use "$t/sys/vda" || fail "disk_in_use: disk holder"
mkdir -p "$t/sys/nvme0n1/nvme0n1p1/holders"; touch "$t/sys/nvme0n1/nvme0n1p1/holders/dm-1"
disk_in_use "$t/sys/nvme0n1" || fail "disk_in_use: nvme partition holder"

# url_host: download errors show only the host (the path/query may carry a secret)
[ "$(url_host "https://h.example:8443/a/b.env?token=s3cret#x")" = "h.example:8443" ] || fail url_host
[ "$(url_host "https://h.example?token=s3cret")" = "h.example" ] || fail "url_host query without path"

# rewrite_root_partuuid: per-install root PARTUUID in the ESP's grub config(s)
old=9e5d1375-3ecc-451f-a377-ef0275d46c26 new=0b7a2f0e-1111-4222-8333-444455556666
mkdir -p "$t/esp/grub" "$t/esp/EFI/debian"
printf 'configfile /grub/grub.cfg\n' > "$t/esp/EFI/debian/grub.cfg"
printf 'menuentry "a" {\n    linux /vmlinuz root=PARTUUID=%s console=ttyS0\n}\n' "$old" > "$t/esp/grub/grub.cfg"
printf '\0binary root=PARTUUID=%s\n' "$old" > "$t/esp/initrd"
rewrite_root_partuuid "$t/esp" "$old" "$new" || fail "rewrite_root_partuuid"
grep -qF "root=PARTUUID=$new console=ttyS0" "$t/esp/grub/grub.cfg" || fail "rewrite_root_partuuid: new value"
if grep -qF "$old" "$t/esp/grub/grub.cfg"; then fail "rewrite_root_partuuid: old value left"; fi
[ "$(cat "$t/esp/EFI/debian/grub.cfg")" = "configfile /grub/grub.cfg" ] || fail "rewrite_root_partuuid touched the early config"
grep -qaF "$old" "$t/esp/initrd" || fail "rewrite_root_partuuid edited a binary file"
# a second run finds $new, not $old: must fail, not silently succeed
if rewrite_root_partuuid "$t/esp" "$old" "$new" 2>/dev/null; then fail "rewrite_root_partuuid accepted a config without the old value"; fi
rm -rf "$t/esp/grub"
if rewrite_root_partuuid "$t/esp" "$old" "$new" 2>/dev/null; then fail "rewrite_root_partuuid accepted an ESP without root=PARTUUID"; fi
if rewrite_root_partuuid "$t/esp" "$old" 'x/;s' 2>/dev/null; then fail "rewrite_root_partuuid accepted a non-UUID"; fi

# fstab_root_partuuid
printf '# Root is mounted by the initrd\nPARTLABEL=root-x86-64  /  ext4  defaults,x-systemd.growfs  0  0\n' > "$t/fstab"
fstab_root_partuuid "$t/fstab" "$new" || fail fstab_root_partuuid
grep -qx "PARTUUID=$new  /  ext4  defaults,x-systemd.growfs  0  0" "$t/fstab" || fail "fstab_root_partuuid line"
if fstab_root_partuuid "$t/fstab" "$new" 2>/dev/null; then fail "fstab_root_partuuid accepted fstab without the PARTLABEL line"; fi

# loop_backing_drive: a loop device's backing file may only be an optical drive (sr*)
[ "$(loop_backing_drive /sr0)" = sr0 ] || fail "loop_backing_drive /sr0"
[ "$(loop_backing_drive /dev/sr12)" = sr12 ] || fail "loop_backing_drive /dev/sr12"
for b in /sda /dev/nvme0n1 /var/tmp/x.img /sr /srx "" /; do
  if loop_backing_drive "$b" >/dev/null; then fail "loop_backing_drive accepted '$b'"; fi
done

# web_ui_summary: how the summary screen says the web UI will be reachable
[ "$(web_ui_summary 0 0)" = 'off (turn it on later: sudo agentos-config)' ] || fail "web_ui_summary off"
[ "$(web_ui_summary '' 0)" = 'off (turn it on later: sudo agentos-config)' ] || fail "web_ui_summary no key"
[ "$(web_ui_summary 1 0)" = 'on the tailnet, once you allow your login (AGENTOS_WEB_USERS)' ] || fail "web_ui_summary tailnet"
[ "$(web_ui_summary 0 1)" = 'https://<LAN address> (password login)' ] || fail "web_ui_summary LAN"
[ "$(web_ui_summary 1 1)" = 'https://<LAN address> (password login); also on the tailnet, once you allow your login (AGENTOS_WEB_USERS)' ] || fail "web_ui_summary both"

echo "installer lib OK"
