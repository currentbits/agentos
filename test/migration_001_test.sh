#!/bin/bash
# Unit test for migration 001 (moves AgentOS's units from /etc/systemd/system into the package's
# /usr/lib/systemd/system, setting the stale /etc copy aside as "<name>.pre-agentos" -- a suffix
# systemd's unit loader never matches, so it's as good as gone to systemd -- only when no package
# owns it, removing only that unit's own enablement symlinks, and re-enabling it from /usr/lib if it
# was enabled). dpkg and systemctl are fakes that log argv; AGENTOS_ETC_UNITS/AGENTOS_USR_UNITS point
# the migration at a scratch E/U tree instead of the real /etc and /usr/lib.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
M=$R/package/usr/local/lib/agentos/migrations/001-units-to-usr-lib.sh
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
E=$d/etc; U=$d/usr-lib; L=$d/calls
mkdir -p "$E/multi-user.target.wants" "$U" "$d/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }

# dpkg -S: only agentos-pkgowned.service is claimed by some (other) package.
cat > "$d/bin/dpkg" <<EOS
#!/bin/sh
[ "\$1" = -S ] || exit 1
case "\$2" in
  */agentos-pkgowned.service) echo "somepkg: \$2"; exit 0 ;;
  *) exit 1 ;;
esac
EOS
# systemctl: logs; is-enabled reports agentos-remove.service as enabled, everything else disabled.
cat > "$d/bin/systemctl" <<EOS
#!/bin/sh
echo "systemctl \$*" >> "$L"
case "\$1" in
  is-enabled)
    case "\$2" in
      agentos-remove.service) echo enabled; exit 0 ;;
      *) echo disabled; exit 1 ;;
    esac ;;
esac
exit 0
EOS
chmod +x "$d/bin/"*

# A masked unit (a symlink, e.g. to /dev/null) is left alone, even though /usr/lib has a copy too.
ln -s /dev/null "$E/agentos-masked.service"
touch "$U/agentos-masked.service"

# A symlink to a regular file is left alone too: -f alone would follow it and treat it like a
# plain file, so this exercises the separate "[ ! -L "$f" ]" guard that the /dev/null mask case
# above doesn't (that target isn't a regular file either way).
touch "$U/agentos-linked.service"
ln -s "$U/agentos-linked.service" "$E/agentos-linked.service"

# A package-owned /etc copy is left alone, including its enablement symlink.
printf 'unit\n' > "$E/agentos-pkgowned.service"
printf 'unit\n' > "$U/agentos-pkgowned.service"
ln -s "$E/agentos-pkgowned.service" "$E/multi-user.target.wants/agentos-pkgowned.service"

# A stale, package-less /etc copy that the package now ships in /usr/lib: moved aside, along with
# only its own enablement symlink removed; it was enabled, so it is re-enabled (from the /usr/lib
# copy).
printf 'unit\n' > "$E/agentos-remove.service"
printf 'unit\n' > "$U/agentos-remove.service"
ln -s "$E/agentos-remove.service" "$E/multi-user.target.wants/agentos-remove.service"

run() { env PATH="$d/bin:$PATH" AGENTOS_ETC_UNITS="$E" AGENTOS_USR_UNITS="$U" bash "$M"; }
run

[ -L "$E/agentos-masked.service" ] || fail "the symlink mask was removed"
! grep -q agentos-masked "$L" || fail "the mask was touched: $(cat "$L")"

[ -L "$E/agentos-linked.service" ] || fail "the symlink to a regular file was removed"
! grep -q agentos-linked "$L" || fail "the symlink to a regular file was touched: $(cat "$L")"

[ -f "$E/agentos-pkgowned.service" ] && [ ! -L "$E/agentos-pkgowned.service" ] || fail "the package-owned file was removed"
[ -L "$E/multi-user.target.wants/agentos-pkgowned.service" ] || fail "the package-owned unit's enablement symlink was removed"
! grep -q agentos-pkgowned "$L" || fail "the package-owned unit was touched: $(cat "$L")"

[ ! -e "$E/agentos-remove.service" ] || fail "the stale unit file is still at its original name"
[ -f "$E/agentos-remove.service.pre-agentos" ] && [ ! -L "$E/agentos-remove.service.pre-agentos" ] || fail "the stale unit file was not moved aside"
[ "$(cat "$E/agentos-remove.service.pre-agentos")" = unit ] || fail "the moved-aside file lost its content"
[ ! -e "$E/multi-user.target.wants/agentos-remove.service" ] || fail "its enablement symlink was not removed"
grep -qx 'systemctl daemon-reload' "$L" || fail "no daemon-reload after moving a unit aside: $(cat "$L")"
grep -qx 'systemctl enable --quiet agentos-remove.service' "$L" || fail "the unit was not re-enabled from /usr/lib: $(cat "$L")"

# Safe to run again: the moved-aside file no longer matches the "agentos-*.service" glob (it ends
# in ".pre-agentos", not ".service"), so there's nothing left to migrate for it, no systemctl calls
# at all.
: > "$L"
run
[ ! -s "$L" ] || fail "re-run touched systemctl: $(cat "$L")"
echo "migration-001 OK"
