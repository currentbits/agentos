#!/bin/bash
# Boot the installer image (UEFI) as a USB disk and as a CD; each must print the READY marker.
set -euo pipefail
INST=$(realpath "${1:?usage: installer-boot-test.sh <agentos-installer.raw>}")
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d); trap 'pkill -F "$WORK/q.pid" 2>/dev/null || true; rm -rf "$WORK"' EXIT
FAILS=0

boot_until() {  # boot_until <label> <marker> <qemu drive args...>
  local label=$1 marker=$2; shift 2
  cp "$OVMF_VARS" "$WORK/vars.fd"; : > "$WORK/serial.log"
  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    "$@" -nic user,model=virtio-net-pci -display none -serial "file:$WORK/serial.log" \
    -daemonize -pidfile "$WORK/q.pid"
  for _ in $(seq 1 90); do grep -q "$marker" "$WORK/serial.log" && break; sleep 2; done
  pkill -F "$WORK/q.pid" 2>/dev/null || true; sleep 1
  if grep -q "$marker" "$WORK/serial.log"; then echo "PASS [$label] $marker"
  else echo "FAIL [$label] no '$marker'; serial tail:"; tail -30 "$WORK/serial.log"; FAILS=$((FAILS + 1)); fi
}

boot_until usb "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,if=virtio,readonly=on"
if [ "${SKIP_CD:-0}" != 1 ]; then
  boot_until cd "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,media=cdrom,readonly=on"
fi
[ "$FAILS" -eq 0 ] && echo "INSTALLER BOOT OK" || { echo "$FAILS FAILURE(S)"; exit 1; }
