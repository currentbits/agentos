#!/bin/bash
# Boxes installed before the agentos package have AgentOS's units in /etc/systemd/system, where they
# shadow the package's copies in /usr/lib/systemd/system. Remove each old copy that no package owns
# and that the package replaces, keeping the unit's enabled state. Safe to run again.
set -euo pipefail
E=/etc/systemd/system U=/usr/lib/systemd/system
for f in "$E"/agentos-*.service "$E"/agentos-*.timer "$E"/agentos-*.path "$E"/docker.service.d/10-agentos.conf; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  rel=${f#"$E"/}
  [ -e "$U/$rel" ] || continue
  if dpkg -S "$f" >/dev/null 2>&1; then continue; fi
  u=${rel##*/}
  was=$(systemctl is-enabled "$u" 2>/dev/null || true)
  rm -f "$f"
  find "$E" -lname "$f" -delete   # its enablement symlinks, now dangling
  systemctl daemon-reload
  if [ "$was" = enabled ]; then systemctl enable --quiet "$u"; fi
done
