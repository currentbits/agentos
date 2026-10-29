#!/bin/bash
# Boxes installed before the agentos package have AgentOS's units in /etc/systemd/system, where they
# shadow the package's copies in /usr/lib/systemd/system. Move each old copy that no package owns and
# that the package replaces out of the way (to "$f.pre-agentos", a suffix systemd's unit loader never
# matches: it only loads files whose name ends exactly in .service/.timer/.path/.conf), keeping the
# unit's enabled state. Safe to run again.
# AGENTOS_ETC_UNITS / AGENTOS_USR_UNITS point the unit test at scratch dirs.
set -euo pipefail
E=${AGENTOS_ETC_UNITS:-/etc/systemd/system} U=${AGENTOS_USR_UNITS:-/usr/lib/systemd/system}
for f in "$E"/agentos-*.service "$E"/agentos-*.timer "$E"/agentos-*.path "$E"/docker.service.d/10-agentos.conf; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  rel=${f#"$E"/}
  [ -e "$U/$rel" ] || continue
  if dpkg -S "$f" >/dev/null 2>&1; then continue; fi
  u=${rel##*/}
  was=$(systemctl is-enabled "$u" 2>/dev/null || true)
  mv -f "$f" "$f.pre-agentos"
  find "$E" -lname "$f" -delete   # its enablement symlinks, now dangling
  systemctl daemon-reload
  if [ "$was" = enabled ]; then systemctl enable --quiet "$u"; fi
done
