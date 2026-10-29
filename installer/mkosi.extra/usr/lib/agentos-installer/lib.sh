# shellcheck shell=bash
# AgentOS installer: pure helpers (stdout/stderr only). Sourced by agentos-install and test/installer_test.sh.

INSTALLER_KEYS=(AGENTOS_INSTALL_DISK AGENTOS_INSTALL_POWEROFF AGENTOS_SSH_KEY AGENTOS_GITHUB_USER
                AGENTOS_PASSWORD_HASH AGENTOS_NET_IFACE AGENTOS_NET_ADDRESS AGENTOS_NET_GATEWAY AGENTOS_NET_DNS)
# shellcheck disable=SC2034 # used by scripts that source this file, not by lib.sh itself
MIN_DISK_BYTES=$((32 * 1024 * 1024 * 1024))
# shellcheck disable=SC2034 # used by scripts that source this file, not by lib.sh itself
ROOT_PARTLABEL=root-x86-64

is_installer_key() {
  local k
  for k in "${INSTALLER_KEYS[@]}"; do [ "$k" = "$1" ] && return 0; done
  return 1
}

parse_env() {
  local n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[A-Z_][A-Z0-9_]*= ]] || { echo "line $n: expected KEY=VALUE" >&2; return 2; }
    printf '%s\n' "$line"
  done < "$1"
}

env_value() {
  local line v=""
  while IFS= read -r line; do [ "${line%%=*}" = "$1" ] && v=${line#*=}; done
  printf '%s' "$v"
}

cmdline_get() {
  local -a words
  local w
  read -ra words <<< "$2"
  for w in "${words[@]}"; do [[ $w == "$1="* ]] && { printf '%s' "${w#*=}"; return 0; }; done
  return 1
}

valid_https_url()     { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]]; }
valid_sha256()        { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
valid_hostname()      { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_iface()         { [[ $1 =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
valid_password_hash() { [[ $1 =~ ^\$(6|y)\$[^:[:space:]]+$ ]]; }
valid_ipv4() {
  local oct='(0|[1-9][0-9]{0,2})'
  [[ $1 =~ ^$oct(\.$oct){3}$ ]] || return 1
  local o IFS=.
  for o in $1; do [ "$((10#$o))" -le 255 ] || return 1; done
}
valid_cidr() { [[ $1 == */* ]] && valid_ipv4 "${1%/*}" && [[ ${1#*/} =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]; }
# Keep in sync with cmd_add_ssh_key in package/usr/local/bin/agentos-config (the target re-validates).
valid_ssh_pubkey() {
  [[ $1 != *$'\n'* && $1 != *$'\r'* ]] &&
  [[ $1 =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]]
}

# disk_in_use /sys/class/block/<disk>: true if the disk or any of its partitions has holders (LVM/RAID/dm).
disk_in_use() {
  local h
  for h in "$1"/holders/* "$1/$(basename "$1")"*/holders/*; do [ -e "$h" ] && return 0; done
  return 1
}

network_file() {
  printf '[Match]\nName=%s\n\n[Network]\nAddress=%s\nGateway=%s\n' "$1" "$2" "$3"
  local d
  for d in ${4//,/ }; do printf 'DNS=%s\n' "$d"; done
}

# url_host <url>: host[:port] only; the path/query of an autoinstall URL may carry a secret.
url_host() { local h=${1#*://}; printf '%s' "${h%%[/?#]*}"; }

# loop_backing_drive <backing_file>: the optical drive (sr*) behind a loop device, else fail (closed).
loop_backing_drive() { local d=${1##*/}; [[ $d =~ ^sr[0-9]+$ ]] && printf '%s\n' "$d"; }

valid_uuid() { [[ $1 =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]]; }

# rewrite_root_partuuid <esp-dir> <old> <new>: point root=PARTUUID in every text config on the ESP
# (mkosi: /grub/grub.cfg; EFI/*/grub.cfg only chains to it) at <new>. Fails unless every
# root=PARTUUID= found is exactly <old>.
rewrite_root_partuuid() {
  local f files
  valid_uuid "$2" && valid_uuid "$3" || { echo "not a lowercase UUID: $2 / $3" >&2; return 1; }
  files=$(grep -rlI -e 'root=PARTUUID=' "$1") || { echo "no root=PARTUUID= under $1" >&2; return 1; }
  while IFS= read -r f; do
    ! grep -o 'root=PARTUUID=[^[:space:]]*' "$f" | grep -qvxF "root=PARTUUID=$2" ||
      { echo "$f: root=PARTUUID= is not $2" >&2; return 1; }
    sed -i "s/root=PARTUUID=$2/root=PARTUUID=$3/g" "$f"
  done <<< "$files"
}

# fstab_root_partuuid <fstab> <new>: mount / by this install's PARTUUID, not the label every AgentOS disk shares.
fstab_root_partuuid() {
  grep -q "^PARTLABEL=${ROOT_PARTLABEL}[[:space:]]" "$1" || { echo "$1: no PARTLABEL=$ROOT_PARTLABEL line" >&2; return 1; }
  sed -i "s/^PARTLABEL=$ROOT_PARTLABEL\([[:space:]]\)/PARTUUID=$2\1/" "$1"
}

autoinstall_source() {
  local url sha
  if url=$(cmdline_get agentos.autoinstall "$1"); then
    valid_https_url "$url" || { echo "agentos.autoinstall must be an https:// URL" >&2; return 2; }
    sha=$(cmdline_get agentos.autoinstall_sha256 "$1") || sha=""
    [ -z "$sha" ] || valid_sha256 "$sha" || { echo "agentos.autoinstall_sha256 must be 64 lowercase hex chars" >&2; return 2; }
    printf 'url %s %s\n' "$url" "$sha"
    return 0
  fi
  if [ -n "$2" ] && [ -f "$2" ] && grep -q '^AGENTOS_INSTALL_DISK=' "$2"; then
    printf 'file %s\n' "$2"
    return 0
  fi
  echo none
}
