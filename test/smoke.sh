#!/bin/bash
# Boot an AgentOS image in QEMU (UEFI and/or BIOS) and run test/checks/*.sh against it.
# Modes: uefi, bios (cloud-init seed, SSH; runs check_*), uefi-noseed (no seed, so no SSH key:
# runs noseed_* checks as root through the QEMU guest agent, see qga()).
set -euo pipefail

IMG=$(realpath "${1:?usage: smoke.sh <agentos.raw> [uefi] [bios] [uefi-noseed]}")
shift
MODES=("$@"); [ ${#MODES[@]} -gt 0 ] || MODES=(uefi bios)
HERE=$(cd "$(dirname "$0")" && pwd)
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d)
export WORK
FAILS=0

cleanup() {
  for p in "$WORK"/*.pid; do [ -e "$p" ] && kill "$(cat "$p")" 2>/dev/null || true; done
  [ "${KEEP_WORK:-0}" = 1 ] && echo "work dir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"

cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$WORK/key.pub")
write_files:
  - path: /etc/agentos/agentos.env
    permissions: "0600"
    content: |
      AGENTOS_HOSTNAME=agentos-test
      AGENTOS_LAN_SSH=1
      AGENTOS_AUTO_REBOOT=0
      ANTHROPIC_API_KEY=sk-test-dummy
      PAD_TOKEN=abc==
      PAD1_TOKEN=abc=
EOF

vm()  { ssh -i "$WORK/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=5 agent@127.0.0.1 "$@"; }
vml() { vm "bash -lc $(printf '%q' "$1")"; }
# qga '<sh cmd>': run as root in the guest via the QEMU guest agent; prints stdout, returns its exit code.
qga() {
  python3 - "$WORK/qga-$MODE.sock" "$1" <<'PY'
import base64, json, random, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(sys.argv[1]); f = s.makefile("rw")
def send(cmd, **a): f.write(json.dumps({"execute": cmd, "arguments": a}) + "\n"); f.flush()
i = random.randint(1, 2**31); send("guest-sync", id=i)
while json.loads(f.readline()).get("return") != i: pass   # skip stale replies
def rpc(cmd, **a):
    send(cmd, **a); r = json.loads(f.readline())
    if "error" in r: sys.exit(f"qga {cmd}: {r['error']}")
    return r["return"]
pid = rpc("guest-exec", path="/bin/sh", arg=["-c", sys.argv[2]], **{"capture-output": True})["pid"]
while not (st := rpc("guest-exec-status", pid=pid))["exited"]: time.sleep(0.5)
sys.stdout.write(base64.b64decode(st.get("out-data", "")).decode())
sys.stderr.write(base64.b64decode(st.get("err-data", "")).decode())
sys.exit(st.get("exitcode", 1))
PY
}
export -f vm vml qga

boot() {  # boot <mode> <port>
  local mode=$1
  PORT=$2; HOSTPORT_HTTP=$(( $2 + 1 ))
  export PORT HOSTPORT_HTTP MODE=$mode
  printf 'instance-id: smoke-%s-%s\n' "$mode" "$RANDOM" > "$WORK/meta-data"
  local seed=()
  if [[ $mode != *-noseed ]]; then
    cloud-localds "$WORK/seed-$mode.iso" "$WORK/user-data" "$WORK/meta-data"
    seed=(-drive "file=$WORK/seed-$mode.iso,media=cdrom")
  fi
  qemu-img convert -O qcow2 "$IMG" "$WORK/disk-$mode.qcow2"
  qemu-img resize -q "$WORK/disk-$mode.qcow2" 40G
  local fw=()
  if [[ $mode == uefi* ]]; then
    cp "$OVMF_VARS" "$WORK/vars.fd"
    fw=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd")
  fi
  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 -smp 2 "${fw[@]}" \
    -drive "file=$WORK/disk-$mode.qcow2,if=virtio" \
    "${seed[@]}" \
    -chardev "socket,id=qga0,path=$WORK/qga-$mode.sock,server=on,wait=off" \
    -device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22,hostfwd=tcp:127.0.0.1:$HOSTPORT_HTTP-:8080" \
    -display none -serial "file:$WORK/serial-$mode.log" \
    -daemonize -pidfile "$WORK/qemu-$mode.pid"
  if [[ $mode == *-noseed ]]; then
    for _ in $(seq 1 120); do
      qga 'systemctl is-system-running --wait >/dev/null 2>&1 || true' 2>/dev/null && return 0
      sleep 5
    done
    echo "FAIL [$mode] guest agent never answered; serial log tail:"; tail -50 "$WORK/serial-$mode.log"
    return 1
  fi
  for _ in $(seq 1 120); do
    vm true 2>/dev/null && vm 'cloud-init status --wait >/dev/null 2>&1; systemctl is-system-running --wait >/dev/null 2>&1 || true' && return 0
    sleep 5
  done
  echo "FAIL [$mode] VM never became reachable over SSH; serial log tail:"; tail -50 "$WORK/serial-$mode.log"
  return 1
}

run_checks() {
  local f fn prefix=check_
  [[ $MODE == *-noseed ]] && prefix=noseed_
  for f in "$HERE"/checks/*.sh; do
    # shellcheck source=/dev/null
    . "$f"
  done
  for fn in $(declare -F | awk '{print $3}' | grep "^$prefix" | sort); do
    if out=$("$fn" 2>&1); then echo "PASS [$MODE] $fn"
    else echo "FAIL [$MODE] $fn"; echo "$out" | sed 's/^/    /'; FAILS=$((FAILS + 1)); fi
  done
}

port=2222
for mode in "${MODES[@]}"; do
  if boot "$mode" "$port"; then run_checks; else FAILS=$((FAILS + 1)); fi
  kill "$(cat "$WORK/qemu-$mode.pid")" 2>/dev/null || true
  port=$((port + 10))
done

[ "$FAILS" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "$FAILS FAILURE(S)"; exit 1; }
