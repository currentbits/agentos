#!/bin/bash
# Prove the one-time bootstrap in docs/updates.md ("Boxes installed before updates existed") in a
# real VM: boot an image built before the agentos package existed (commit f2c51ea, the parent of
# the first package commit), point it at a locally served, test-key-signed apt repo containing the
# current agentos .deb through the same override test/checks/99-update.sh's check_update_end_to_end
# uses (a local sources.list.d entry naming a test keyring), run the documented steps verbatim with
# only the URL and key swapped for the test repo's, and verify what the docs promise: the package
# installed, migration 001 moved the old unit copies aside, the services and web UI are up, the
# MCP/skill registrations ran, and a --check against the test repo works.
# Not part of the default smoke suite (test/smoke.sh): it needs a separate pre-package image. Build
# one (once; the raw image is large and not worth rebuilding per run) in its own git worktree, e.g.:
#   git worktree add --detach /tmp/agentos-f2c51ea f2c51ea
#   rsync -a --delete --exclude .git /tmp/agentos-f2c51ea/ <build-host>:/root/agentos-old/
#   ssh <build-host> 'cd /root/agentos-old && mkosi -f build'
# then run this script against <build-host>:/root/agentos-old/mkosi.output/agentos.raw and a
# freshly built mkosi.packages/agentos_*.deb from the current tree.
#   test/bootstrap-test.sh <old-agentos.raw> <agentos.deb>
set -euo pipefail
OLD=$(realpath "${1:?usage: bootstrap-test.sh <old-agentos.raw> <agentos.deb>}")
DEB=$(realpath "${2:?usage: bootstrap-test.sh <old-agentos.raw> <agentos.deb>}")
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
WORK=$(mktemp -d); export GNUPGHOME=$WORK/gnupg
trap 'pkill -F "$WORK/qemu.pid" 2>/dev/null || true; [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"' EXIT
FAILS=0

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$WORK/key.pub")
write_files:
  - path: /etc/agentos/agentos.env
    permissions: "0600"
    content: |
      AGENTOS_HOSTNAME=agentos-boot-test
      AGENTOS_LAN_SSH=1
      AGENTOS_AUTO_REBOOT=0
      ANTHROPIC_API_KEY=sk-test-dummy
EOF
echo "instance-id: bootstrap-test-$RANDOM" > "$WORK/meta-data"
cloud-localds "$WORK/seed.iso" "$WORK/user-data" "$WORK/meta-data"
qemu-img convert -O qcow2 "$OLD" "$WORK/disk.qcow2"
qemu-img resize -q "$WORK/disk.qcow2" 40G
cp "$OVMF_VARS" "$WORK/vars.fd"
PORT=2322
qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
  -drive "file=$WORK/disk.qcow2,if=virtio" -drive "file=$WORK/seed.iso,media=cdrom" \
  -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22" \
  -display none -serial "file:$WORK/serial.log" -daemonize -pidfile "$WORK/qemu.pid"

vm() { ssh -i "$WORK/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=5 agent@127.0.0.1 "$@"; }
expect() {  # expect <label> <command...>
  if "${@:2}"; then echo "PASS [bootstrap] $1"; else echo "FAIL [bootstrap] $1"; FAILS=$((FAILS + 1)); fi
}

for _ in $(seq 1 120); do
  vm true 2>/dev/null && vm 'cloud-init status --wait >/dev/null 2>&1; systemctl is-system-running --wait >/dev/null 2>&1 || true' && break
  sleep 5
done
if ! vm true 2>/dev/null; then
  echo "FAIL [bootstrap] VM never became reachable over SSH"; tail -50 "$WORK/serial.log"; exit 1
fi

# A local, test-key-signed repo holding only the current agentos .deb -- the same shape
# test/checks/99-update.sh builds for check_update_end_to_end, never tools/apt-publish.sh (which
# refuses a test key / a repo this small on purpose).
mkdir -m 700 "$GNUPGHOME"
gpg -q --batch --passphrase '' --quick-gen-key 'AgentOS bootstrap-test <test@invalid>' ed25519 sign never 2>/dev/null
R=$WORK/repo
mkdir -p "$R/pool" "$R/dists/stable/main/binary-amd64"
cp "$DEB" "$R/pool/"
(cd "$R" && apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages)
apt-ftparchive -o APT::FTPArchive::Release::Origin=AgentOS -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Components=main -o APT::FTPArchive::Release::Architectures=amd64 \
  release "$R/dists/stable" > "$WORK/Release"
mv "$WORK/Release" "$R/dists/stable/Release"
gpg -q --batch --yes --clearsign -o "$R/dists/stable/InRelease" "$R/dists/stable/Release"
gpg -q --batch --export > "$R/agentos-archive.gpg"
tar -C "$R" -cf - . | vm 'rm -rf ~/boot-repo && mkdir ~/boot-repo && tar -C ~/boot-repo -xf -'
expect repo_served vm '
  sudo systemctl stop boot-repo >/dev/null 2>&1
  sudo systemd-run --unit=boot-repo -p User=agent python3 -m http.server 8099 --bind 127.0.0.1 --directory /home/agent/boot-repo &&
  for _ in $(seq 1 20); do curl -fsS -o /dev/null http://127.0.0.1:8099/dists/stable/InRelease && exit 0; sleep 0.5; done; exit 1'

# docs/updates.md, "Boxes installed before updates existed", verbatim except the URL and key: the
# real bootstrap points at https://<owner>.github.io/<repo>/apt and the real archive key.
expect bootstrap_steps vm '
  curl -fsSLo /tmp/agentos-archive.gpg http://127.0.0.1:8099/agentos-archive.gpg &&
  { command -v gpg >/dev/null || { sudo apt-get update >/dev/null && sudo apt-get install -y gnupg >/dev/null; }; } &&
  gpg --show-keys /tmp/agentos-archive.gpg >/dev/null &&
  sudo install -m 644 /tmp/agentos-archive.gpg /usr/share/keyrings/agentos-archive.gpg &&
  printf "Types: deb\nURIs: http://127.0.0.1:8099\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/agentos-archive.gpg\n" |
    sudo tee /etc/apt/sources.list.d/agentos.sources >/dev/null &&
  sudo apt-get update &&
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold agentos'

expect dpkg_installed vm 'dpkg -s agentos | grep -qx "Status: install ok installed"'
# Clean apart from the one conffile this test deliberately pre-edited before installing (the
# sources.list.d override above) -- docs/updates.md: "yours is kept".
expect dpkg_verify_clean vm '
  bad=$(sudo dpkg -V agentos | grep -v "etc/apt/sources.list.d/agentos.sources" || true)
  [ -z "$bad" ] || { echo "$bad"; exit 1; }'
expect migration_001_ran vm '
  test -e /etc/systemd/system/agentos-web.service.pre-agentos &&
  test -e /etc/systemd/system/agentos-mcp-http.service.pre-agentos &&
  test -e /etc/systemd/system/agentos-firewall.service.pre-agentos &&
  grep -qx 001-units-to-usr-lib.sh /var/lib/agentos/migrations.done'
expect services_active vm '
  systemctl is-active --quiet agentos-web.service && systemctl is-active --quiet agentos-mcp-http.service &&
  systemctl is-active --quiet agentos-novnc.service && systemctl is-active --quiet agentos-firewall.service'
expect web_ui_answers vm '
  sudo agentos-config set AGENTOS_WEB_USERS smoke@example.com && sudo agentos-config apply &&
  for _ in $(seq 1 30); do
    test "$(curl -s -o /dev/null -m 10 -w "%{http_code}" -H "Tailscale-User-Login: smoke@example.com" http://127.0.0.1:7070/api/sessions)" = 200 && exit 0
    sleep 1
  done; exit 1'
expect mcp_and_skill_registered vm '
  claude mcp get agentos-ci 2>/dev/null | grep -q agentos-ci-mcp &&
  grep -A2 "^\[mcp_servers\.agentos-ci\]\$" ~/.codex/config.toml | grep -qx "tool_timeout_sec = 1900" &&
  test -e ~/.claude/skills/agentos-ci/SKILL.md'
expect update_check_against_test_repo vm 'sudo agentos-update --check >/dev/null; jq -e ".error == null" /var/lib/agentos/update.json >/dev/null'

if [ "$FAILS" -eq 0 ]; then echo "BOOTSTRAP TEST OK"; else echo "$FAILS FAILURE(S)"; exit 1; fi
