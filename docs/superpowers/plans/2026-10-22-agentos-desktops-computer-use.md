# AgentOS Desktops and Computer Use Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On-demand 1920×1080 XFCE desktops that agents drive through one MCP server, `agentos-computer` (stdio inside the box, bearer-protected HTTP on the tailnet). Humans can watch each desktop live via a per-desktop noVNC URL.

**Architecture:**
- **Desktops:** a systemd template unit `agentos-desktop@N.service` runs `Xvnc :N` plus an XFCE session as `agent`. systemd is the only registry of which desktops exist.
- **Control:** a Python MCP server (`mcp` SDK v1, FastMCP) shells out to `systemctl`, `xdotool` and `scrot`. Its pure logic (coordinate scaling, desktop bookkeeping, validation) lives in `core.py` with stdlib-only unit tests.
- **Viewing:** one websockify/noVNC service resolves per-desktop random tokens from `/run/agentos/vnc/`.
- **Registration:** the MCP server is registered in all four agent CLIs at first boot, so no CLI state lands in the image.

**Tech Stack:** mkosi 27, Debian trixie, TigerVNC, XFCE 4.20, xdotool, scrot, noVNC/websockify, Python 3.13 venv with `mcp` (v1) and Pillow, polkit, systemd.

**Builds on:** Plan 1, merged on `master` at 562e2c2. Read `.superpowers/sdd/context.md` for the build host workflow (devvm, `devvm.sh`, `TMPDIR=/var/tmp`, foreground polling).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-21-agentos-design.md` Section 2 (and 6 for security). When this plan and the spec disagree, the spec wins; stop and flag it.
- Desktop N: `Xvnc :N` at exactly 1920×1080, depth 24. VNC on `localhost:5900+N` only. N ∈ 1..`AGENTOS_MAX_DESKTOPS` (default 8, valid 1–16).
- systemd is the registry: no desktop state of our own beyond the per-desktop token file `/run/agentos/vnc/N`.
- Screenshots: PNG, scaled to `AGENTOS_SCREENSHOT_WIDTH` (default 1366 → 1366×768). Every tool coordinate is in that scaled space; the server maps to 1920×1080 and clamps to the screen.
- MCP server name `agentos-computer`, launcher `/usr/local/bin/agentos-computer`. stdio by default; `--http HOST:PORT` serves Streamable HTTP at path `/mcp`.
- HTTP requires `Authorization: Bearer <token>`, where the token is `/etc/agentos/mcp-token` (Plan 1, 64 hex chars, root 0600), passed via systemd `LoadCredential=`. Compare in constant time. Anything else gets 401.
- Tool names and parameters (spec): `create_desktop() -> {id, view_url}`, `list_desktops()`, `destroy_desktop(id)`, `screenshot(desktop)`, `click(desktop, x, y, button)`, `double_click`, `move`, `drag`, `type(desktop, text)`, `key(desktop, combo)`, `scroll`, `cursor_position(desktop)`.
- noVNC on `0.0.0.0:6080`. Per-desktop token: 128-bit random, hex. `view_url = http://<hostname>:6080/vnc.html?path=websockify%3Ftoken%3D<token>&autoconnect=1&resize=scale`.
- Reachability: only via `tailscale0` (Plan 1 nftables). Our network services `Requires=`/`After=agentos-firewall.service`.
- Services we ship run as `agent` with `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=read-only`.
- Python deps live only in `/usr/local/lib/agentos/venv`: `mcp>=1.28,<2`, `pillow>=10`. Versions are recorded in the image manifest.
- No CLI state in the image (Plan 1 finalize invariants stay green). CLI MCP registration happens at first boot.
- Root used space ≤ 7168 MiB (Plan 1 `check_root_size_budget`).
- Bash scripts: `#!/bin/bash` + `set -euo pipefail`, `shellcheck -S warning` clean. Checks in `test/checks/*.sh` must use `&&` chains (don't rely on `set -e` inside check functions).

## File map

```
mkosi.conf.d/30-desktop.conf                          # desktop + viewer packages
mkosi.prepare.chroot                                  # + XFCE defaults for agent, + Python venv
mkosi.finalize.chroot                                 # + venv versions in manifest
mkosi.extra/usr/local/lib/agentos/desktop-session     # Xvnc :N + XFCE for one desktop
mkosi.extra/usr/local/lib/agentos/vnc-token           # add|del websockify token for desktop N
mkosi.extra/usr/local/lib/agentos/register-mcp        # registers agentos-computer in 4 CLIs (runs as agent)
mkosi.extra/usr/local/lib/agentos/computer/core.py    # pure logic
mkosi.extra/usr/local/lib/agentos/computer/server.py  # MCP server
mkosi.extra/usr/local/bin/agentos-computer            # launcher
mkosi.extra/etc/systemd/system/agentos-desktop@.service
mkosi.extra/etc/systemd/system/agentos-novnc.service
mkosi.extra/etc/systemd/system/agentos-mcp-http.service
mkosi.extra/etc/polkit-1/rules.d/50-agentos-desktop.rules
mkosi.extra/usr/lib/tmpfiles.d/agentos.conf
mkosi.extra/home/agent/.config/xfce4/terminal/terminalrc
mkosi.extra/usr/local/sbin/agentos-firstboot          # + desktop.conf publish, + register-mcp
mkosi.extra/usr/local/bin/agentos-config              # + "desktops" menu item
test/smoke.sh                                         # + host forwards for 6080 and 8765
test/computer_test.py                                 # core.py unit tests (stdlib, runs anywhere)
test/mcp_client.py                                    # end-to-end MCP client (runs inside the VM)
test/checks/90-desktop.sh, 91-desktop-lifecycle.sh, 92-computer.sh, 93-mcp-http.sh, 94-cli-mcp.sh
```

---

### Task 1: Desktop session (multi-session spike)

The spec flags a risk: several `startxfce4` sessions under one Unix user may conflict (xfconfd, panel). This task builds the desktop unit and proves two desktops run independently. **Decision gate:** if they don't, stop and report BLOCKED with evidence. The fallback (one Unix user per desktop) is a design change for the controller and user to decide.

**Files:**
- Create: `mkosi.conf.d/30-desktop.conf`, `mkosi.extra/usr/local/lib/agentos/desktop-session`, `mkosi.extra/etc/systemd/system/agentos-desktop@.service`, `mkosi.extra/home/agent/.config/xfce4/terminal/terminalrc`, `test/checks/90-desktop.sh`
- Modify: `mkosi.prepare.chroot` (append)

**Interfaces:**
- Produces: `agentos-desktop@N.service`. Starting it gives a running X display `:N` (1920×1080) with an XFCE panel and no first-run dialog. Stopping it removes the display. Task 2 adds `ExecStartPost`/`ExecStopPost` token lines to this unit.
- Produces: `/usr/local/lib/agentos/desktop-session N`.

- [ ] **Step 1: Write the failing checks**

`test/checks/90-desktop.sh`:
```bash
# shellcheck shell=bash
# Desktops are started with sudo here; Task 2 adds the polkit rule that lets agent do it directly.
wait_x() {  # wait_x <N>: wait up to 60 s for display :N to answer
  vm "for i in \$(seq 1 60); do DISPLAY=:$1 xdotool getdisplaygeometry 2>/dev/null | grep -qx '1920 1080' && exit 0; sleep 1; done; exit 1"
}
check_desktop_packages() { vm 'command -v Xvnc startxfce4 xdotool scrot xclip chromium >/dev/null'; }
check_two_desktops_independent() {
  vm 'sudo systemctl start agentos-desktop@1.service agentos-desktop@2.service' &&
  wait_x 1 && wait_x 2 && vm 'sleep 10' &&
  vm 'for n in 1 2; do DISPLAY=:$n xdotool search --class xfce4-panel | grep -q . || { echo "no panel on :$n"; exit 1; }; done' &&
  vm 'test "$(pgrep -u agent -c -x xfconfd)" -ge 2 || { echo "expected one xfconfd per desktop, got $(pgrep -u agent -c -x xfconfd)"; exit 1; }' &&
  vm 'for n in 1 2; do ! DISPLAY=:$n xdotool search --onlyvisible --name "^Panel$" | grep -q . || { echo "first-run panel dialog on :$n"; exit 1; }; done' &&
  vm 'sudo systemctl stop agentos-desktop@1.service && sleep 2 &&
      ! DISPLAY=:1 xdotool getdisplaygeometry 2>/dev/null &&
      DISPLAY=:2 xdotool search --class xfce4-panel | grep -q . || { echo "stopping :1 affected :2"; exit 1; }' &&
  vm 'sudo systemctl stop agentos-desktop@2.service && sleep 1 && ! pgrep -u agent -x Xvnc'
}
check_desktop_restart_after_crash() {
  vm 'sudo systemctl start agentos-desktop@3.service' && wait_x 3 &&
  vm 'pkill -KILL -u agent -f "Xvnc :3" ; sleep 2; sudo systemctl stop agentos-desktop@3.service 2>/dev/null; sudo systemctl reset-failed agentos-desktop@3.service 2>/dev/null; sudo systemctl start agentos-desktop@3.service' &&
  wait_x 3 && vm 'sudo systemctl stop agentos-desktop@3.service'
}
check_terminal_login_shell() { vm 'grep -qx "CommandLoginShell=TRUE" ~/.config/xfce4/terminal/terminalrc'; }
```

- [ ] **Step 2: Run to confirm failure**

```bash
.superpowers/sdd/devvm.sh run 'TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi'
.superpowers/sdd/devvm.sh wait <JOB>   # repeat until exit code != 124
```
Expected: `check_desktop_packages`, `check_two_desktops_independent`, `check_desktop_restart_after_crash` and `check_terminal_login_shell` FAIL. All Plan 1 checks still PASS.

- [ ] **Step 3: Packages**

`mkosi.conf.d/30-desktop.conf`:
```ini
[Content]
Packages=
        tigervnc-standalone-server
        xfce4-session
        xfwm4
        xfce4-panel
        xfdesktop4
        xfce4-settings
        xfce4-terminal
        xfconf
        dbus-x11
        adwaita-icon-theme
        xdotool
        scrot
        xclip
        chromium
        fonts-dejavu
        fonts-noto-color-emoji
        novnc
        websockify
        polkitd
```
`polkitd` and the noVNC packages are used from Task 2 on. They're installed here so that Task 1's image is the final package set.

- [ ] **Step 4: Desktop session script and unit**

`mkosi.extra/usr/local/lib/agentos/desktop-session`:
```bash
#!/bin/bash
# Run one AgentOS desktop: Xvnc :N (1920x1080, localhost-only VNC on 5900+N) plus an XFCE session.
# Started by agentos-desktop@N.service as agent. Exits when either Xvnc or the session exits.
set -euo pipefail
n=${1:?usage: desktop-session N}
[[ $n =~ ^[0-9]+$ ]] || { echo "invalid desktop number: $n" >&2; exit 2; }

rm -f "/tmp/.X$n-lock" "/tmp/.X11-unix/X$n"   # stale after a crash; owned by agent
Xvnc ":$n" -geometry 1920x1080 -depth 24 -localhost -rfbport $((5900 + n)) \
  -SecurityTypes None -AlwaysShared -nolisten tcp &
for _ in $(seq 1 100); do [ -S "/tmp/.X11-unix/X$n" ] && break; sleep 0.1; done
[ -S "/tmp/.X11-unix/X$n" ] || { echo "Xvnc :$n did not start" >&2; exit 1; }

export DISPLAY=":$n"
dbus-run-session -- startxfce4 &
wait -n
```

`mkosi.extra/etc/systemd/system/agentos-desktop@.service`:
```ini
[Unit]
Description=AgentOS desktop %i (Xvnc :%i + XFCE)
After=network.target

[Service]
Type=simple
User=agent
WorkingDirectory=/home/agent
ExecStart=/usr/local/lib/agentos/desktop-session %i
KillMode=control-group
Restart=no
```
No `[Install]`: desktops start only on demand. The preset glob `agentos-*.service` is harmless for templates without an install section.

- [ ] **Step 5: XFCE defaults for agent**

Append to `mkosi.prepare.chroot`:
```bash
# XFCE: ship the default panel config so the first start shows no "Panel: use default config?" dialog.
install -d -o agent -g agent /home/agent/.config/xfce4/xfconf/xfce-perchannel-xml
install -o agent -g agent -m 644 /etc/xdg/xfce4/panel/default.xml \
  /home/agent/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
```
If `/etc/xdg/xfce4/panel/default.xml` doesn't exist in trixie's xfce4-panel, find the shipped default (`dpkg -L xfce4-panel | grep -i default`) and report the path you used.

`mkosi.extra/home/agent/.config/xfce4/terminal/terminalrc` (login shell, so `/etc/profile.d/agentos.sh` loads PATH and API keys for agents started in a desktop terminal):
```ini
[Configuration]
CommandLoginShell=TRUE
```
mkosi copies `mkosi.extra/` as root after the prepare script has run, so fix ownership in `mkosi.finalize.chroot`. Add this right after the `chmod 0440 /etc/sudoers.d/agent` line:
```bash
chown -R agent:agent /home/agent/.config/xfce4
```

- [ ] **Step 6: Build and test**

```bash
chmod +x mkosi.extra/usr/local/lib/agentos/desktop-session
.superpowers/sdd/devvm.sh run 'shellcheck -S warning mkosi.extra/usr/local/lib/agentos/desktop-session mkosi.prepare.chroot mkosi.finalize.chroot && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `ALL CHECKS PASSED` in both modes, including `check_root_size_budget` (record the `root used:` value).

**If `check_two_desktops_independent` fails** because the sessions interfere (shared xfconfd, panel only on one display, stopping one kills the other): stop. Report BLOCKED with the failing output, `pgrep -a -u agent` from inside the VM, and the session journal (`journalctl -u agentos-desktop@1 -u agentos-desktop@2`). Don't implement the per-user fallback.

If Xvnc rejects an option (e.g. `-localhost` or `-SecurityTypes None` in this TigerVNC version), use the closest equivalent (`-interface 127.0.0.1`, `-SecurityTypes None` with `-I-KNOW-THIS-IS-INSECURE` if TigerVNC demands it), and report the exact error.

- [ ] **Step 7: Commit**

```bash
git add mkosi.conf.d/30-desktop.conf mkosi.extra/usr/local/lib/agentos/desktop-session \
  mkosi.extra/etc/systemd/system/agentos-desktop@.service mkosi.extra/home/agent \
  mkosi.prepare.chroot mkosi.finalize.chroot test/checks/90-desktop.sh
git commit -m "feat: on-demand Xvnc + XFCE desktop unit; two concurrent sessions proven independent"
```

---

### Task 2: Desktop lifecycle, live viewing and settings

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/vnc-token`, `mkosi.extra/usr/lib/tmpfiles.d/agentos.conf`, `mkosi.extra/etc/polkit-1/rules.d/50-agentos-desktop.rules`, `mkosi.extra/etc/systemd/system/agentos-novnc.service`, `test/checks/91-desktop-lifecycle.sh`
- Modify: `mkosi.extra/etc/systemd/system/agentos-desktop@.service`, `mkosi.extra/usr/local/sbin/agentos-firstboot`, `mkosi.extra/usr/local/bin/agentos-config`, `test/smoke.sh`

**Interfaces:**
- Consumes: `agentos-desktop@N.service` (Task 1); `env_get`, `AGENTOS_ENV` (Plan 1 `env.sh`).
- Produces: the `agent` user can run `systemctl start|stop|restart agentos-desktop@N.service` without sudo (polkit). Nothing else.
- Produces: `/run/agentos/vnc/N` while desktop N runs. One line, `<32 hex chars>: localhost:<5900+N>`, mode 0640 root:agent.
- Produces: `/etc/agentos/desktop.conf` (0644), written by firstboot:
  ```
  MAX_DESKTOPS=<1..16, default 8>
  SCREENSHOT_WIDTH=<640..1920, default 1366>
  ```
- Produces: `agentos-novnc.service` on `0.0.0.0:6080`.
- Produces in `test/smoke.sh`: `$HOSTPORT_NOVNC` and `$HOSTPORT_MCP`, host ports forwarded to guest 6080 and 8765.

- [ ] **Step 1: Forward the new ports in the smoke harness**

In `test/smoke.sh`, function `boot()`, change:
```bash
  PORT=$2; HOSTPORT_HTTP=$(( $2 + 1 ))
  export PORT HOSTPORT_HTTP MODE=$mode
```
to:
```bash
  PORT=$2; HOSTPORT_HTTP=$(( $2 + 1 )); HOSTPORT_NOVNC=$(( $2 + 2 )); HOSTPORT_MCP=$(( $2 + 3 ))
  export PORT HOSTPORT_HTTP HOSTPORT_NOVNC HOSTPORT_MCP MODE=$mode
```
and the `-nic` line to:
```bash
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22,hostfwd=tcp:127.0.0.1:$HOSTPORT_HTTP-:8080,hostfwd=tcp:127.0.0.1:$HOSTPORT_NOVNC-:6080,hostfwd=tcp:127.0.0.1:$HOSTPORT_MCP-:8765" \
```

- [ ] **Step 2: Write the failing checks**

`test/checks/91-desktop-lifecycle.sh`:
```bash
# shellcheck shell=bash
check_agent_manages_desktop_without_sudo() {
  vm 'systemctl --no-ask-password start agentos-desktop@5.service &&
      systemctl is-active agentos-desktop@5.service &&
      systemctl --no-ask-password stop agentos-desktop@5.service'
}
check_agent_cannot_manage_other_units() {
  vm '! systemctl --no-ask-password start systemd-tmpfiles-clean.service 2>/dev/null'
}
check_vnc_token_lifecycle() {
  vm 'systemctl --no-ask-password start agentos-desktop@6.service && sleep 2 &&
      grep -qE "^[0-9a-f]{32}: localhost:5906$" /run/agentos/vnc/6 &&
      test "$(stat -c "%a %U %G" /run/agentos/vnc/6)" = "640 root agent" &&
      systemctl --no-ask-password stop agentos-desktop@6.service && sleep 1 &&
      test ! -e /run/agentos/vnc/6'
}
check_vnc_tokens_differ() {
  vm 'systemctl --no-ask-password start agentos-desktop@6.service agentos-desktop@7.service && sleep 2 &&
      a=$(cut -d: -f1 /run/agentos/vnc/6) && b=$(cut -d: -f1 /run/agentos/vnc/7) && test "$a" != "$b";
      rc=$?; systemctl --no-ask-password stop agentos-desktop@6.service agentos-desktop@7.service; exit $rc'
}
check_novnc_serves_locally() {
  vm 'systemctl is-active agentos-novnc.service && curl -sf -m 5 http://127.0.0.1:6080/vnc.html | grep -qi novnc'
}
check_novnc_not_reachable_from_lan() {
  vm 'curl -sf -m 5 "http://$(hostname -I | awk "{print \$1}"):6080/vnc.html" >/dev/null' &&
  ! curl -s -m 5 "http://127.0.0.1:$HOSTPORT_NOVNC/vnc.html" >/dev/null
}
check_novnc_unit_hardened() {
  vm 'systemctl show agentos-novnc.service -p User -p NoNewPrivileges -p ProtectSystem -p Requires |
      sort | tr "\n" " " | grep -q "NoNewPrivileges=yes ProtectSystem=strict Requires=agentos-firewall.service.*User=agent"'
}
check_desktop_conf_published() {
  vm 'grep -qx "MAX_DESKTOPS=8" /etc/agentos/desktop.conf && grep -qx "SCREENSHOT_WIDTH=1366" /etc/agentos/desktop.conf &&
      test "$(stat -c %a /etc/agentos/desktop.conf)" = 644'
}
check_desktop_conf_follows_config() {
  vm 'sudo agentos-config set AGENTOS_MAX_DESKTOPS 3 && sudo agentos-config set AGENTOS_SCREENSHOT_WIDTH 99999 &&
      sudo agentos-config apply && grep -qx MAX_DESKTOPS=3 /etc/agentos/desktop.conf &&
      grep -qx SCREENSHOT_WIDTH=1366 /etc/agentos/desktop.conf;
      rc=$?; sudo agentos-config set AGENTOS_MAX_DESKTOPS 8; sudo agentos-config set AGENTOS_SCREENSHOT_WIDTH 1366;
      sudo agentos-config apply; exit $rc'
}
```

Run the uefi smoke test (as in Task 1 Step 2). Expected: all of these FAIL. Note that `check_novnc_not_reachable_from_lan` fails on its first, guest-side line, which proves the negative assertion isn't vacuous.

- [ ] **Step 3: Token script, tmpfiles and unit hooks**

`mkosi.extra/usr/local/lib/agentos/vnc-token`:
```bash
#!/bin/bash
# vnc-token add|del N: manage the websockify token file for desktop N (runs as root from the unit).
set -euo pipefail
op=${1:?usage: vnc-token add|del N}; n=${2:?usage: vnc-token add|del N}
[[ $n =~ ^[0-9]+$ ]] || { echo "invalid desktop number: $n" >&2; exit 2; }
f=/run/agentos/vnc/$n
case $op in
  add) t=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
       install -m 640 -o root -g agent /dev/null "$f"
       printf '%s: localhost:%d\n' "$t" $((5900 + n)) > "$f" ;;
  del) rm -f "$f" ;;
  *)   echo "usage: vnc-token add|del N" >&2; exit 2 ;;
esac
```

`mkosi.extra/usr/lib/tmpfiles.d/agentos.conf`:
```
d /run/agentos      0755 root root  -
d /run/agentos/vnc  0750 root agent -
```

In `mkosi.extra/etc/systemd/system/agentos-desktop@.service`, add under `[Service]` (the `+` prefix runs them as root):
```ini
ExecStartPost=+/usr/local/lib/agentos/vnc-token add %i
ExecStopPost=+/usr/local/lib/agentos/vnc-token del %i
```

- [ ] **Step 4: Polkit rule**

`mkosi.extra/etc/polkit-1/rules.d/50-agentos-desktop.rules`:
```javascript
// agent may start/stop/restart AgentOS desktops, nothing else, without a password.
polkit.addRule(function (action, subject) {
  if (action.id === "org.freedesktop.systemd1.manage-units" && subject.user === "agent") {
    var unit = action.lookup("unit");
    var verb = action.lookup("verb");
    if (unit && /^agentos-desktop@[0-9]+\.service$/.test(unit) &&
        (verb === "start" || verb === "stop" || verb === "restart")) {
      return polkit.Result.YES;
    }
  }
});
```

- [ ] **Step 5: noVNC service**

`mkosi.extra/etc/systemd/system/agentos-novnc.service`:
```ini
[Unit]
Description=AgentOS live desktop viewer (noVNC, tailnet only)
Requires=agentos-firewall.service
After=agentos-firewall.service network.target

[Service]
User=agent
ExecStart=/usr/bin/websockify --web /usr/share/novnc --token-plugin TokenFile --token-source /run/agentos/vnc 0.0.0.0:6080
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```
If `websockify` lives elsewhere, or the TokenFile plugin needs a different class name in trixie's websockify (`websockify.token_plugins.TokenFile`), adjust and report.

- [ ] **Step 6: Publish desktop settings in firstboot**

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, insert after the `printf 'AGENTOS_CONSOLE=…' > /etc/agentos/console.mode` block (before `chmod 711 /etc/agentos`):
```bash
# Desktop settings for agentos-computer (runs as agent; agentos.env is root-only). Invalid -> default.
md=$(env_get "$AGENTOS_ENV" AGENTOS_MAX_DESKTOPS | grep -xE '[1-9]|1[0-6]' || echo 8)
sw=$(env_get "$AGENTOS_ENV" AGENTOS_SCREENSHOT_WIDTH | grep -xE '6[4-9][0-9]|[7-9][0-9]{2}|1[0-8][0-9]{2}|19[01][0-9]|1920' || echo 1366)
printf 'MAX_DESKTOPS=%s\nSCREENSHOT_WIDTH=%s\n' "$md" "$sw" > /etc/agentos/desktop.conf
chmod 644 /etc/agentos/desktop.conf
```

- [ ] **Step 7: Settings menu item**

In `mkosi.extra/usr/local/bin/agentos-config`, inside `menu()`, add a menu entry after `console    "Local console: headless or terminal" \`:
```bash
      desktops  "Desktops: max count and screenshot width" \
```
and a case branch next to `console)`:
```bash
      desktops)  m=$(whiptail --inputbox "Max concurrent desktops (1-16)" 10 60 "$(cmd_get AGENTOS_MAX_DESKTOPS || true)" 3>&1 1>&2 2>&3) && [ -n "$m" ] && cmd_set AGENTOS_MAX_DESKTOPS "$m" || true
                 w=$(whiptail --inputbox "Screenshot width in px (640-1920, default 1366)" 10 60 "$(cmd_get AGENTOS_SCREENSHOT_WIDTH || true)" 3>&1 1>&2 2>&3) && [ -n "$w" ] && cmd_set AGENTOS_SCREENSHOT_WIDTH "$w" || true ;;
```
Invalid values are tolerated here, because firstboot falls back to the defaults (tested by `check_desktop_conf_follows_config`).

- [ ] **Step 8: Build and test**

```bash
chmod +x mkosi.extra/usr/local/lib/agentos/vnc-token
.superpowers/sdd/devvm.sh run 'shellcheck -S warning test/smoke.sh mkosi.extra/usr/local/lib/agentos/vnc-token mkosi.extra/usr/local/sbin/agentos-firstboot mkosi.extra/usr/local/bin/agentos-config && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `ALL CHECKS PASSED`. Task 1's checks still use `sudo` and still pass.

- [ ] **Step 9: Commit**

```bash
git add test/smoke.sh test/checks/91-desktop-lifecycle.sh mkosi.extra
git commit -m "feat: polkit-scoped desktop lifecycle, per-desktop noVNC tokens, desktop settings"
```

---

### Task 3: `core.py`, the pure logic, with unit tests

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/computer/core.py`, `test/computer_test.py`

**Interfaces:**
- Produces `core.py` (stdlib only, no I/O):
  - `SCREEN_W = 1920`, `SCREEN_H = 1080`
  - `scaled_size(target_w: int) -> tuple[int, int]` returns `(target_w, round(1080 * target_w / 1920))`
  - `to_screen(x: int, y: int, target_w: int) -> tuple[int, int]` maps scaled to screen pixels and clamps to `0..1919`, `0..1079`
  - `to_scaled(sx: int, sy: int, target_w: int) -> tuple[int, int]`
  - `active_desktops(systemctl_output: str) -> list[int]`, sorted and unique
  - `lowest_free(active: list[int], max_n: int) -> int | None`
  - `view_url(host: str, token: str) -> str`
  - `parse_token_file(text: str) -> str`
  - `parse_conf(text: str, defaults: dict[str, str]) -> dict[str, str]`: only keys present in `defaults`
  - `valid_key_combo(combo: str) -> bool`
  - `BUTTONS = {"left": "1", "middle": "2", "right": "3"}`
  - `SCROLL = {"up": "4", "down": "5", "left": "6", "right": "7"}`

- [ ] **Step 1: Write the failing test**

`test/computer_test.py`:
```python
#!/usr/bin/env python3
"""Unit tests for agentos-computer core logic. Stdlib only: python3 test/computer_test.py"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mkosi.extra", "usr", "local", "lib", "agentos", "computer"))
import core  # noqa: E402

# scaling: 1366 wide keeps 16:9
assert core.scaled_size(1366) == (1366, 768)
assert core.scaled_size(1920) == (1920, 1080)
assert core.to_screen(683, 384, 1366) == (960, 540)
assert core.to_screen(0, 0, 1366) == (0, 0)
assert core.to_screen(1366, 768, 1366) == (1919, 1079)          # clamped to last pixel
assert core.to_screen(-5, 99999, 1366) == (0, 1079)
assert core.to_screen(960, 540, 1920) == (960, 540)             # identity at full width
assert core.to_scaled(960, 540, 1366) == (683, 384)
for x, y in [(0, 0), (100, 50), (683, 384), (1365, 767)]:        # round trip within 1 px
    sx, sy = core.to_screen(x, y, 1366)
    bx, by = core.to_scaled(sx, sy, 1366)
    assert abs(bx - x) <= 1 and abs(by - y) <= 1, (x, y, bx, by)

# systemd bookkeeping
out = ("agentos-desktop@3.service loaded active running AgentOS desktop 3\n"
       "agentos-desktop@1.service loaded active running AgentOS desktop 1\n")
assert core.active_desktops(out) == [1, 3]
assert core.active_desktops("") == []
assert core.lowest_free([1, 3], 8) == 2
assert core.lowest_free([], 8) == 1
assert core.lowest_free([1, 2], 2) is None

# viewer + config
url = core.view_url("agentos-01", "abc123")
assert url == "http://agentos-01:6080/vnc.html?path=websockify%3Ftoken%3Dabc123&autoconnect=1&resize=scale", url
assert core.parse_token_file("abc123: localhost:5901\n") == "abc123"
defaults = {"MAX_DESKTOPS": "8", "SCREENSHOT_WIDTH": "1366"}
assert core.parse_conf("MAX_DESKTOPS=4\n# comment\ngarbage\nOTHER=1\n", defaults) == {"MAX_DESKTOPS": "4", "SCREENSHOT_WIDTH": "1366"}
assert core.parse_conf("", defaults) == defaults

# key combos passed to xdotool key
for ok in ["Return", "ctrl+alt+t", "ctrl+shift+Tab", "F5", "super", "KP_Enter"]:
    assert core.valid_key_combo(ok), ok
for bad in ["", "ctrl++", "+a", "a;rm -rf", "ctrl alt", "--help", "a\nb"]:
    assert not core.valid_key_combo(bad), bad

assert core.BUTTONS == {"left": "1", "middle": "2", "right": "3"}
assert core.SCROLL == {"up": "4", "down": "5", "left": "6", "right": "7"}
print("core OK")
```

- [ ] **Step 2: Run to confirm failure**

Run: `python3 test/computer_test.py`
Expected: `ModuleNotFoundError: No module named 'core'`

- [ ] **Step 3: Implement**

`mkosi.extra/usr/local/lib/agentos/computer/core.py`:
```python
"""Pure logic for agentos-computer: coordinate scaling, desktop bookkeeping, validation. No I/O."""
import re

SCREEN_W, SCREEN_H = 1920, 1080
BUTTONS = {"left": "1", "middle": "2", "right": "3"}
SCROLL = {"up": "4", "down": "5", "left": "6", "right": "7"}

_UNIT_RE = re.compile(r"^agentos-desktop@(\d+)\.service\b", re.M)
_KEY_RE = re.compile(r"^[A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*$")


def scaled_size(target_w):
    return target_w, round(SCREEN_H * target_w / SCREEN_W)


def to_screen(x, y, target_w):
    f = SCREEN_W / target_w
    return (min(max(round(x * f), 0), SCREEN_W - 1),
            min(max(round(y * f), 0), SCREEN_H - 1))


def to_scaled(sx, sy, target_w):
    f = target_w / SCREEN_W
    return round(sx * f), round(sy * f)


def active_desktops(systemctl_output):
    return sorted({int(n) for n in _UNIT_RE.findall(systemctl_output)})


def lowest_free(active, max_n):
    return next((n for n in range(1, max_n + 1) if n not in active), None)


def view_url(host, token):
    return f"http://{host}:6080/vnc.html?path=websockify%3Ftoken%3D{token}&autoconnect=1&resize=scale"


def parse_token_file(text):
    return text.split(":", 1)[0].strip()


def parse_conf(text, defaults):
    conf = dict(defaults)
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key in defaults:
            conf[key] = value.strip()
    return conf


def valid_key_combo(combo):
    return bool(_KEY_RE.match(combo)) and "\n" not in combo
```

- [ ] **Step 4: Run to confirm it passes**

Run: `python3 test/computer_test.py`
Expected: `core OK`

- [ ] **Step 5: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/computer/core.py test/computer_test.py
git commit -m "feat: agentos-computer core logic (scaling, desktop bookkeeping, validation) with tests"
```

---

### Task 4: MCP server over stdio

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/computer/server.py`, `mkosi.extra/usr/local/bin/agentos-computer`, `test/mcp_client.py`, `test/checks/92-computer.sh`
- Modify: `mkosi.prepare.chroot` (append), `mkosi.finalize.chroot` (manifest), `.github/workflows/build.yml` (run `test/computer_test.py` in lint)

**Interfaces:**
- Consumes: `core` (Task 3); `agentos-desktop@N.service`, polkit rule, `/run/agentos/vnc/N`, `/etc/agentos/desktop.conf` (Tasks 1–2).
- Produces: `/usr/local/bin/agentos-computer`, which serves the spec's 12 tools over stdio. `--http HOST:PORT` is accepted but Task 5 implements it (until then it exits with status 2 and the message `--http not implemented yet`).
- Produces: `test/mcp_client.py stdio` and `test/mcp_client.py http <url> <token>`. Both run the same end-to-end scenario and print `MCP CLIENT OK`.
- Produces: the manifest section `# agentos-computer python` with `pip freeze` lines.

- [ ] **Step 1: Write the end-to-end client (the failing test)**

`test/mcp_client.py`:
```python
#!/usr/bin/env python3
"""End-to-end test for agentos-computer, run inside an AgentOS VM with the agentos venv python.

  mcp_client.py stdio                  spawn /usr/local/bin/agentos-computer
  mcp_client.py http <url> <token>     connect to the Streamable HTTP endpoint
"""
import asyncio
import base64
import io
import json
import os
import subprocess
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.streamable_http import streamablehttp_client
from PIL import Image

EXPECTED_TOOLS = {"create_desktop", "list_desktops", "destroy_desktop", "screenshot", "click",
                  "double_click", "move", "drag", "type", "key", "scroll", "cursor_position"}


def fail(msg):
    sys.exit(f"MCP CLIENT FAIL: {msg}")


async def call(s, name, **args):
    r = await s.call_tool(name, args)
    if r.isError:
        fail(f"{name}({args}) returned error: {r.content}")
    return r


def data(r):
    return json.loads(r.content[0].text)


async def scenario(s):
    await s.initialize()
    tools = {t.name for t in (await s.list_tools()).tools}
    if tools != EXPECTED_TOOLS:
        fail(f"tool set mismatch: {sorted(tools ^ EXPECTED_TOOLS)}")

    d = data(await call(s, "create_desktop"))
    n = d["id"]
    if "token%3D" not in d["view_url"]:
        fail(f"bad view_url {d['view_url']}")

    # screenshot: PNG at 1366x768 that eventually shows more than one colour (XFCE drew something)
    for _ in range(30):
        r = await call(s, "screenshot", desktop=n)
        img = r.content[0]
        if img.type != "image" or img.mimeType != "image/png":
            fail(f"screenshot content is {img.type} {getattr(img, 'mimeType', '')}")
        im = Image.open(io.BytesIO(base64.b64decode(img.data)))
        if im.size != (1366, 768):
            fail(f"screenshot size {im.size}")
        if len(im.convert("RGB").getcolors(maxcolors=4) or [None] * 5) > 1:
            break
        await asyncio.sleep(1)
    else:
        fail("screenshot stayed a single colour for 30 s")

    # move in scaled space -> real pointer at the 1920x1080 position, and back
    await call(s, "move", desktop=n, x=683, y=384)
    pos = data(await call(s, "cursor_position", desktop=n))
    if abs(pos["x"] - 683) > 1 or abs(pos["y"] - 384) > 1:
        fail(f"cursor_position {pos}")
    real = subprocess.run(["xdotool", "getmouselocation", "--shell"], env={**os.environ, "DISPLAY": f":{n}"},
                          capture_output=True, text=True, check=True).stdout
    rx = int(real.split("X=")[1].split()[0]); ry = int(real.split("Y=")[1].split()[0])
    if abs(rx - 960) > 2 or abs(ry - 540) > 2:
        fail(f"real pointer at {rx},{ry}, expected ~960,540")

    # input tools run without error
    await call(s, "click", desktop=n, x=683, y=384, button="left")
    await call(s, "double_click", desktop=n, x=683, y=384)
    await call(s, "drag", desktop=n, x1=100, y1=100, x2=200, y2=200)
    await call(s, "scroll", desktop=n, x=683, y=384, direction="down", amount=2)
    await call(s, "key", desktop=n, combo="Escape")
    await call(s, "type", desktop=n, text="hello agentos")

    # invalid input is a tool error, not a crash
    for name, args in [("key", {"desktop": n, "combo": "a;rm -rf /"}),
                       ("click", {"desktop": n, "x": 1, "y": 1, "button": "nope"}),
                       ("screenshot", {"desktop": 99})]:
        r = await s.call_tool(name, args)
        if not r.isError:
            fail(f"{name}({args}) should have been rejected")

    # second desktop gets a different id; both listed; destroy both
    n2 = data(await call(s, "create_desktop"))["id"]
    ids = {d["id"] for d in data(await call(s, "list_desktops"))}
    if n2 == n or not {n, n2} <= ids:
        fail(f"ids {n}, {n2}, listed {ids}")
    for i in (n, n2):
        await call(s, "destroy_desktop", id=i)
    if data(await call(s, "list_desktops")):
        fail("desktops left after destroy")
    print("MCP CLIENT OK")


async def main():
    if sys.argv[1:2] == ["stdio"]:
        async with stdio_client(StdioServerParameters(command="/usr/local/bin/agentos-computer")) as (r, w):
            async with ClientSession(r, w) as s:
                await scenario(s)
    elif sys.argv[1:2] == ["http"] and len(sys.argv) == 4:
        headers = {"Authorization": f"Bearer {sys.argv[3]}"}
        async with streamablehttp_client(sys.argv[2], headers=headers) as (r, w, _):
            async with ClientSession(r, w) as s:
                await scenario(s)
    else:
        sys.exit(__doc__)


asyncio.run(main())
```

`test/checks/92-computer.sh`:
```bash
# shellcheck shell=bash
check_computer_venv() { vm '/usr/local/lib/agentos/venv/bin/python -c "import mcp, PIL"'; }
check_manifest_lists_python() {
  vm 'grep -q "^# agentos-computer python" /var/lib/agentos-manifest.txt && grep -qi "^mcp==1\." /var/lib/agentos-manifest.txt'
}
check_mcp_stdio_end_to_end() {
  vm 'cat > /tmp/mcp_client.py' < "$HERE/mcp_client.py" &&
  vm '/usr/local/lib/agentos/venv/bin/python /tmp/mcp_client.py stdio'
}
```

Run the uefi smoke test. Expected: the three new checks FAIL (no venv, no server).

- [ ] **Step 2: Venv in the image, versions in the manifest**

Append to `mkosi.prepare.chroot`:
```bash
# agentos-computer MCP server deps, isolated from the system and the agent's own Python.
python3 -m venv /usr/local/lib/agentos/venv
/usr/local/lib/agentos/venv/bin/pip install --no-cache-dir --disable-pip-version-check 'mcp>=1.28,<2' 'pillow>=10'
```

In `mkosi.finalize.chroot`, right after the `} >> /var/lib/agentos-manifest.txt` that closes the agent CLI section, add:
```bash
{ echo "# agentos-computer python"; /usr/local/lib/agentos/venv/bin/pip freeze --disable-pip-version-check; } >> /var/lib/agentos-manifest.txt
```

- [ ] **Step 3: Launcher**

`mkosi.extra/usr/local/bin/agentos-computer`:
```bash
#!/bin/bash
# AgentOS computer-use MCP server. stdio by default; --http HOST:PORT for the tailnet service.
set -euo pipefail
exec /usr/local/lib/agentos/venv/bin/python /usr/local/lib/agentos/computer/server.py "$@"
```

- [ ] **Step 4: Server**

`mkosi.extra/usr/local/lib/agentos/computer/server.py`:
```python
"""agentos-computer: MCP server driving AgentOS virtual desktops.

stdio by default (spawned by agent CLIs inside the box); --http HOST:PORT for the tailnet service.
Screenshots are scaled to SCREENSHOT_WIDTH; every coordinate a tool takes or returns is in that space.
"""
import fcntl
import io
import os
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402

from mcp.server.fastmcp import FastMCP, Image  # noqa: E402
from PIL import Image as PILImage  # noqa: E402

CONF = "/etc/agentos/desktop.conf"
TOKENS = "/run/agentos/vnc"
LOCK = "/tmp/agentos-desktop.lock"

mcp = FastMCP("agentos-computer", host="0.0.0.0")


def conf():
    try:
        text = open(CONF).read()
    except FileNotFoundError:
        text = ""
    c = core.parse_conf(text, {"MAX_DESKTOPS": "8", "SCREENSHOT_WIDTH": "1366"})
    return int(c["MAX_DESKTOPS"]), int(c["SCREENSHOT_WIDTH"])


def run(*args, display=None):
    env = dict(os.environ)
    if display is not None:
        env["DISPLAY"] = f":{display}"
    r = subprocess.run(args, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{args[0]} failed: {r.stderr.strip() or r.returncode}")
    return r.stdout


def active():
    return core.active_desktops(run("systemctl", "list-units", "agentos-desktop@*", "--state=active",
                                    "--plain", "--no-legend"))


def need(desktop):
    if desktop not in active():
        raise ValueError(f"desktop {desktop} is not running; call create_desktop first")


def info(n):
    for _ in range(50):
        try:
            token = core.parse_token_file(open(f"{TOKENS}/{n}").read())
            return {"id": n, "view_url": core.view_url(socket.gethostname(), token)}
        except FileNotFoundError:
            time.sleep(0.1)
    raise RuntimeError(f"no viewer token for desktop {n}")


def pt(x, y):
    return [str(v) for v in core.to_screen(x, y, conf()[1])]


def _button(name):  # underscore: click() has a parameter called `button`
    if name not in core.BUTTONS:
        raise ValueError(f"button must be one of {sorted(core.BUTTONS)}")
    return core.BUTTONS[name]


@mcp.tool()
def create_desktop() -> dict:
    """Start a new 1920x1080 XFCE desktop. Returns its id and a live view URL for humans."""
    max_n, _ = conf()
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # ponytail: one host-wide lock; two agents can't grab the same N
        n = core.lowest_free(active(), max_n)
        if n is None:
            raise ValueError(f"all {max_n} desktops are in use; destroy one first")
        run("systemctl", "--no-ask-password", "start", f"agentos-desktop@{n}.service")
    for _ in range(150):
        try:
            run("xdotool", "getdisplaygeometry", display=n)
            break
        except RuntimeError:
            time.sleep(0.2)
    else:
        raise RuntimeError(f"desktop {n} did not come up")
    return info(n)


@mcp.tool()
def list_desktops() -> list[dict]:
    """List running desktops with their live view URLs."""
    return [info(n) for n in active()]


@mcp.tool()
def destroy_desktop(id: int) -> str:
    """Stop a desktop and everything running on it."""
    need(id)
    run("systemctl", "--no-ask-password", "stop", f"agentos-desktop@{id}.service")
    return "ok"


@mcp.tool()
def screenshot(desktop: int) -> Image:
    """PNG of the desktop scaled to the screenshot width (default 1366x768). Use its pixel coordinates for all input tools."""
    need(desktop)
    _, w = conf()
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "s.png")
        run("scrot", "--overwrite", path, display=desktop)
        im = PILImage.open(path).convert("RGB").resize(core.scaled_size(w), PILImage.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return Image(data=buf.getvalue(), format="png")


@mcp.tool()
def click(desktop: int, x: int, y: int, button: str = "left") -> str:
    """Click at (x, y). button: left, middle or right."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x, y), "click", _button(button), display=desktop)
    return "ok"


@mcp.tool()
def double_click(desktop: int, x: int, y: int) -> str:
    """Double-click the left button at (x, y)."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x, y), "click", "--repeat", "2", "--delay", "80", "1", display=desktop)
    return "ok"


@mcp.tool()
def move(desktop: int, x: int, y: int) -> str:
    """Move the pointer to (x, y)."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x, y), display=desktop)
    return "ok"


@mcp.tool()
def drag(desktop: int, x1: int, y1: int, x2: int, y2: int) -> str:
    """Press the left button at (x1, y1), move to (x2, y2), release."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x1, y1), "mousedown", "1",
        "mousemove", "--sync", *pt(x2, y2), "mouseup", "1", display=desktop)
    return "ok"


@mcp.tool(name="type")
def type_text(desktop: int, text: str) -> str:
    """Type text into the focused window."""
    need(desktop)
    run("xdotool", "type", "--delay", "12", "--", text, display=desktop)
    return "ok"


@mcp.tool()
def key(desktop: int, combo: str) -> str:
    """Press a key or combination, xdotool syntax: Return, ctrl+c, ctrl+alt+t, super."""
    need(desktop)
    if not core.valid_key_combo(combo):
        raise ValueError(f"invalid key combo {combo!r}")
    run("xdotool", "key", "--", combo, display=desktop)
    return "ok"


@mcp.tool()
def scroll(desktop: int, x: int, y: int, direction: str = "down", amount: int = 3) -> str:
    """Scroll at (x, y). direction: up, down, left, right. amount: 1-50 notches."""
    need(desktop)
    if direction not in core.SCROLL:
        raise ValueError(f"direction must be one of {sorted(core.SCROLL)}")
    amount = min(max(int(amount), 1), 50)
    run("xdotool", "mousemove", "--sync", *pt(x, y), "click", "--repeat", str(amount), "--delay", "30",
        core.SCROLL[direction], display=desktop)
    return "ok"


@mcp.tool()
def cursor_position(desktop: int) -> dict:
    """Current pointer position in screenshot coordinates."""
    need(desktop)
    out = run("xdotool", "getmouselocation", "--shell", display=desktop)
    vals = dict(line.split("=", 1) for line in out.split() if "=" in line)
    x, y = core.to_scaled(int(vals["X"]), int(vals["Y"]), conf()[1])
    return {"x": x, "y": y}


def main():
    if sys.argv[1:2] == ["--http"]:
        print("--http not implemented yet", file=sys.stderr)
        sys.exit(2)
    mcp.run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run unit tests in CI lint**

In `.github/workflows/build.yml`, in the step that runs `test/env_test.sh`, add a line after it:
```yaml
          python3 test/computer_test.py
```

- [ ] **Step 6: Build and test**

```bash
chmod +x mkosi.extra/usr/local/bin/agentos-computer test/mcp_client.py
python3 test/computer_test.py
.superpowers/sdd/devvm.sh run 'shellcheck -S warning mkosi.extra/usr/local/bin/agentos-computer mkosi.prepare.chroot mkosi.finalize.chroot && python3 -m py_compile mkosi.extra/usr/local/lib/agentos/computer/server.py test/mcp_client.py && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `core OK`, `ALL CHECKS PASSED` including `check_mcp_stdio_end_to_end`, and the build log still prints `image invariants OK`.

If an `mcp` v1 API name differs in the installed version (e.g. `streamablehttp_client`, `Image`, the `FastMCP(host=…)` kwarg), check it in the VM (`/usr/local/lib/agentos/venv/bin/python -c "import mcp, inspect; …"`), use the installed version's name, and report it.

- [ ] **Step 7: Commit**

```bash
git add mkosi.prepare.chroot mkosi.finalize.chroot mkosi.extra/usr/local/bin/agentos-computer \
  mkosi.extra/usr/local/lib/agentos/computer/server.py test/mcp_client.py test/checks/92-computer.sh .github/workflows/build.yml
git commit -m "feat: agentos-computer MCP server (stdio) with end-to-end desktop test"
```

---

### Task 5: MCP over HTTP on the tailnet

**Files:**
- Create: `mkosi.extra/etc/systemd/system/agentos-mcp-http.service`, `test/checks/93-mcp-http.sh`
- Modify: `mkosi.extra/usr/local/lib/agentos/computer/server.py` (`main()` plus a `BearerAuth` class)

**Interfaces:**
- Consumes: `server.py` (`mcp`, tools) from Task 4; `/etc/agentos/mcp-token` (Plan 1).
- Produces: `agentos-computer --http HOST:PORT`, which serves Streamable HTTP at `/mcp` behind bearer auth. Token is read from `$CREDENTIALS_DIRECTORY/mcp-token`, falling back to `/etc/agentos/mcp-token`. It refuses to start if the token is shorter than 32 chars.
- Produces: `agentos-mcp-http.service` on `0.0.0.0:8765`.

- [ ] **Step 1: Write the failing checks**

`test/checks/93-mcp-http.sh`:
```bash
# shellcheck shell=bash
check_mcp_http_rejects_missing_or_wrong_token() {
  vm 'systemctl is-active agentos-mcp-http.service &&
      test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST http://127.0.0.1:8765/mcp)" = 401 &&
      test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST -H "Authorization: Bearer wrong" http://127.0.0.1:8765/mcp)" = 401 &&
      test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST -H "Authorization: bearer $(printf %064d 0)" http://127.0.0.1:8765/mcp)" = 401'
}
check_mcp_http_end_to_end() {
  vm 'cat > /tmp/mcp_client.py' < "$HERE/mcp_client.py" &&
  vm 't=$(sudo cat /etc/agentos/mcp-token) && /usr/local/lib/agentos/venv/bin/python /tmp/mcp_client.py http http://127.0.0.1:8765/mcp "$t"'
}
check_mcp_http_not_reachable_from_lan() {
  vm 'test "$(curl -s -o /dev/null -w "%{http_code}" -m 5 -X POST "http://$(hostname -I | awk "{print \$1}"):8765/mcp")" = 401' &&
  ! curl -s -m 5 -X POST "http://127.0.0.1:$HOSTPORT_MCP/mcp" >/dev/null
}
check_mcp_http_unit_hardened() {
  vm 'systemctl show agentos-mcp-http.service -p User -p NoNewPrivileges -p ProtectSystem -p Requires |
      sort | tr "\n" " " | grep -q "NoNewPrivileges=yes ProtectSystem=strict Requires=agentos-firewall.service.*User=agent" &&
      ! systemctl cat agentos-mcp-http.service | grep -q "^Environment=.*TOKEN"'
}
```

Run the uefi smoke test. Expected: all four FAIL.

- [ ] **Step 2: Implement HTTP in `server.py`**

Add `import hmac` to the imports, and replace `main()` with:
```python
class BearerAuth:
    """ASGI wrapper: every HTTP request must carry Authorization: Bearer <token>. Lifespan passes through."""

    def __init__(self, app, token):
        self.app, self.expected = app, b"Bearer " + token

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            got = dict(scope["headers"]).get(b"authorization", b"")
            if not hmac.compare_digest(got, self.expected):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain"), (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": b"unauthorized\n"})
                return
        await self.app(scope, receive, send)


def serve_http(hostport):
    import uvicorn
    host, _, port = hostport.rpartition(":")
    path = os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/etc/agentos"), "mcp-token")
    token = open(path, "rb").read().strip()
    if len(token) < 32:
        sys.exit(f"MCP token in {path} missing or too short")
    uvicorn.run(BearerAuth(mcp.streamable_http_app(), token), host=host, port=int(port), log_level="warning")


def main():
    if sys.argv[1:2] == ["--http"] and len(sys.argv) == 3:
        serve_http(sys.argv[2])
    else:
        mcp.run()
```

- [ ] **Step 3: Unit**

`mkosi.extra/etc/systemd/system/agentos-mcp-http.service`:
```ini
[Unit]
Description=AgentOS computer-use MCP server (Streamable HTTP, tailnet only)
Requires=agentos-firewall.service
After=agentos-firewall.service agentos-firstboot.service network.target

[Service]
User=agent
LoadCredential=mcp-token:/etc/agentos/mcp-token
ExecStart=/usr/local/bin/agentos-computer --http 0.0.0.0:8765
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/tmp

[Install]
WantedBy=multi-user.target
```
`PrivateTmp` stays off on purpose: the server talks to X through `/tmp/.X11-unix`, and shares `/tmp/agentos-desktop.lock` with stdio instances.

- [ ] **Step 4: Build and test**

```bash
.superpowers/sdd/devvm.sh run 'python3 -m py_compile mkosi.extra/usr/local/lib/agentos/computer/server.py && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/computer/server.py mkosi.extra/etc/systemd/system/agentos-mcp-http.service test/checks/93-mcp-http.sh
git commit -m "feat: agentos-computer over Streamable HTTP on the tailnet behind a bearer token"
```

---

### Task 6: Register `agentos-computer` in all four agent CLIs

**Files:**
- Create: `mkosi.extra/usr/local/lib/agentos/register-mcp`, `test/checks/94-cli-mcp.sh`
- Modify: `mkosi.extra/usr/local/sbin/agentos-firstboot`

**Interfaces:**
- Consumes: `/usr/local/bin/agentos-computer` (Task 4); the CLIs on the agent's PATH (Plan 1).
- Produces: `/usr/local/lib/agentos/register-mcp`, which runs as `agent` and is idempotent. It ensures:
  - Claude Code: user-scope MCP server `agentos-computer` (via `claude mcp add`).
  - Codex: `[mcp_servers.agentos-computer]` in `~/.codex/config.toml`.
  - Grok: `[mcp_servers.agentos-computer]` in `~/.grok/config.toml`, plus `[mcp] max_output_bytes = 4000000` if no `[mcp]` table exists (Grok's 20 KB default cap truncates screenshots).
  - opencode: `.mcp["agentos-computer"] = {type: "local", command: ["/usr/local/bin/agentos-computer"], enabled: true}` in `~/.config/opencode/opencode.json`.
- Firstboot calls it as agent on every boot. A failure only warns and never fails the boot.

- [ ] **Step 1: Write the failing checks**

`test/checks/94-cli-mcp.sh`:
```bash
# shellcheck shell=bash
check_claude_mcp_registered()   { vml 'claude mcp get agentos-computer 2>&1 | grep -q /usr/local/bin/agentos-computer'; }
check_claude_mcp_connects()     { vml 'claude mcp list 2>&1 | grep agentos-computer | grep -qi connected'; }
check_codex_mcp_registered()    { vml 'codex mcp list 2>&1 | grep -q agentos-computer'; }
check_grok_mcp_registered()     { vml 'grok mcp list 2>&1 | grep -q agentos-computer' && vm 'grep -qx "max_output_bytes = 4000000" ~/.grok/config.toml'; }
check_opencode_mcp_registered() {
  vm 'jq -e ".mcp[\"agentos-computer\"] == {\"type\":\"local\",\"command\":[\"/usr/local/bin/agentos-computer\"],\"enabled\":true}" ~/.config/opencode/opencode.json >/dev/null'
}
check_register_idempotent() {
  vm 'sudo agentos-config apply &&
      test "$(grep -c "^\[mcp_servers\.agentos-computer\]" ~/.codex/config.toml)" = 1 &&
      test "$(grep -c "^\[mcp_servers\.agentos-computer\]" ~/.grok/config.toml)" = 1 &&
      test "$(grep -c "^\[mcp\]" ~/.grok/config.toml)" = 1'
}
check_register_keeps_user_config() {
  vm 'printf "\n[mcp_servers.mine]\ncommand = \"/bin/true\"\n" >> ~/.codex/config.toml &&
      sudo agentos-config apply && grep -q "^\[mcp_servers\.mine\]" ~/.codex/config.toml'
}
```

Run the uefi smoke test. Expected: all of them FAIL.

- [ ] **Step 2: Implement registration**

`mkosi.extra/usr/local/lib/agentos/register-mcp`:
```bash
#!/bin/bash
# Register the agentos-computer MCP server with every agent CLI. Idempotent, runs as agent at
# every boot (from agentos-firstboot), never edits other entries. Done at boot, not build time,
# so no CLI state is baked into the image.
set -euo pipefail
NAME=agentos-computer
CMD=/usr/local/bin/agentos-computer
rc=0

# Claude Code (user scope, ~/.claude.json)
if ! claude mcp get "$NAME" >/dev/null 2>&1; then
  claude mcp add --scope user "$NAME" -- "$CMD" >/dev/null || { echo "claude: registration failed" >&2; rc=1; }
fi

# Codex and Grok share the TOML shape
for f in "$HOME/.codex/config.toml" "$HOME/.grok/config.toml"; do
  mkdir -p "$(dirname "$f")"; touch "$f"
  grep -q "^\[mcp_servers\.$NAME\]" "$f" || printf '\n[mcp_servers.%s]\ncommand = "%s"\n' "$NAME" "$CMD" >> "$f"
done
grep -q '^\[mcp\]' "$HOME/.grok/config.toml" || printf '\n[mcp]\nmax_output_bytes = 4000000\n' >> "$HOME/.grok/config.toml"

# opencode (JSON)
f=$HOME/.config/opencode/opencode.json
mkdir -p "$(dirname "$f")"
[ -s "$f" ] || printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$f"
tmp=$(mktemp "$f.XXXXXX")
if jq --arg n "$NAME" --arg c "$CMD" '.mcp[$n] //= {type: "local", command: [$c], enabled: true}' "$f" > "$tmp"; then
  mv "$tmp" "$f"
else
  rm -f "$tmp"; echo "opencode: $f is not valid JSON, left untouched" >&2; rc=1
fi
exit "$rc"
```

In `mkosi.extra/usr/local/sbin/agentos-firstboot`, insert before the `# 5. Tailscale` block:
```bash
# 4d. Register the computer-use MCP server with the agent CLIs (warn only: never block boot on it).
runuser -u agent -- env -i HOME=/home/agent USER=agent \
  PATH=/home/agent/.local/bin:/home/agent/.cargo/bin:/home/agent/.bun/bin:/home/agent/.opencode/bin:/home/agent/.grok/bin:/usr/local/bin:/usr/bin:/bin \
  /usr/local/lib/agentos/register-mcp || echo "warning: agentos-computer MCP registration incomplete" >&2
```

- [ ] **Step 3: Build and test**

```bash
chmod +x mkosi.extra/usr/local/lib/agentos/register-mcp
.superpowers/sdd/devvm.sh run 'shellcheck -S warning mkosi.extra/usr/local/lib/agentos/register-mcp mkosi.extra/usr/local/sbin/agentos-firstboot && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed'
.superpowers/sdd/devvm.sh wait <JOB>
```
Expected: `ALL CHECKS PASSED` for all three modes, and `image invariants OK` in the build log (no `~/.claude*` at build time).

If a CLI's `mcp list`/`mcp get` subcommand differs in the installed version, check its `--help` in the VM, adapt the check (not the registration format), and report it. If `claude mcp list` can't show "connected" without a login, replace `check_claude_mcp_connects` with a direct stdio handshake: run `test/mcp_client.py stdio` via the exact command Claude has registered (read it with `claude mcp get`). Report which one you used.

- [ ] **Step 4: Commit**

```bash
git add mkosi.extra/usr/local/lib/agentos/register-mcp mkosi.extra/usr/local/sbin/agentos-firstboot test/checks/94-cli-mcp.sh
git commit -m "feat: register agentos-computer MCP in claude, codex, grok and opencode at first boot"
```

---

## Spec coverage (Plan 2)

| Spec item (Section 2 and related) | Task |
|---|---|
| Xvnc :N 1920×1080 + XFCE per desktop, own D-Bus session | 1 |
| Multi-session risk spike, with fallback as a decision gate | 1 |
| Minimal XFCE (no Thunar/plugins/screensaver/power manager), Debian Chromium | 1 |
| Desktop terminals are login shells (API keys available to agents in desktops) | 1 |
| systemd as the registry; polkit scoped to `agentos-desktop@*` | 2, 4 |
| Max desktops (default 8) and screenshot width, configurable via agentos-config | 2 |
| Per-desktop random token, noVNC on 6080, view_url | 2, 3 |
| Screenshot scaling 1920→1366 with coordinate mapping and clamping | 3, 4 |
| The 12 MCP tools | 4 |
| stdio transport pre-registered in claude, codex, opencode, grok | 4, 6 |
| HTTP on 8765, bearer token, constant-time compare, 401 | 5 |
| Tailnet-only reachability, units require the firewall, sandboxed as agent | 2, 5 |
| No desktop/MCP unit reads API keys | 5 (unit check) |
| Known-risk notes: no idle reaper; one agent per desktop | 4 (`ponytail:` lock comment) |
| Playwright headless for web tasks | Plan 1 (already installed) |
