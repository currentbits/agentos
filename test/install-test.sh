#!/bin/bash
# End-to-end installer test: refusal cases, an unattended install onto a blank 40G disk,
# then the full smoke suite (uefi + bios) against the installed disk.
set -euo pipefail
INST=$(realpath "${1:?usage: install-test.sh <agentos-installer.raw>}")
HERE=$(cd "$(dirname "$0")" && pwd)
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d); trap 'pkill -F "$WORK/q.pid" 2>/dev/null || true; [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"' EXIT
FAILS=0
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
HASH=$(openssl passwd -6 -stdin <<< 'agentos-test-password')

# installer stick with agentos.env on its AGENTOS partition
stick() {  # stick <env-file> -> $WORK/stick.raw
  cp --sparse=always "$INST" "$WORK/stick.raw"
  local start
  start=$(partx -g -o START,NAME "$WORK/stick.raw" | awk '$2=="AGENTOS"{print $1}')
  [ -n "$start" ] || { echo "no AGENTOS partition in installer image" >&2; exit 1; }
  FAT="$WORK/stick.raw@@$((start * 512))"
  mcopy -o -i "$FAT" "$1" ::agentos.env
}
fat_env_gone() { local l; l=$(mdir -b -i "$FAT" ::) && ! grep -qix '::/agentos.env' <<< "$l"; }

run_installer() {  # run_installer <target.qcow2> <marker> <timeout-s>: boot until marker or poweroff
  cp "$OVMF_VARS" "$WORK/vars.fd"; : > "$WORK/serial.log"
  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$WORK/stick.raw,format=raw,if=none,id=stick" -device virtio-blk-pci,drive=stick,serial=agentos-stick \
    -drive "file=$1,format=qcow2,if=none,id=tgt" -device virtio-blk-pci,drive=tgt,serial=agentos-target \
    -nic user,model=virtio-net-pci -display none -serial "file:$WORK/serial.log" -no-reboot \
    -daemonize -pidfile "$WORK/q.pid"
  for _ in $(seq 1 "$3"); do
    grep -q "$2" "$WORK/serial.log" && break
    pkill -0 -F "$WORK/q.pid" 2>/dev/null || break
    sleep 1
  done
  for _ in $(seq 1 120); do pkill -0 -F "$WORK/q.pid" 2>/dev/null || break; [[ $2 == "AGENTOS INSTALL OK"* ]] || break; sleep 1; done
  pkill -F "$WORK/q.pid" 2>/dev/null || true; sleep 1
  grep -q "$2" "$WORK/serial.log"
}

expect() {  # expect <label> <command...>
  if "${@:2}"; then echo "PASS [install] $1"; else echo "FAIL [install] $1"; tail -40 "$WORK/serial.log"; FAILS=$((FAILS + 1)); fi
}
untouched() { [ "$(qemu-img info --output=json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])')" -lt 1048576 ]; }

# 1. refuses the installer's own disk; target untouched
printf 'AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-stick\n' > "$WORK/env"; stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/t1.qcow2" 40G
expect refuses_boot_disk run_installer "$WORK/t1.qcow2" "refusing to install onto the installer's own disk" 300
expect boot_disk_case_target_untouched untouched "$WORK/t1.qcow2"

# 2. refuses a disk smaller than 32 GiB
printf 'AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-target\n' > "$WORK/env"; stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/t2.qcow2" 20G
expect refuses_small_disk run_installer "$WORK/t2.qcow2" "smaller than 32 GiB" 300
expect small_disk_untouched untouched "$WORK/t2.qcow2"

# 3. refuses invalid settings before writing
printf 'AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-target\nAGENTOS_SSH_KEY=command="x" ssh-ed25519 AAAA\n' > "$WORK/env"; stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/t3.qcow2" 40G
expect refuses_bad_ssh_key run_installer "$WORK/t3.qcow2" "invalid AGENTOS_SSH_KEY" 300
expect bad_settings_untouched untouched "$WORK/t3.qcow2"

# 4. the real install
cat > "$WORK/env" <<EOF
AGENTOS_INSTALL_DISK=/dev/disk/by-id/virtio-agentos-target
AGENTOS_INSTALL_POWEROFF=1
AGENTOS_SSH_KEY=$(cat "$WORK/key.pub")
AGENTOS_PASSWORD_HASH=$HASH
AGENTOS_HOSTNAME=agentos-test
AGENTOS_LAN_SSH=1
AGENTOS_AUTO_REBOOT=0
ANTHROPIC_API_KEY=sk-test-dummy
PAD_TOKEN=abc==
PAD1_TOKEN=abc=
AGENTOS_NET_IFACE=enp0s2
AGENTOS_NET_ADDRESS=10.0.2.15/24
AGENTOS_NET_GATEWAY=10.0.2.2
AGENTOS_NET_DNS=10.0.2.3
EOF
stick "$WORK/env"
qemu-img create -q -f qcow2 "$WORK/target.qcow2" 40G
expect unattended_install run_installer "$WORK/target.qcow2" "AGENTOS INSTALL OK" 1800
expect fat_env_deleted fat_env_gone
expect fat_env_deleted_message grep -q "agentos.env deleted" "$WORK/serial.log"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURE(S) before smoke"; exit 1; fi

# 5. full smoke suite on the installed disk, booted UEFI and BIOS
SMOKE_DISK="$WORK/target.qcow2" SMOKE_KEY="$WORK/key" SMOKE_NOSEED=1 "$HERE/smoke.sh" "$INST" uefi bios
echo "INSTALL TEST OK"
