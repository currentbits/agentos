#!/bin/bash
# Unit test for the agentos package's postinst logic (configure): the image-build (chroot) path, new
# units (including a static one, which must not be started), migrations (order, run once, a failure
# stops the run and is retried, re-runs), a failed restart (warns, does not fail the configure), a
# missing "agent" user (tmpfiles and register-mcp are skipped with warnings) and the restarts and
# register-mcp --update that do run. systemctl, systemd-tmpfiles, runuser and id are fakes that log
# argv (systemctl also reports the enablement state is-enabled would print).
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
C=$R/package/usr/local/lib/agentos/configure
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
L=$d/calls
mkdir -p "$d/bin" "$d/lib/migrations" "$d/state" "$d/run" "$d/old"
for c in systemd-tmpfiles runuser; do printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$c" "$L" > "$d/bin/$c"; done
# systemctl: logs; is-enabled prints (and exits per) the state a preset would leave a unit in: a
# "*-off*" unit is disabled, a "*-static*" unit is static (exit 0, but not "enabled"), everything
# else is enabled. try-restart fails while "$d/fail-restart" exists.
cat > "$d/bin/systemctl" <<EOS
#!/bin/sh
echo "systemctl \$*" >> "$L"
case "\$1" in
  is-enabled)
    case "\$2" in
      *-off*) echo disabled; exit 1 ;;
      *-static*) echo static; exit 0 ;;
      *) echo enabled; exit 0 ;;
    esac ;;
  try-restart) [ ! -e "$d/fail-restart" ] || exit 1 ;;
esac
exit 0
EOS
printf '#!/bin/sh\n[ "$1" = agent ]\n' > "$d/bin/id"
chmod +x "$d/bin/"*
printf 'agentos-web.service\nagentos-new.timer\nagentos-new-off.service\nagentos-new-static.service\n' > "$d/lib/units.new"
for n in 001-first 002-flaky 003-third; do
  printf '#!/bin/bash\n[ ! -e "%s/fail-%s" ] || exit 1\necho %s >> "%s/ran"\n' "$d" "$n" "$n" "$d" > "$d/lib/migrations/$n.sh"
done
run() { env PATH="$d/bin:$PATH" AGENTOS_LIB="$d/lib" AGENTOS_STATE="$d/state" AGENTOS_RUN="$d/run" AGENTOS_OLD_UNITS="$d/old" "$C" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { rm -rf "$d/state" "$L" "$d/ran"; mkdir -p "$d/state"; touch "$L"; }

# Not "configure" (e.g. abort-upgrade): nothing.
reset; run abort-upgrade 1.0; [ ! -s "$L" ] && [ ! -e "$d/state/units.seen" ] || fail "abort-upgrade did something"

# Image build: no running systemd. Units recorded as seen, migrations as done, nothing run.
reset; run configure
cmp -s "$d/lib/units.new" "$d/state/units.seen" || fail "chroot: units.seen"
[ "$(cat "$d/state/migrations.done")" = $'001-first.sh\n002-flaky.sh\n003-third.sh' ] || fail "chroot: migrations.done"
[ ! -e "$d/ran" ] && [ ! -s "$L" ] || fail "chroot: ran something: $(cat "$L" "$d/ran" 2>/dev/null)"

# Live upgrade: agentos-web is known; the new units get the preset; only the one actually enabled
# starts (the static one's is-enabled exits 0 too, but it must not be started).
mkdir -p "$d/run/systemd/system"
reset; echo agentos-web.service > "$d/state/units.seen"; touch "$d/fail-002-flaky"
if run configure 1.0 >/dev/null 2>&1; then fail "a failing migration must fail the configure"; fi
[ "$(cat "$d/ran")" = 001-first ] || fail "order/stop: $(cat "$d/ran")"
[ "$(cat "$d/state/migrations.done")" = 001-first.sh ] || fail "done after failure"
want="systemctl daemon-reload
systemd-tmpfiles --create /usr/lib/tmpfiles.d/agentos.conf
systemctl preset agentos-new.timer
systemctl is-enabled agentos-new.timer
systemctl start --no-block agentos-new.timer
systemctl preset agentos-new-off.service
systemctl is-enabled agentos-new-off.service
systemctl preset agentos-new-static.service
systemctl is-enabled agentos-new-static.service"
[ "$(cat "$L")" = "$want" ] || fail "calls before the failed migration: $(cat "$L")"
# Retried on the next update: the failed one and the rest run, the done one does not.
rm "$d/fail-002-flaky"; : > "$L"; run configure 1.0 >/dev/null
[ "$(cat "$d/ran")" = $'001-first\n002-flaky\n003-third' ] || fail "retry: $(cat "$d/ran")"
grep -qx 'systemctl try-restart agentos-web.service agentos-mcp-http.service agentos-novnc.service agentos-firewall.service' "$L" || fail "restarts"
grep -q '^runuser -u agent -- env -i HOME=/home/agent USER=agent PATH=.* .*/register-mcp --update$' "$L" || fail "register-mcp --update"
! grep -q preset "$L" || fail "units presets applied twice"
# Re-run: no migration runs again.
: > "$L"; run configure 1.1 >/dev/null
[ "$(wc -l < "$d/ran")" = 3 ] || fail "re-run re-ran a migration"

# A failed restart warns but does not fail the configure, and register-mcp --update still runs.
reset; printf '%s\n' agentos-web.service agentos-new.timer agentos-new-off.service agentos-new-static.service > "$d/state/units.seen"
touch "$d/fail-restart"
if ! err=$(run configure 1.0 2>&1 >/dev/null); then fail "a failed restart must not fail the configure"; fi
rm -f "$d/fail-restart"
echo "$err" | grep -q 'restarting AgentOS services failed' || fail "missing restart-failed warning: $err"
grep -q '^runuser -u agent -- env -i HOME=/home/agent USER=agent PATH=.* .*/register-mcp --update$' "$L" || fail "register-mcp did not run after a failed restart"

# No "agent" user yet (e.g. first configure, before firstboot creates it): tmpfiles and
# register-mcp are both skipped, each with a warning, but the configure still succeeds.
reset; printf '%s\n' agentos-web.service agentos-new.timer agentos-new-off.service agentos-new-static.service > "$d/state/units.seen"
printf '#!/bin/sh\nexit 1\n' > "$d/bin/id"
if ! err=$(run configure 1.0 2>&1 >/dev/null); then fail "a missing agent user must not fail the configure"; fi
printf '#!/bin/sh\n[ "$1" = agent ]\n' > "$d/bin/id"
echo "$err" | grep -q "skipping systemd-tmpfiles --create" || fail "missing tmpfiles-skip warning: $err"
echo "$err" | grep -q "skipping register-mcp --update" || fail "missing register-mcp-skip warning: $err"
! grep -q tmpfiles "$L" || fail "tmpfiles ran without an agent user"
! grep -q runuser "$L" || fail "register-mcp ran without an agent user"

# First configure on a box from before the package: units it already had (old place) count as seen.
reset; touch "$d/old/agentos-web.service"; mkdir -p "$d/old/multi-user.target.wants"
run configure >/dev/null
[ "$(cat "$d/state/units.seen")" = $'agentos-web.service\nagentos-new.timer\nagentos-new-off.service\nagentos-new-static.service' ] || fail "seed: $(cat "$d/state/units.seen")"
! grep -q 'preset agentos-web' "$L" || fail "seed: existing unit got the preset"
echo "configure OK"
