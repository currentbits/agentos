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

qmp() {  # qmp <json command>: prints QEMU's reply
  python3 - "$WORK/qmp" "$1" <<'EOF2'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
def cmd(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    while "return" not in (r := json.loads(f.readline())) and "error" not in r: pass
    return r
f.readline(); cmd({"execute": "qmp_capabilities"}); print(json.dumps(cmd(json.loads(sys.argv[2]))))
EOF2
}
hmp() { qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$1\"}}"; }
bad() { FAULT="${FAULT:+$FAULT; }$1"; }  # the fault injection did not happen as intended: fail the leg
kernel_started() { for _ in $(seq 1 300); do grep -aq 'Linux version' "$WORK/serial.log" && return; sleep 0.2; done; bad "no 'Linux version'"; }
# Late virtual media (seen on Unraid): the firmware reads the CD, but it is gone while the initrd probes it
# and back only after systemd's default 90 s device timeout. The first change hits the tray the guest
# locked, so udev ejects it; the second one inserts the medium.
late_media() {  # late_media <marker>
  kernel_started; hmp 'eject -f cd' >/dev/null
  hmp 'info block cd' | grep -q 'not inserted' || bad "eject did not take"
  sleep 100
  ! grep -q "$1" "$WORK/serial.log" || bad "'$1' before the media came back"
  hmp "change cd $INST raw read-only" >/dev/null; sleep 3; hmp "change cd $INST raw read-only" >/dev/null
}
# Stalled virtual media: present all along (no eject, no media-change event), but reads fail while the
# initrd probes it and work again 30 s later. Swaps the CD's file between the image and a blkdebug node
# that fails every read. 30 s is well within the 90 s device timeout: what this tests is the retry.
cd_file() { qmp "{\"execute\":\"blockdev-reopen\",\"arguments\":{\"options\":[{\"driver\":\"raw\",\"node-name\":\"cd\",\"read-only\":true,\"file\":\"$1\"}]}}" | grep -q '"return"'; }
stalled_media() {  # stalled_media <marker>
  kernel_started; cd_file err || bad "blockdev-reopen to blkdebug failed"
  hmp 'info block' | grep -q blkdebug || bad "the CD is not on the blkdebug node"
  sleep 30
  ! grep -q "$1" "$WORK/serial.log" || bad "'$1' while reads were failing"
  qmp '{"execute":"query-blockstats"}' | grep -Eq '"failed_rd_operations": [1-9]' || bad "no read failed during the stall"
  cd_file img || bad "blockdev-reopen back to the image failed"
}

boot_until() {  # boot_until <label> <marker> <qemu drive args...>
  local label=$1 marker=$2; shift 2
  cp "$OVMF_VARS" "$WORK/vars.fd"; : > "$WORK/serial.log"
  qemu-system-x86_64 -machine "$MACHINE" "${SB[@]}" -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    "$@" -nic user,model=virtio-net-pci -display none -serial "file:$WORK/serial.log" \
    -qmp "unix:$WORK/qmp,server,nowait" -daemonize -pidfile "$WORK/q.pid"
  FAULT=""
  case $label in cd-late-media) late_media "$marker" ;; cd-stall) stalled_media "$marker" ;; esac
  for _ in $(seq 1 150); do grep -q "$marker" "$WORK/serial.log" && break; sleep 2; done
  pkill -F "$WORK/q.pid" 2>/dev/null || true; sleep 1
  local cmdline; cmdline=$(grep -a -m1 "Kernel command line:" "$WORK/serial.log") || cmdline=""
  if [[ $label == usb* ]] && grep -Eq 'agentos\.cd|volatile|default_device_timeout' <<< "$cmdline"; then
    echo "FAIL [$label] CD-only arguments on a USB boot: $cmdline"; FAILS=$((FAILS + 1)); return
  fi
  if [ -n "$FAULT" ]; then echo "FAIL [$label] fault injection: $FAULT"; FAILS=$((FAILS + 1)); return; fi
  if grep -q "$marker" "$WORK/serial.log" && grep -q "$SB_MARK" "$WORK/serial.log" && [ -n "$cmdline" ]; then echo "PASS [$label] $marker${SB_MARK:+ ($SB_MARK)}"
  else echo "FAIL [$label] no '$marker'${SB_MARK:+ and '$SB_MARK'}; serial tail:"; tail -30 "$WORK/serial.log"; FAILS=$((FAILS + 1)); fi
}

boot_until usb "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,if=virtio,readonly=on"
boot_until usb-tui "AGENTOS-INSTALLER TUI STARTED" -drive "file=$INST,format=raw,if=virtio,readonly=on"
if [ "${SKIP_CD:-0}" != 1 ]; then  # El Torito: a virtual CD (IPMI/iDRAC virtual media, Hyper-V DVD)
  boot_until cd "AGENTOS-INSTALLER READY (interactive)" -drive "file=$INST,format=raw,media=cdrom,readonly=on"
  boot_until cd-tui "AGENTOS-INSTALLER TUI STARTED" -drive "file=$INST,format=raw,media=cdrom,readonly=on"
  boot_until cd-late-media "AGENTOS-INSTALLER READY (interactive)" \
    -drive "if=none,id=cd,file=$INST,format=raw,media=cdrom,readonly=on" -device ide-cd,bus=ide.0,drive=cd
  boot_until cd-stall "AGENTOS-INSTALLER READY (interactive)" -blockdev "driver=file,node-name=img,filename=$INST,read-only=on" \
    -blockdev "driver=blkdebug,node-name=err,image=img,read-only=on,inject-error.0.event=read_aio" \
    -blockdev "driver=raw,node-name=cd,file=img,read-only=on" -device ide-cd,bus=ide.0,drive=cd
fi
[ "$FAILS" -eq 0 ] && echo "INSTALLER BOOT OK" || { echo "$FAILS FAILURE(S)"; exit 1; }
