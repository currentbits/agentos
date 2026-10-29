# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

check_agentos_package_installed() {  # sorts before check_agentos_update and check_update_*
  # The image carries the .deb this build made, untouched, and no unit files in the old place.
  local want; want=$(dpkg-deb -f "$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb)" Version) || return 1
  vm 'test "$(agentos-update --version)" = "'"$want"'" && test -z "$(sudo dpkg -V agentos)" &&
      test -z "$(find /etc/systemd/system -maxdepth 1 -name "agentos-*" -print -quit)" &&
      test ! -e /etc/systemd/system/docker.service.d/10-agentos.conf &&
      systemctl is-enabled --quiet agentos-update-check.timer && systemctl is-active --quiet agentos-update-check.timer &&
      test "$(stat -c "%U %a" /var/log/agentos-update.log /run/lock/agentos-update.lock | sort -u)" = "agent 644"'
}

check_update_dev_build_source_disabled() {
  # This image comes from a development build (AGENTOS_DEV=1): the check says so, as an error.
  vm 'grep -qx "Enabled: no" /etc/apt/sources.list.d/agentos.sources && sudo agentos-update --check >/dev/null &&
      jq -e ".available == null and .error == \"the AgentOS update source is disabled (development build)\"" /var/lib/agentos/update.json >/dev/null &&
      test -z "$(agentos-update --notice)" && test ! -e /run/issue.d/60-agentos-update.issue'
}

# upd_repo KEY DEB...: a signed apt repo of the given packages in $WORK/upd/repo (suite stable,
# component main, signed by $WORK/upd/KEY), copied to ~/upd-repo in the VM.
upd_repo() {
  local key=$1 r=$WORK/upd/repo; shift
  rm -rf "$r" && mkdir -p "$r/pool" "$r/dists/stable/main/binary-amd64" && cp "$@" "$r/pool/" &&
  (cd "$r" && apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages) &&
  apt-ftparchive -o APT::FTPArchive::Release::Origin=AgentOS -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Components=main -o APT::FTPArchive::Release::Architectures=amd64 \
    release "$r/dists/stable" > "$WORK/upd/Release" && mv "$WORK/upd/Release" "$r/dists/stable/Release" &&
  GNUPGHOME=$WORK/upd/$key gpg -q --batch --yes --clearsign -o "$r/dists/stable/InRelease" "$r/dists/stable/Release" &&
  mkdir -p "$r/notes" && echo "Smoke release notes <b>plain</b>" > "$r/notes/$(dpkg-deb -f "$1" Version).md" &&
  tar -C "$r" -cf - . | vm 'rm -rf ~/upd-repo && mkdir ~/upd-repo && tar -C ~/upd-repo -xf -'
}
# upd_deb VERSION: N's package repacked as VERSION, with a migration that writes a marker, a changed
# unit (agentos-web gets an Environment= line), a new enabled unit, and a changed conffile.
upd_deb() {
  local t=$WORK/upd/pkg-$1
  rm -rf "$t" && dpkg-deb -R "$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb)" "$t" &&
  sed -i "s/^Version: .*/Version: $1/" "$t/DEBIAN/control" &&
  printf '#!/bin/bash\necho "%s $(date +%%s%%N)" >> /var/lib/agentos/smoke-marker\n' "$1" > "$t/usr/local/lib/agentos/migrations/900-smoke-marker.sh" &&
  sed -i 's/^Environment=LANG=C.UTF-8$/Environment=LANG=C.UTF-8 AGENTOS_SMOKE=1/' "$t/usr/lib/systemd/system/agentos-web.service" &&
  printf '[Unit]\nDescription=smoke\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' \
    > "$t/usr/lib/systemd/system/agentos-smoke.service" &&
  echo agentos-smoke.service >> "$t/usr/local/lib/agentos/units.new" &&
  echo "# smoke $1" >> "$t/etc/sysctl.d/90-agentos.conf" &&
  dpkg-deb --root-owner-group -b "$t" "$WORK/upd/agentos_$1_amd64.deb" >/dev/null
}

check_update_end_to_end() {
  # Spec §7: N+1 from a local repo signed with a test key, through a source override; check, then
  # update through the web UI (agentos-web restarts mid-update); what must survive does; rollback
  # to N; the repo re-signed with another key is an error and installs nothing.
  local deb n n1 n2 rc=0 webpid runid
  deb=$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb) && n=$(dpkg-deb -f "$deb" Version) || return 1
  n1="$n+smoke1" n2="$n+smoke2"
  rm -rf "$WORK/upd" && mkdir "$WORK/upd" && for k in good bad; do   # $WORK is shared by the modes
    mkdir -m 700 "$WORK/upd/$k" &&
    GNUPGHOME=$WORK/upd/$k gpg -q --batch --passphrase '' --quick-gen-key "AgentOS smoke $k <smoke@invalid>" ed25519 sign never 2>/dev/null || return 1
  done
  upd_deb "$n1" && upd_repo good "$WORK/upd/agentos_${n1}_amd64.deb" "$deb" || return 1
  GNUPGHOME=$WORK/upd/good gpg -q --batch --export | vm 'sudo install -D -m 644 /dev/stdin /etc/apt/keyrings/agentos-smoke.gpg' || return 1
  # The source override is a local edit of a conffile (kept by the update); the sysctl edit, too.
  vm 'sudo cp /etc/apt/sources.list.d/agentos.sources /var/tmp/agentos.sources.orig &&
      printf "Types: deb\nURIs: http://127.0.0.1:8099\nSuites: stable\nComponents: main\nSigned-By: /etc/apt/keyrings/agentos-smoke.gpg\n" |
        sudo tee /etc/apt/sources.list.d/agentos.sources >/dev/null &&
      echo "# smoke local edit" | sudo tee -a /etc/sysctl.d/90-agentos.conf >/dev/null &&
      sudo systemd-run --unit=smoke-repo -p User=agent python3 -m http.server 8099 --bind 127.0.0.1 --directory /home/agent/upd-repo &&
      for _ in $(seq 1 20); do curl -fsS -o /dev/null http://127.0.0.1:8099/dists/stable/InRelease && exit 0; sleep 0.5; done; exit 1' || return 1

  # The check reports N+1 everywhere: update.json, the MOTD (pam_motd at this ssh login) and the console.
  vm 'sudo agentos-update --check | head -1 | grep -qx "AgentOS '"$n1"' is available (installed: '"$n"')" &&
      jq -e --arg v "'"$n1"'" ".available == \$v and .error == null and (.notes | startswith(\"Smoke release notes\"))" /var/lib/agentos/update.json >/dev/null &&
      grep -qx "AgentOS '"$n1"' available: run agentos-update (or use the web UI)" /run/issue.d/60-agentos-update.issue' || rc=1
  vm 'grep -qF "AgentOS '"$n1"' available" /run/motd.dynamic' || rc=1

  # unattended-upgrades must never install agentos: with N+1 available (and apt's lists already
  # refreshed for the AgentOS source by the --check above), a real `unattended-upgrade --dry-run -d`
  # is the most direct evidence that AgentOS's own origin pinning (52agentos-unattended) actually
  # works, rather than re-deriving the same conclusion by statically reading that file. Its debug
  # log (verified verbatim against a real run: unattended-upgrades 2.x, same config, a two-version
  # repo) says "adjusting candidate to version agentos=<installed> in allowed origin [...]" once it
  # pins the AgentOS origin file at -32768 and falls back to the already-installed version, and
  # never lists agentos among the packages it decides to upgrade.
  vm 'sudo unattended-upgrade --dry-run -d > /tmp/uu.log 2>&1
      grep -qF "adjusting candidate to version agentos='"$n"' in allowed origin" /tmp/uu.log &&
      ! grep "^pkgs that look like they should be upgraded:" /tmp/uu.log | grep -qw agentos' || { rc=1; vm 'tail -40 /tmp/uu.log'; }

  # What must survive the update, started through the web UI so they live in agentos-web's cgroup:
  # a tmux session and a CI run; and a running desktop.
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" || return 1
  runid=$(vm "$WEB$CI_REPO"'d=$(ci_repo upd-survivor .agentos/ci.yml "steps: [{name: s, run: sleep 31339}]") &&
    wm -X POST -d "{\"path\":\"$d\"}" $U/api/ci/runs | jq -r .run_id') && [ -n "$runid" ] || return 1
  vm "$WEB"'wm -X POST -d "{\"cli\":\"shell\",\"name\":\"upd\"}" $U/api/sessions | grep -q "\"id\":\"ag-upd\"" &&
      sudo systemctl start agentos-desktop@5.service &&
      for _ in $(seq 1 30); do pgrep -f "sleep 31339" >/dev/null && exit 0; sleep 1; done; exit 1' || rc=1
  vm 'systemctl show -p MainPID --value agentos-desktop@5.service > /tmp/desk.pid' || rc=1
  webpid=$(vm 'systemctl show -p MainPID --value agentos-web.service')

  # Update through the web UI: the stream ends when agentos-web restarts; the run goes on (its log).
  vm "$WEB"'node /tmp/web_ws.mjs update >/tmp/upd-stream.txt 2>&1; up &&
    for _ in $(seq 1 900); do w $U/api/update/log | jq -e ".running == false" >/dev/null && break; sleep 2; done &&
    w $U/api/update/log | jq -r .text > /tmp/upd.log && grep -qx "ok    agentos" /tmp/upd.log && grep -q "^== done" /tmp/upd.log' || {
    rc=1; vm 'cat /tmp/upd-stream.txt /tmp/upd.log 2>/dev/null | tail -40'; }

  vm "$WEB"'test "$(agentos-update --version)" = "'"$n1"'" &&
    test "$(w $U/api/update | jq -r .installed)" = "'"$n1"'" &&
    test "$(systemctl show -p MainPID --value agentos-web.service)" != "'"$webpid"'" &&
    systemctl show -p Environment --value agentos-web.service | grep -qw AGENTOS_SMOKE=1 &&
    systemctl is-enabled --quiet agentos-smoke.service && systemctl is-active --quiet agentos-smoke.service &&
    test "$(wc -l < /var/lib/agentos/smoke-marker)" = 1 &&
    sudo /var/lib/dpkg/info/agentos.postinst configure "'"$n1"'" >/dev/null && test "$(wc -l < /var/lib/agentos/smoke-marker)" = 1 &&
    grep -qx "# smoke local edit" /etc/sysctl.d/90-agentos.conf && grep -qx "# smoke '"$n1"'" /etc/sysctl.d/90-agentos.conf.dpkg-dist &&
    grep -q 127.0.0.1:8099 /etc/apt/sources.list.d/agentos.sources &&
    tmux has-session -t =ag-upd &&
    test "$(systemctl show -p MainPID --value agentos-desktop@5.service)" = "$(cat /tmp/desk.pid)" &&
    pgrep -f "sleep 31339" >/dev/null && test "$(agentos-ci status '"$runid"' --json | jq -r .status)" = running &&
    jq -e ".available == null" /var/lib/agentos/update.json >/dev/null && test ! -e /run/issue.d/60-agentos-update.issue' || rc=1

  # Rollback to N: lists the versions, installs N, and the check offers N+1 again.
  vm 'agentos-update --rollback > /tmp/rb.txt; r=$?; cat /tmp/rb.txt; test $r = 0 &&
      grep -qx "  '"$n1"'" /tmp/rb.txt && grep -qx "ok    agentos '"$n"'" /tmp/rb.txt &&
      test "$(agentos-update --version)" = "'"$n"'" && jq -e ".available == \"'"$n1"'\"" /var/lib/agentos/update.json >/dev/null' || rc=1

  # A version that is not in the repo at all is refused (distinct from "the repo could not be
  # read" below): nothing is installed, and the installed version doesn't change.
  vm 'agentos-update --rollback 9.9.9 > /tmp/rb9.txt; r=$?; cat /tmp/rb9.txt; test $r = 1 &&
      grep -qx "FAIL  rollback (9.9.9 is not in the repo)" /tmp/rb9.txt &&
      test "$(agentos-update --version)" = "'"$n"'"' || rc=1

  # The repo re-signed with another key (now offering N+2): an error, and nothing installs.
  upd_deb "$n2" && upd_repo bad "$WORK/upd/agentos_${n2}_amd64.deb" "$WORK/upd/agentos_${n1}_amd64.deb" "$deb" || rc=1
  vm 'sudo agentos-update --check >/dev/null &&
      jq -e ".available == null and (.error | test(\"Missing key|NO_PUBKEY|verif\"))" /var/lib/agentos/update.json >/dev/null &&
      ! agentos-update --rollback "'"$n2"'" >/tmp/rb2.txt && grep -q "FAIL  rollback (the AgentOS repo could not be read)" /tmp/rb2.txt &&
      test "$(agentos-update --version)" = "'"$n"'"' || rc=1

  # Leave the box as the other checks expect it.
  vm "$WEB"'sudo systemctl stop smoke-repo agentos-desktop@5.service; agentos-ci cancel '"$runid"' >/dev/null
      wm -X POST $U/api/sessions/ag-upd/stop >/dev/null; wm -X DELETE $U/api/sessions/ag-upd >/dev/null
      sudo cp /var/tmp/agentos.sources.orig /etc/apt/sources.list.d/agentos.sources; sudo rm -f /etc/apt/keyrings/agentos-smoke.gpg
      sudo sed -i "/^# smoke local edit$/d" /etc/sysctl.d/90-agentos.conf; sudo rm -f /etc/sysctl.d/90-agentos.conf.dpkg-dist
      sudo agentos-update --check >/dev/null' || true
  return "$rc"
}

check_update_notice_console_and_motd() {
  # A release in update.json shows on the console (firstboot rewrites /run/issue.d at every boot and
  # apply) and at the next SSH login (pam_motd runs /etc/update-motd.d); without one it goes away.
  vm 'sudo agentos-update --check >/dev/null && sudo cp /var/lib/agentos/update.json /var/tmp/update.json.orig &&
      printf "{\"installed\":\"0.1\",\"available\":\"9.9.9\",\"notes\":\"\",\"checked_at\":\"2026-10-29T00:00:00Z\",\"error\":null}\n" |
        sudo tee /var/lib/agentos/update.json >/dev/null &&
      sudo rm -f /run/issue.d/60-agentos-update.issue && sudo agentos-config apply &&
      grep -qx "AgentOS 9.9.9 available: run agentos-update (or use the web UI)" /run/issue.d/60-agentos-update.issue' &&
  vm 'grep -qx "AgentOS 9.9.9 available: run agentos-update (or use the web UI)" /run/motd.dynamic &&
      sudo cp /var/tmp/update.json.orig /var/lib/agentos/update.json && sudo agentos-update --issue &&
      test ! -e /run/issue.d/60-agentos-update.issue && test -z "$(agentos-update --notice)"'
}
