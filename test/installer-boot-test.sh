#!/bin/bash
# Boot the installer image (UEFI) as a USB disk and as a CD; each must print the READY marker.
# SECUREBOOT=1: Secure Boot enforced, Microsoft keys enrolled (shim -> Debian-signed GRUB and kernel).
# The OVMF file names are the same in Debian 13 and Ubuntu 24.04; OVMF_CODE/OVMF_VARS override them.
# USB legs: the kernel command line must carry none of the CD-only arguments (agentos_cdargs).
set -euo pipefail
INST=$(realpath "${1:?usage: installer-boot-test.sh <agentos-installer.raw>}")
MACHINE=q35; SB=(); SB_MARK=""
if [ "${SECUREBOOT:-0}" = 1 ]; then
  OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.secboot.fd} OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}
  MACHINE=q35,smm=on; SB=(-global "driver=cfi.pflash01,property=secure,value=on"); SB_MARK="Secure boot enabled"
fi
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d); trap 'pkill -F "$WORK/q.pid" 2>/dev/null || true; rm -rf "$WORK"' EXIT
FAILS=0

boot_until() {  # boot_until <label> <marker> <qemu drive args...>
  local label=$1 marker=$2; shift 2
  cp "$OVMF_VARS" "$WORK/vars.fd"; : > "$WORK/serial.log"
  qemu-system-x86_64 -machine "$MACHINE" "${SB[@]}" -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    "$@" -nic user,model=virtio-net-pci -display none -serial "file:$WORK/serial.log" \
    -daemonize -pidfile "$WORK/q.pid"
  for _ in $(seq 1 90); do grep -q "$marker" "$WORK/serial.log" && break; sleep 2; done
  pkill -F "$WORK/q.pid" 2>/dev/null || true; sleep 1
  local cmdline; cmdline=$(grep -a -m1 "Kernel command line:" "$WORK/serial.log") || cmdline=""
  if [[ $label == usb* ]] && grep -Eq 'agentos\.cd|volatile' <<< "$cmdline"; then
    echo "FAIL [$label] CD-only arguments on a USB boot: $cmdline"; FAILS=$((FAILS + 1)); return
  fi
  if grep -q "$marker" "$WORK/serial.log" && grep -q "$SB_MARK" "$WORK/serial.log" && [ -n "$cmdline" ]; then echo "PASS [$label] $marker${SB_MARK:+ ($SB_MARK)}"
  else echo "FAIL [$label] no '$marker'${SB_MARK:+ and '$SB_MARK'}; serial tail:"; tail -30 "$WORK/serial.log"; FAILS=$((FAILS + 1)); fi
}

boot_until usb "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,if=virtio,readonly=on"
boot_until usb-tui "AGENTOS-INSTALLER TUI STARTED" -drive "file=$INST,format=raw,if=virtio,readonly=on"
if [ "${SKIP_CD:-0}" != 1 ]; then  # El Torito: a virtual CD (IPMI/iDRAC virtual media, Hyper-V DVD)
  boot_until cd "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,media=cdrom,readonly=on"
  boot_until cd-tui "AGENTOS-INSTALLER TUI STARTED" -drive "file=$INST,format=raw,media=cdrom,readonly=on"
fi
[ "$FAILS" -eq 0 ] && echo "INSTALLER BOOT OK" || { echo "$FAILS FAILURE(S)"; exit 1; }
