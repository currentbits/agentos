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
if parse_env "$t/b.env" 2>"$t/err"; then fail "parse_env accepted a bad line"; fi
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

# validators
valid_https_url "https://h.example:8443/x?y=1" || fail url1
for bad in "http://h/x" "https://h/a b" "https://" "ftp://h/x"; do
  if valid_https_url "$bad"; then fail "url accepted: $bad"; fi
done
valid_sha256 "$h64" || fail sha
if valid_sha256 ABC; then fail "sha accepted ABC"; fi
valid_hostname agentos-01 || fail hostname
for bad in -bad Bad "" "a_b" "$(printf 'a%.0s' $(seq 1 64))"; do
  if valid_hostname "$bad"; then fail "hostname accepted: $bad"; fi
done
valid_ipv4 10.0.0.1 || fail ipv4
for bad in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d; do if valid_ipv4 "$bad"; then fail "ipv4 accepted: $bad"; fi; done
valid_cidr 192.168.1.10/24 || fail cidr
for bad in 192.168.1.10 192.168.1.10/33 300.1.1.1/24; do if valid_cidr "$bad"; then fail "cidr accepted: $bad"; fi; done
valid_iface enp3s0 || fail iface
for bad in "en p" averyveryverylongname ""; do if valid_iface "$bad"; then fail "iface accepted: $bad"; fi; done
valid_password_hash '$6$salt$hash' || fail hash6
valid_password_hash '$y$j9T$a$b' || fail hashy
for bad in plain '$1$x$y' '$6$a b'; do if valid_password_hash "$bad"; then fail "hash accepted: $bad"; fi; done
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

echo "installer lib OK"
