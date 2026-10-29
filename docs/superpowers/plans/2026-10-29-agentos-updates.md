# AgentOS Updates Implementation Plan (Plan 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A box owner moves an installed AgentOS box to the latest AgentOS release (features and fixes) without reinstalling: the box checks daily, says so, and installs on one click or `agentos-update`.

**Architecture:**
- **The package.** Everything AgentOS installs itself moves from `mkosi.extra` and `mkosi.prepare.chroot` into one `agentos` .deb. Its tree is the new top-level `package/` directory (the old `mkosi.extra`, minus a few image-only files), plus what `tools/build-deb.sh` builds in a `debian:trixie` container: the venv, the web UI, `act` and the Solenta bridge. Units move to `/usr/lib/systemd/system`. mkosi installs the same .deb from `mkosi.packages/`, so a fresh image and an updated box run identical code.
- **The repo.** On a `v*` tag, the release job adds the .deb to an apt repo on `gh-pages` (`apt-ftparchive`, signed with `AGENTOS_APT_KEY`), with the notes and `latest.json`. The image trusts it only through its own `Signed-By` keyring.
- **On the box.** The postinst (`/usr/local/lib/agentos/configure`) reloads units, enables new ones, runs one-time migrations, restarts AgentOS's services and re-registers the MCP servers. `agentos-update` gains `--check` (daily timer, writes `update.json`), `--rollback`, `--version`, `--notice` and `--issue`, and installs the `agentos` package first. It survives `agentos-web`'s restart mid-update. The web UI shows the state, "Check now" and the existing Update action; the console and the MOTD show one line.

**Tech Stack:**
- the existing stack: bash, systemd 257, dpkg/apt 3.0 (Debian 13), mkosi 27, Python 3.13 venv, NodeSource Node 24 server and React UI, vitest 5.0.5, pytest;
- new tools: `dpkg-deb` in a `debian:trixie` Docker container (build), `apt-ftparchive` and `gpg` (publish), GitHub Pages (hosting).

**Builds on:** branch `updates` at e3ea7d7 (the spec commit on top of the merged Solenta and CI work). Implement in the main checkout `/Users/willem/Projects/AgentOS`, on branch `updates`. Read `.superpowers/sdd/context.md` for the build host workflow (devvm, `devvm.sh`, `TMPDIR=/var/tmp`, foreground polling).

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-10-29-agentos-updates-design.md`). When this plan and the spec disagree, the spec wins, except for the deliberate, evidenced adjustments listed under "Spec adjustments" below.

- **Notify and one click.** The box checks daily and tells the owner. The owner clicks Update in the web UI, or runs `agentos-update`. Nothing installs on its own.
- **Delivery:** a signed `agentos` .deb from AgentOS's own apt repo.
- **Hosting:** GitHub Pages of the AgentOS GitHub repo. The repo doesn't exist yet. Creating it, pushing, and creating the signing key and secret are the owner's steps, and nothing is published without their go-ahead.
- **Non-goals:** automatic installs, release channels (beta/stable), A/B image updates, and non-amd64 builds.
- **One binary package, `agentos`, amd64.** The version comes from the release tag (`v1.4.0` becomes `1.4.0`). Untagged builds are `0.0.0~git<date>.<sha>`.
- **Units move from `/etc/systemd/system` to `/usr/lib/systemd/system`**, so they aren't conffiles and an update never prompts. Drop-ins that are true local config stay in `/etc`.
- The files in `/etc/profile.d`, `/etc/sudoers.d`, `/etc/sysctl.d`, `/etc/ssh/sshd_config.d`, `/etc/apt`, polkit, `/etc/issue` and docker `daemon.json` stay in `/etc` as dpkg conffiles. A locally edited conffile is kept, with the new one saved as `.dpkg-dist`; the update runs with `--force-confdef --force-confold`, so it never prompts.
- Not in the package: Debian packages (declared in `Depends:`, keeping a minimal base in mkosi); the agent CLIs, Rust, bun and Playwright in `~agent`; user state: `/etc/agentos/agentos.env`, `~/.config/agentos/secrets.env` and everything in `/home`.
- `tools/build-deb.sh` builds the package with `dpkg-deb` in a `debian:trixie` container, so the venv and the native `node-pty` build match the image.
- The image build installs **this same .deb**, through mkosi's local package directory support.
- **Invariant:** the finalize invariants stay: no CLI state in the image.
- On a `v*` tag, the existing release workflow builds the .deb and adds it to an apt repo kept on the GitHub repo's `gh-pages` branch: suite `stable`, component `main`, arch `amd64`. Old versions stay in the pool, so rollback works.
- `InRelease` and `Release.gpg` are signed with a dedicated GPG key whose private half is the Actions secret `AGENTOS_APT_KEY`. Only the release job has write scopes, and only it touches `gh-pages`; this matches today's rule.
- The image ships the public key, at `/usr/share/keyrings/agentos-archive.gpg`, and `/etc/apt/sources.list.d/agentos.sources`, with `URIs: https://<owner>.github.io/<repo>/apt`, `Suites: stable`, `Components: main` and `Signed-By: /usr/share/keyrings/agentos-archive.gpg`. Only that key is trusted for this source, and the key is not trusted for any other source.
- **No automatic installs:** unattended-upgrades must never install `agentos`.
- Each release also publishes `apt/notes/<version>.md` (the "what's new" text) and `apt/latest.json` (`{version, notes_url, published}`).
- postinst, in order: `systemctl daemon-reload`; new units only (`units.new` vs `/var/lib/agentos/units.seen`, enabled per the preset, started if their condition holds; existing units keep the owner's state); one-time migrations `/usr/local/lib/agentos/migrations/NNN-name.sh`, recorded in `/var/lib/agentos/migrations.done`, a failing one stops the run and fails the configure; `systemctl try-restart` on `agentos-web`, `agentos-mcp-http`, `agentos-novnc` and `agentos-firewall`; `register-mcp --update`.
- **Never restarted:** `agentos-solenta`, `agentos-desktop@*`, agent tmux sessions and CI workers.
- On a fresh image build, `postinst` runs inside the image and must not need a running systemd. It detects the chroot and skips steps 1 and 4.
- `agentos-update-check.timer` runs daily, with a randomized delay and `Persistent=true`. It starts `agentos-update --check` as root, which writes `/var/lib/agentos/update.json`: `{installed, available|null, notes_url, notes (first 4 KB), checked_at, error|null}`. The file is world-readable and holds no secrets.
- **Overview** shows a banner, "AgentOS 1.4.0 is available", with the notes shown on demand. **System** shows the installed and available versions, a "Check now" button, and the existing **Update** button. `GET /api/update` reads `update.json`. `POST /api/update/check` runs the check through the actions table.
- Console and SSH: `AgentOS 1.4.0 available: run agentos-update (or use the web UI)`.
- An unreachable repo or a bad signature produces `error`, with the cause, in `update.json`, shown as a warning, never as "up to date".
- `agentos-update` keeps its current shape: the `ok` and `FAIL` lines, and an exit code of 1 if any step failed. Steps: `agentos` (`apt-get install --only-upgrade agentos` with the conffile options), `apt`, the agent CLIs and toolchains. Before step 1, active CI runs print a warning with their ids, without blocking.
- `agentos-update --rollback` installs the previous version with `--allow-downgrades`, lists the available versions, and `--rollback VERSION` picks one. A rollback doesn't undo migrations, which is documented. `agentos-update --version` prints the installed AgentOS version; the web UI shows it in the footer.
- The update keeps running when `agentos-web` restarts mid-update. The System page reconnects, and shows the result from the update log in `/var/log/agentos-update.log`.
- Security: packages are trusted only through the AgentOS key, via `Signed-By`, over HTTPS. The public key's fingerprint is printed in the docs. The web UI renders the notes as plain text (no HTML), and the console prints them through `printf %s`. Only the existing update action can install; `POST /api/update/check` is audited too.
- Owner steps (manual, documented, never executed by an implementer): create the GitHub repo and push; generate the signing key, add `AGENTOS_APT_KEY`, commit the public key; enable Pages on `gh-pages`; set the repo URL in `agentos.sources` (a build-time variable with a placeholder fails the build until it is set); tag `v1.0.0`. Older boxes: a reinstall, or a documented one-time bootstrap.

Repo conventions (from the earlier plans):
- Bash scripts are `#!/bin/bash` with `set -euo pipefail` and must be `shellcheck -S warning` clean.
- Checks in `test/checks/*.sh` use `&&` chains. Don't rely on `set -e` inside check functions. Check names are unique; `smoke.sh` runs them sorted by name, so every check sets up its own state.
- Smoke tests on devvm run with `TMPDIR=/var/tmp`. Never touch devvm's existing Docker containers or volumes; never prune. A throwaway `docker run --rm debian:trixie` is fine (`tools/build-deb.sh` needs one).
- Root used space ≤ 7168 MiB (`check_root_size_budget`; about 6556 MiB before this plan). No CLI state in the image (finalize invariants stay green).
- UI: React only, no UI framework, one stylesheet. Server: every exec goes through the `Runner` and the fixed actions table.

## Facts verified while writing this plan (2026-10-29)

| Fact | How | Result |
|---|---|---|
| mkosi 27 local packages | `mkosi.1.md` in devvm's mkosi 27; `installer/apt.py` `createrepo()`; a probe build (`/var/tmp/mkprobe`, `Format=directory`, a `probe` .deb with `Depends: hello` in `mkosi.packages/`) | `mkosi.packages/` is picked up with no setting ("If the `mkosi.packages/` directory is found in the local directory it is also used"); `PackageDirectories=` is only for other paths. mkosi runs `apt-ftparchive packages .` over it ("Rebuilding local package repository") and adds `file:///repository` with `Trusted: yes` to the sandbox only: no source is left in the image. `Packages=probe` installed it and pulled `hello` from Debian. |
| How mkosi runs the postinst | `installer/apt.py`: dpkg gets `--root=/buildroot`, a `policy-rc.d` that exits 101 is in place; the probe's postinst logged its environment | `configure` with an empty `$2`; `[ -d /run/systemd/system ]` is false; `systemd-detect-virt --chroot` exits 0; `/proc/1/comm` is the *host's* systemd (never use it); `SYSTEMD_OFFLINE=1`, `SYSTEMD_IN_CHROOT=1`; `systemctl daemon-reload` is a no-op returning 0; user `agent` does not exist yet. Build order (`__init__.py`): packages, prepare scripts, extra trees, postinst scripts, tmpfiles, `systemctl preset-all`, finalize. So the package's units get the preset from mkosi, and `mkosi.extra` must not overlap the package (it would silently overwrite package files). |
| dpkg conffile options | `docker run --rm debian:trixie`: a two-version `agentos` probe served from a local signed repo | With `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold`: a locally edited conffile is kept and the new one lands as `.dpkg-dist`, no prompt ("Keeping old config file as default"). An unedited conffile follows the package. `install --only-upgrade agentos` also installs a newly added `Depends:` (`hello`). `--only-upgrade` with `agentos` not installed exits 0 and installs nothing. `--allow-downgrades agentos=1.0.0` downgrades. |
| dpkg and files no package owns (bootstrap of older boxes) | Same container: unowned `/usr/local/lib/agentos/x` and a different unowned `/etc/agentos-probe.conf`, then install | The regular file is overwritten silently. The conffile: "File on system created by you or by a script … Keeping old config file as default", the package's copy saved as `.dpkg-dist`, exit 0. An existing directory keeps its metadata (`/etc/polkit-1/rules.d` stays `750 root:polkitd` after a package ships it as `755 root:root`). |
| Files the package can't own | Loop-mounted the last image (`mkosi.output/agentos.raw`, read-only), `var/lib/dpkg/info/*.list`; unattended-upgrades' postinst in a trixie container | `/etc/issue` belongs to `base-files` (a conffile): shipping it would fail with "trying to overwrite". `/etc/apt/apt.conf.d/20auto-upgrades` is written by unattended-upgrades' postinst through `ucf`/`ucfr`. Both stay in `mkosi.extra`. No other `/etc` file from `mkosi.extra` is owned by a package. |
| Repo tool and signing | Same container | `apt-ftparchive packages pool` lists every version in the pool (1.0.0 and 1.1.0 both indexed); reprepro keeps one version per package per suite by default, so rollback needs `apt-ftparchive`. `apt-ftparchive -o APT::FTPArchive::Release::{Origin,Label,Suite,Codename,Architectures,Components}=… release dists/stable`, then `gpg --clearsign` (InRelease) and `gpg -abs` (Release.gpg): apt 3.0 (sqv) accepted it. `apt-cache madison agentos` lists newest first. |
| `apt-get update` for one deb822 file | Same container | `apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/agentos.sources -o Dir::Etc::sourceparts=-` reads the deb822 file. **Without `-o APT::Get::List-Cleanup=0` it deletes every other source's lists** (6 Debian lists → 0); with it they stay. |
| Errors from `apt-get update` | Same container: repo re-signed with another key; URI on a closed port | A bad signature: plain `apt-get update` **exits 0** ("W: … The repository is not updated and the previous index files will be used … Missing key …, which is needed to verify signature"), and the old candidate stays. Unreachable: also exits 0. With `--error-on=any` both exit 100 with an `E:` line carrying the cause. `Enabled: no`: exit 0, nothing fetched. |
| `Signed-By` scoping | Same container: a second source signed with the AgentOS key | Without `Signed-By`: "E: The repository … is not signed" (a key in `/usr/share/keyrings` is not trusted globally). With `Signed-By: /usr/share/keyrings/agentos-archive.gpg`: OK. Debian's sources still verify with the AgentOS key file present. |
| Does `agentos-update` survive an `agentos-web` restart? | `system.ts` (`streamToSocket` uses `spawn`, not detached: the child stays in `agentos-web`'s cgroup); the unit has `KillMode=process`; devvm: a transient `KillMode=process` service whose Python main reads a bash child's stdout, restarted after 3 s; `node -e` with `/proc/self/status` | The child survives the restart (only the main PID is signalled). **A child that keeps writing to stdout dies of SIGPIPE at the first write after the reader died** (stopped at line 3 of 12). With `trap '' PIPE` and writes that ignore errors it ran to the end. Node ignores SIGPIPE itself (`SigIgn` 0x1000) but its children start with nothing ignored (`SigIgn` 0). So `agentos-update` must ignore SIGPIPE and log to a file. The web's in-memory one-run lock is lost on restart, so `agentos-update` takes its own `flock`. |
| unattended-upgrades and the `agentos` origin | Same container: unattended-upgrades 2.12, the image's `52agentos-unattended`, agentos 1.0.0 installed and 1.2.0 available | "Marking not allowed … o=AgentOS,l=AgentOS … with -32768 pin"; "No packages found that can be upgraded unattended". The release file's `Origin: AgentOS` matches no pattern. Note: the allowed origins also include `origin=Debian,codename=trixie,label=Debian` from Debian's own `50unattended-upgrades`, so "Debian security only" is not exact today; this plan doesn't change it. |
| The image's Node and Python | Last build's `agentos.manifest` | `nodejs 24.22.1-1nodesource1` (NodeSource, the image's own apt source), `python3 3.13.5-1`. trixie's own `nodejs` is 20 and has no `npm`: the first container build failed with "npm: command not found". |
| MOTD and console | devvm `/etc/pam.d/{sshd,login}`; the image's `/etc/update-motd.d`; `agentos-firstboot` | `pam_motd.so motd=/run/motd.dynamic` runs `/etc/update-motd.d/*` at every SSH and console login (`10-uname`, `92-unattended-upgrades` exist). agetty shows `/run/issue.d/*.issue` (firstboot already writes `50-agentos-web.issue` there). |
| The package, built | `AGENTOS_DEV=1 tools/build-deb.sh` on devvm, then `apt-get install ./agentos_*.deb` in a trixie container with the NodeSource source | About 4.5 minutes. 26,096,980 bytes; `Installed-Size: 128032`; 6,598 entries (venv 77 MiB, web 27 MiB, `act` 21 MiB). Installed: the postinst took the chroot path (`units.seen` = 12 units, `migrations.done` = `001-units-to-usr-lib.sh`); `dpkg -V agentos` empty; `/etc/polkit-1/rules.d` `750 root:polkitd`; `/etc/sudoers.d/agent` `440`; `import yaml, mcp, PIL` OK; `node-pty` loads on Node 24.22.2; `act version 0.2.89`. dpkg's own info files for it: about 1.3 MB. |
| The image, built from the package | `mkosi -f build` on devvm with the whole plan applied; manifest diff against the last build | Package set 643 → 644: **only `agentos` added, nothing removed**. `Unpacking polkitd` comes before `Unpacking agentos`. Finalize: "image invariants OK". Root filesystem used: 5637 MiB vs 5636 MiB for the previous image (unexpanded image, same measure). |
| GitHub Pages limits | GitHub Docs, "GitHub Pages limits" | Published sites may be no larger than 1 GB; git rejects files over 100 MB. At 26 MB per release, keeping the newest 10 versions stays near 260 MB. |

All code in this plan was run while writing it:
- **bash:** `configure_test.sh`, `register_mcp_test.sh`, `update_check_test.sh`, `apt_publish_test.sh`, and the existing `env_test.sh`, `wrapper_test.sh`, `solenta_pair_test.sh`, `web_serve_test.sh`, `computer_test.py`, on devvm.
- **pytest:** 70 passed (`test/ci`, after the path change).
- **vitest:** server 106 passed and 1 skipped (was 100 + 1), UI 23 (was 18). Both packages pass `tsc`; the UI builds.
- **shellcheck:** every new or changed script is `shellcheck -S warning` clean.
- **Image and VM:** the image was built with every task applied, and booted in QEMU (`uefi`) with a focused check set: `check_agentos_package_installed`, `check_agentos_update`, `check_root_size_budget`, `check_update_dev_build_source_disabled`, `check_update_end_to_end` and `check_update_notice_console_and_motd` all passed. The full three-mode smoke run is Task 7's.

## Spec adjustments (with evidence)

1. **The build container uses NodeSource Node 24, not Debian's `nodejs`.** The image's Node is NodeSource 24 (fact table); `node-pty` must match its ABI. `build-deb.sh` installs NodeSource from the repo's own `apt/` source and refuses any other major. `Depends:` pins `nodejs (>= 24~), nodejs (<< 25~)` and `python3.13` (the venv's interpreter).
2. **`/etc/issue` and `20auto-upgrades` stay in `mkosi.extra`.** `base-files` owns `/etc/issue`, and unattended-upgrades manages `20auto-upgrades` through ucf (fact table). The console line uses `/run/issue.d` instead. Also image-only, and kept in `mkosi.extra`: `/etc/fstab`, `80-dhcp.network`, `cloud.cfg.d/90-agentos.cfg`, `repart.d/50-root.conf` (disk layout and first boot), and `~agent/.config/xfce4/terminal/terminalrc` (user state under `/home`).
3. **The docker drop-in moves too**, to `/usr/lib/systemd/system/docker.service.d/10-agentos.conf`. It is AgentOS's vendor configuration, not local config; the only true local drop-in, `getty@tty1.service.d/agentos.conf`, is written at runtime by `agentos-console-apply` and stays in `/etc`.
4. **The box doesn't read `latest.json`.** The available version is apt's candidate, from the signed index; the notes come from `<repo>/notes/<candidate>.md`, at most 4 KB. `latest.json` is unsigned and could disagree with the index. It is still published, for people and other tools.
5. **The fail-closed switch is the committed `agentos.sources` file plus the committed key.** While the URL is the placeholder `https://OWNER.github.io/REPO/apt` or the key is missing, `build-deb.sh` fails with a clear message unless `AGENTOS_DEV=1`, which ships the source as `Enabled: no` (a development build). CI builds every non-tag with `AGENTOS_DEV=1`; a tag never is. `apt-publish.sh` refuses development builds, the placeholder URL and a keyring that isn't the signing key.
6. **On the image build, the postinst records instead of running.** In the chroot it copies `units.new` to `units.seen` and marks every migration done: the image already is in the release's state, and `agent` doesn't exist yet. On a live box with no `units.seen` (the one-time bootstrap of an older box), the units already in `/etc/systemd/system` count as seen, and migration `001-units-to-usr-lib.sh` moves them, keeping their enabled state.
7. **The postinst also runs `systemd-tmpfiles --create`** after `daemon-reload`, so the new lock and log files exist before anything uses them.
8. **A failing migration stops the configure before the restarts and `register-mcp`** (`set -e`), so dpkg reports it and the next update retries from that migration.
9. **`agentos-update` ignores SIGPIPE, logs every line to `/var/log/agentos-update.log` (truncated at each run), and holds `flock /run/lock/agentos-update.lock`** for the whole run (fact table). `--check` takes the same lock without waiting: it is skipped while an update runs. After an update or a rollback, it re-runs `--check`, so `update.json`, the console and the MOTD are never stale.
10. **The restricted refresh adds `--error-on=any` and `-o APT::Get::List-Cleanup=0`** to the spec's `apt-get update` (fact table).
11. **`--rollback` with no version installs the newest version older than the installed one**, after listing them all.
12. **The repo keeps the newest 10 versions** (`AGENTOS_APT_KEEP`), and `gh-pages` is a single force-pushed commit, so pruned releases leave nothing in the branch's history (Pages' 1 GB cap).
13. **A release's notes come from `docs/releases/<version>.md`.** The release job fails if it is missing. `docs/releases/1.0.0.md` is part of this plan.
14. **The API also returns `running` and `ciActive`** in `GET /api/update`, and adds `GET /api/update/log` (`{running, text}`) for the reconnect. The server re-validates `available` against the version pattern and caps every field. The footer's version comes from `GET /api/update` (`agentos-update --version`, live).
15. **`Depends:` takes over only `mkosi.conf.d/30-desktop.conf` and `40-solenta.conf`** (both deleted), plus the two ABI pins. The rest of the package set stays in mkosi. Verified: the image's package set is unchanged except for `agentos` itself.
16. **`register-mcp --update` owns AgentOS's whole tables.** `[mcp_servers.agentos-ci]` and its sub-tables are rewritten, including anything a user added inside them, and they move to the end of the TOML file. Everything outside them is kept byte for byte.
17. **The signing key is a repository Actions secret, referenced only in the release job's tag-only publish step.** It is not an Environment secret: the release job also runs for the weekly schedule, and an Environment with a tag-only rule would block it.

## File map

```
package/                                                  NEW  the agentos package tree (git mv of mkosi.extra, minus image-only files)
package/DEBIAN/control                                    NEW  template (Version, Depends, Installed-Size filled in by build-deb.sh)
package/DEBIAN/postinst                                   NEW  execs /usr/local/lib/agentos/configure
package/usr/lib/systemd/system/*                          MOVED from mkosi.extra/etc/systemd/system (units, docker.service.d drop-in)
package/usr/lib/systemd/system/agentos-update-check.{service,timer}  NEW
package/usr/lib/systemd/system-preset/10-agentos.preset   MOD  enable agentos-update-check.timer
package/usr/lib/tmpfiles.d/agentos.conf                   MOD  update lock and log
package/etc/apt/sources.list.d/agentos.sources            NEW  the AgentOS source (placeholder URL until owner step 4)
package/etc/update-motd.d/60-agentos-update               NEW  MOTD line
package/usr/local/bin/agentos-update                      MOD  agentos step, --check/--rollback/--version/--notice/--issue, lock, log
package/usr/local/lib/agentos/configure                   NEW  postinst logic
package/usr/local/lib/agentos/migrations/001-units-to-usr-lib.sh  NEW
package/usr/local/lib/agentos/register-mcp                MOD  --update
package/usr/local/sbin/agentos-firstboot                  MOD  refresh the console notice
mkosi.extra/                                              KEPT image-only: etc/fstab, etc/issue, etc/apt/apt.conf.d/20auto-upgrades,
                                                               etc/systemd/network, etc/cloud, usr/lib/repart.d, home/agent
mkosi.conf.d/30-desktop.conf, 40-solenta.conf             DEL  (now the package's Depends)
mkosi.conf.d/50-agentos.conf                              NEW  Packages=agentos
mkosi.prepare.chroot                                      MOD  venv, act, bridge and web build move to build-deb.sh
mkosi.finalize.chroot                                     MOD  package invariants
tools/build-deb.sh                                        NEW  builds mkosi.packages/agentos_<V>_amd64.deb in debian:trixie
tools/apt-publish.sh                                      NEW  adds a .deb to the gh-pages apt repo and signs it
web/server/src/update.ts                                  NEW  GET /api/update, POST /api/update/check, GET /api/update/log
web/server/src/{actions,app}.ts, test/helpers.ts          MOD
web/server/test/update.test.ts                            NEW
web/ui/src/components/UpdateCard.tsx                      NEW  System > Updates
web/ui/src/{App,pages/System,pages/Overview,types}.tsx|ts, style.css  MOD
web/ui/test/System.test.tsx (rewritten), Overview.test.tsx (new)
test/configure_test.sh, register_mcp_test.sh, update_check_test.sh, apt_publish_test.sh  NEW  bash unit tests
test/checks/99-update.sh                                  NEW  in-VM checks
test/web_ws.mjs                                           MOD  update mode
test/{env,wrapper,solenta_pair,web_serve}_test.sh, test/computer_test.py, test/ci/conftest.py  MOD  path mkosi.extra -> package
.github/workflows/build.yml                               MOD  paths, version, build-deb, tests, deb artifact, apt publish
.gitignore                                                MOD  mkosi.packages/
docs/updates.md, docs/releases/1.0.0.md                   NEW
```

## Working locally

- **The package** is built on devvm (Docker): `.superpowers/sdd/devvm.sh sh 'AGENTOS_DEV=1 tools/build-deb.sh'` (about 4.5 minutes). `mkosi build` and `99-update.sh` need it in `mkosi.packages/`, which exists on devvm only, and `devvm.sh` rsyncs with `--delete`: **every `devvm.sh sh`/`run` deletes it**. Either chain everything in one job (`AGENTOS_DEV=1 tools/build-deb.sh && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh …`), or add `--exclude mkosi.packages` to `sync_tree` in your local, untracked `.superpowers/sdd/devvm.sh`. There is no `.git` on devvm, so a devvm build's version is `0.0.0~git<date>.local`.
- **Bash unit tests** run on devvm (`dpkg`, `apt-ftparchive`, `gpg`, `jq` and `flock` are there): `.superpowers/sdd/devvm.sh sh 'test/<name>_test.sh'`. They run as root there and unprivileged in CI; none of them touches the host's apt, systemd or `/var/lib`.
- **Python tests** on the Mac: `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci` (venv as in Plan 5).
- **Web tests** on the Mac: `npx tsc -p tsconfig.json --noEmit && npx vitest run` in `web/server`; `npx tsc -p tsconfig.json --noEmit && npx vitest run && npm run build` in `web/ui`.
- **shellcheck** runs on devvm.
- **A faster VM loop for one check file** (optional, Task 7): copy `test/smoke.sh`, `test/web_ws.mjs` and the check files you want into `test-upd/` (with `test-upd/checks/00-helpers.sh` holding `WEB`, `web_users` and `CI_REPO`, copied from `96-web.sh` and `98-ci.sh`), then run `TMPDIR=/var/tmp test-upd/smoke.sh mkosi.output/agentos.raw uefi`. `smoke.sh` runs every `check_*` it sources; `99-update.sh` finds the package through `$HERE/../mkosi.packages`. Don't commit `test-upd/`.

---
### Task 1: The `agentos` package: layout, build script, and the image installs it

**Files:**
- Move: `mkosi.extra/` → `package/` (all of it), then back to `mkosi.extra/`: `etc/fstab`, `etc/issue`, `etc/apt/apt.conf.d/20auto-upgrades`, `etc/systemd/network/`, `etc/cloud/`, `usr/lib/repart.d/`, `home/`; and `package/etc/systemd/system/*.{service,timer,path}` and `docker.service.d/` → `package/usr/lib/systemd/system/`
- Create: `tools/build-deb.sh` (mode 755), `package/DEBIAN/control`, `package/etc/apt/sources.list.d/agentos.sources`, `mkosi.conf.d/50-agentos.conf`, `test/checks/99-update.sh`
- Delete: `mkosi.conf.d/30-desktop.conf`, `mkosi.conf.d/40-solenta.conf`
- Modify: `mkosi.prepare.chroot` (drop lines 45–87), `mkosi.finalize.chroot`, `.gitignore`, `.github/workflows/build.yml`, and the path in `test/{env,wrapper,solenta_pair,web_serve}_test.sh`, `test/computer_test.py`, `test/ci/conftest.py`, `installer/mkosi.extra/usr/lib/agentos-installer/lib.sh` (a comment)

**Interfaces:**
- Consumes: the repo's `apt/` (NodeSource source and key), `tools/solenta-bridge`, `web/`.
- Produces:
  - `tools/build-deb.sh` → `mkosi.packages/agentos_<V>_amd64.deb`. Env: `AGENTOS_VERSION` (default: the `v*` tag on HEAD, else `0.0.0~git<YYYYMMDD>.<sha8|local>`), `AGENTOS_DEV=1` (required while `agentos.sources` has the placeholder URL or `package/usr/share/keyrings/agentos-archive.gpg` is missing; then the shipped source has `Enabled: no`).
  - In the package: `/usr/local/lib/agentos/units.new` (the package's `agentos-*.{service,timer,path}` units, no templates, one per line), `DEBIAN/conffiles` (every file under `/etc`).
  - `package/` is the package tree; later tasks add files there. `mkosi.extra/` holds only image-only files.

- [ ] **Step 1: Write the failing checks**

`test/checks/99-update.sh` (Task 7 extends this file and replaces this function):
```bash
# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

check_agentos_package_installed() {  # sorts before check_agentos_update and check_update_*
  # The image carries the .deb this build made, untouched, and no unit files in the old place.
  local want; want=$(dpkg-deb -f "$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb)" Version) || return 1
  vm 'test "$(dpkg-query -W -f "\${Version}" agentos)" = "'"$want"'" && test -z "$(sudo dpkg -V agentos)" &&
      test -z "$(find /etc/systemd/system -maxdepth 1 -name "agentos-*" -print -quit)" &&
      test ! -e /etc/systemd/system/docker.service.d/10-agentos.conf'
}
```

In `mkosi.finalize.chroot`, find:
```bash
chmod 0440 /etc/sudoers.d/agent
chown -R agent:agent /home/agent/.config/xfce4
```
Replace with (the package ships the file as 0440 now):
```bash
chown -R agent:agent /home/agent/.config/xfce4
```
Then find:
```bash
W=/usr/local/lib/agentos/web
for f in "$W/server/dist/main.js"
```
Replace with:
```bash
# AgentOS comes from the agentos package (tools/build-deb.sh): installed, untouched, and the only
# source of AgentOS's units (in /usr/lib/systemd/system, never /etc, so updates never prompt).
[ "$(dpkg-query -W -f '${Status}' agentos 2>/dev/null)" = "install ok installed" ] || fail "agentos package not installed"
if [ -n "$(dpkg -V agentos)" ]; then fail "files differ from the agentos package: $(dpkg -V agentos | tr '\n' ' ')"; fi
if compgen -G '/etc/systemd/system/agentos-*' >/dev/null || [ -e /etc/systemd/system/docker.service.d/10-agentos.conf ]; then
  fail "AgentOS unit files under /etc/systemd/system: they belong in the package (/usr/lib/systemd/system)"
fi
# A directory the package shares keeps its owner's metadata: dpkg leaves an existing directory
# alone, and apt unpacks polkitd (a dependency) first.
[ "$(stat -c '%a %U:%G' /etc/polkit-1/rules.d)" = "750 root:polkitd" ] || fail "/etc/polkit-1/rules.d: $(stat -c '%a %U:%G' /etc/polkit-1/rules.d)"
[ "$(stat -c %a /etc/sudoers.d/agent)" = 440 ] || fail "/etc/sudoers.d/agent is not 0440"

W=/usr/local/lib/agentos/web
for f in "$W/server/dist/main.js"
```

- [ ] **Step 2: Run the build to see it fail**

Run: `.superpowers/sdd/devvm.sh sh 'AGENTOS_DEV=1 tools/build-deb.sh'`
Expected: `bash: line 1: tools/build-deb.sh: No such file or directory`, exit 127.

- [ ] **Step 3: Move the tree**

```bash
git mv mkosi.extra package
mkdir -p mkosi.extra/etc/systemd mkosi.extra/etc/apt/apt.conf.d mkosi.extra/usr/lib package/usr/lib/systemd/system
git mv package/etc/fstab mkosi.extra/etc/fstab
git mv package/etc/issue mkosi.extra/etc/issue                     # owned by base-files
git mv package/etc/apt/apt.conf.d/20auto-upgrades mkosi.extra/etc/apt/apt.conf.d/20auto-upgrades   # ucf, unattended-upgrades
git mv package/etc/systemd/network mkosi.extra/etc/systemd/network
git mv package/etc/cloud mkosi.extra/etc/cloud
git mv package/usr/lib/repart.d mkosi.extra/usr/lib/repart.d
git mv package/home mkosi.extra/home
for f in package/etc/systemd/system/*.service package/etc/systemd/system/*.timer package/etc/systemd/system/*.path; do
  git mv "$f" package/usr/lib/systemd/system/
done
git mv package/etc/systemd/system/docker.service.d package/usr/lib/systemd/system/docker.service.d
rmdir package/etc/systemd/system package/etc/systemd
perl -pi -e 's#(?<!installer/)mkosi\.extra/(usr/local|etc/profile\.d)#package/$1#g; s#"mkosi\.extra", "usr"#"package", "usr"#' \
  .github/workflows/build.yml test/env_test.sh test/wrapper_test.sh test/solenta_pair_test.sh test/web_serve_test.sh \
  test/computer_test.py test/ci/conftest.py installer/mkosi.extra/usr/lib/agentos-installer/lib.sh
printf 'mkosi.packages/\n' >> .gitignore
git rm -q mkosi.conf.d/30-desktop.conf mkosi.conf.d/40-solenta.conf
```
Check: `git status --short | grep -v '^R ' ` lists only the two deletions, `.gitignore`, and the eight files the `perl` line changed. `grep -rn 'mkosi\.extra' test .github tools | grep -v installer/mkosi.extra` prints nothing. No unit, test or doc outside `docs/superpowers/` refers to `/etc/systemd/system/agentos-*`; the `getty@tty1` drop-in that `70-config.sh` and `agentos-console-apply` use is runtime local config and stays in `/etc`.

- [ ] **Step 4: The build script, the control template, the source, the mkosi wiring**

`tools/build-deb.sh`:
```bash
#!/bin/bash
# Build the agentos .deb into mkosi.packages/, where mkosi finds it (a local repository) and installs
# it into the image (mkosi.conf.d/50-agentos.conf). Release builds publish the same file to the apt repo.
#   tools/build-deb.sh                     version: the v* tag on HEAD, else 0.0.0~git<date>.<sha>
#   AGENTOS_VERSION=1.4.0 tools/build-deb.sh
#   AGENTOS_DEV=1 tools/build-deb.sh       allowed while the repo URL or the signing key is not set
#                                          yet: the AgentOS apt source ships disabled (Enabled: no)
# The tree is package/ plus what is built here: the Python venv, the web UI, act and the bridge. It is
# built in a debian:trixie container, so the venv's Python (3.13) and node-pty's Node ABI (NodeSource
# 24, the image's apt source) match the image.
set -euo pipefail
die() { echo "build-deb: $*" >&2; exit 1; }

# Debian packages AgentOS's own code needs (moved here from mkosi.conf.d, so a release can add one).
# The image's base (kernel, systemd, toolchains, docker, tailscale) stays in mkosi.conf.d.
DEPENDS=(
  # The venv in /usr/local/lib/agentos/venv is built against this exact Python.
  python3.13
  # node-pty in the web UI is compiled for this Node major.
  'nodejs (>= 24~)' 'nodejs (<< 25~)'
  # Desktops and computer use (was mkosi.conf.d/30-desktop.conf).
  tigervnc-standalone-server xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfce4-terminal
  xfconf dbus-x11 adwaita-icon-theme xdotool scrot xclip chromium fonts-dejavu fonts-noto-color-emoji
  novnc websockify polkitd
  # Electron runtime libraries for Solenta's Linux build (was mkosi.conf.d/40-solenta.conf). Solenta's
  # Remote Connections installs it over SSH and checks it with ldd. Trixie names (t64 ABI renames).
  libnss3 libnspr4 libgtk-3-0t64 libgbm1 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64
  libatspi2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libxfixes3
  libpango-1.0-0 libcairo2 libdbus-1-3 libexpat1 libxext6 libx11-6 libxcb1 libglib2.0-0t64
)

# act runs .github/workflows for agentos-ci. Pinned by version and sha256 (the release's
# checksums.txt); Docker pulls its runner images on first use, they are never baked in.
ACT_VERSION=0.2.89
ACT_SHA256=0191d6f1f3b716b5c55820032605d05fc3c1cdbf581ebeff655019e5dd1524c0

inside() {  # runs in the container: /src (the repo, read-only) -> /out/agentos_<version>_amd64.deb
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  install -d /etc/apt/keyrings
  cp /src/apt/keyrings/nodesource.gpg /etc/apt/keyrings/
  cp /src/apt/sources.list.d/nodesource.sources /etc/apt/sources.list.d/
  apt-get update -qq --error-on=any
  apt-get install -y -qq --no-install-recommends nodejs python3 python3-venv build-essential curl >/dev/null
  node -e 'process.exit(process.versions.node.startsWith("24.") ? 0 : 1)' || { echo "build-deb: Node $(node --version) is not 24.x" >&2; exit 1; }

  local S=/build/root W wb at
  mkdir -p /build
  cp -a /src/package "$S"

  # agentos-computer and agentos-ci deps, isolated from the system and the agent's own Python. Built
  # at its final path: a venv is not relocatable.
  python3 -m venv /usr/local/lib/agentos/venv
  /usr/local/lib/agentos/venv/bin/pip install -q --no-cache-dir --disable-pip-version-check 'mcp>=1.28,<2' 'pillow>=10' 'pyyaml>=6,<7'
  cp -a /usr/local/lib/agentos/venv "$S/usr/local/lib/agentos/venv"

  at=$(mktemp -d)
  curl -fsSL -o "$at/act.tgz" "https://github.com/nektos/act/releases/download/v$ACT_VERSION/act_Linux_x86_64.tar.gz"
  echo "$ACT_SHA256  $at/act.tgz" | sha256sum -c --quiet -
  tar -xzf "$at/act.tgz" -C "$at" act
  install -D -m 755 "$at/act" "$S/usr/local/bin/act"

  # The Mac-side Solenta bridge (Mode B), served for download by the web UI's Solenta card.
  install -D -m 755 /src/tools/solenta-bridge "$S/usr/local/share/agentos/solenta-bridge"

  # The web UI: only the build output and production node_modules ship. node-pty compiles against
  # this Node with node-gyp. Host node_modules/dist are excluded: a macOS checkout must not leak
  # darwin binaries into the package.
  W=$S/usr/local/lib/agentos/web
  wb=$(mktemp -d)
  tar -C /src/web --exclude=node_modules --exclude=dist -cf - . | tar -C "$wb" -xf -
  # One command per line: set -e ignores a failure anywhere in an && chain except its last command.
  (
    cd "$wb/ui"
    npm ci --no-audit --no-fund
    npm run build
    cd "$wb/server"
    npm ci --no-audit --no-fund
    npm run build
    npm prune --omit=dev --no-audit --no-fund
    # node-pty also ships Windows/macOS prebuilds and its C++ sources; Linux loads build/Release only.
    rm -rf node_modules/node-pty/prebuilds node_modules/node-pty/third_party node_modules/node-pty/deps node_modules/node-pty/src
  )
  install -d "$W/server"
  cp -a "$wb/server/dist" "$wb/server/node_modules" "$wb/server/package.json" "$W/server/"
  cp -a "$wb/ui/dist" "$W/ui"

  # The package's units, for postinst's "new units" step (templates can't be enabled by name).
  (cd "$S/usr/lib/systemd/system" && ls agentos-*.service agentos-*.timer agentos-*.path) | grep -v @ > "$S/usr/local/lib/agentos/units.new"

  if [ "$AGENTOS_DEV_SOURCE" = 1 ]; then
    sed -i 's/^Types: deb$/# Development build: no repo URL or signing key yet (tools\/build-deb.sh, AGENTOS_DEV=1).\nEnabled: no\nTypes: deb/' \
      "$S/etc/apt/sources.list.d/agentos.sources"
  fi
  chmod 0440 "$S/etc/sudoers.d/agent"
  # Everything in /etc is a conffile: a local edit is kept on upgrade (the new file lands as .dpkg-dist).
  (cd "$S" && find etc -type f | sort | sed 's|^|/|') > "$S/DEBIAN/conffiles"
  local deps size
  deps=$(printf '%s, ' "${DEPENDS[@]}"); deps=${deps%, }
  size=$(du -sk --exclude=DEBIAN "$S" | cut -f1)
  sed -i -e "s/^Version: .*/Version: $AGENTOS_VERSION/" -e "s/^Depends: .*/Depends: $deps/" \
    -e "s/^Installed-Size: .*/Installed-Size: $size/" "$S/DEBIAN/control"
  dpkg-deb --root-owner-group -b "$S" "/out/agentos_${AGENTOS_VERSION}_amd64.deb" >/dev/null
  chown "$OWNER_UID:$OWNER_GID" "/out/agentos_${AGENTOS_VERSION}_amd64.deb"
}

if [ "${1:-}" = --inside ]; then inside; exit 0; fi

cd "$(dirname "$0")/.."
SRC=package/etc/apt/sources.list.d/agentos.sources
KEY=package/usr/share/keyrings/agentos-archive.gpg
dev=0
if grep -q '^URIs: https://OWNER\.github\.io/REPO/apt$' "$SRC" || [ ! -s "$KEY" ]; then
  [ "${AGENTOS_DEV:-0}" = 1 ] || die "the AgentOS apt repo is not set up yet: set its URL in $SRC and commit its public key as $KEY (docs/updates.md, owner steps), or build with AGENTOS_DEV=1 for a development image whose AgentOS update source is disabled"
  dev=1
fi
V=${AGENTOS_VERSION:-}
if [ -z "$V" ]; then
  tag=$(git describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || true)
  if [ -n "$tag" ]; then V=${tag#v}
  else V="0.0.0~git$(date -u +%Y%m%d).$(git rev-parse --short=8 HEAD 2>/dev/null || echo local)"; fi
fi
[[ $V =~ ^[0-9][A-Za-z0-9.+~]*$ ]] || die "not a usable package version: $V"
mkdir -p mkosi.packages
rm -f mkosi.packages/agentos_*.deb
docker run --rm -e AGENTOS_VERSION="$V" -e AGENTOS_DEV_SOURCE="$dev" -e OWNER_UID="$(id -u)" -e OWNER_GID="$(id -g)" \
  -v "$PWD:/src:ro" -v "$PWD/mkosi.packages:/out" debian:trixie bash /src/tools/build-deb.sh --inside
echo "mkosi.packages/agentos_${V}_amd64.deb"
```

`package/DEBIAN/control`:
```
Package: agentos
Version: 0
Architecture: amd64
Maintainer: AgentOS <root@localhost>
Installed-Size: 0
Depends: filled in by tools/build-deb.sh
Section: admin
Priority: optional
Description: AgentOS: the box's own scripts, units, web UI, CI and MCP servers
 Everything AgentOS installs itself, outside Debian packages and the agent's
 home: /usr/local/{bin,sbin,lib/agentos,share/agentos}, the systemd units and
 preset, and AgentOS's files in /etc. Updated with agentos-update.
```

`package/etc/apt/sources.list.d/agentos.sources` (the placeholder is owner step 4; `build-deb.sh` fails closed on it):
```
# AgentOS releases, for agentos-update. Only the AgentOS key (Signed-By) may sign this source, and
# that key is trusted for nothing else. The URL is set once by the repo owner (docs/updates.md).
Types: deb
URIs: https://OWNER.github.io/REPO/apt
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/agentos-archive.gpg
```

`mkosi.conf.d/50-agentos.conf`:
```
# AgentOS itself: the agentos .deb that tools/build-deb.sh puts in mkosi.packages/ (mkosi turns that
# directory into a local repository on its own). Build it first: AGENTOS_DEV=1 tools/build-deb.sh.
# Its Depends bring the desktop stack and Solenta's Electron libraries (they used to be listed here).
[Content]
Packages=agentos
```

`mkosi.prepare.chroot`: delete everything after the XFCE panel lines, from `# agentos-computer and agentos-ci deps, isolated from the system and the agent's own Python.` (line 45) to the end of the file (`rm -rf "$wb"`, line 87). The venv, `act`, the bridge and the web build now come from the package. The file ends with:
```bash
# XFCE: ship the default panel config so the first start shows no "Panel: use default config?" dialog.
install -d -o agent -g agent /home/agent/.config/xfce4/xfconf/xfce-perchannel-xml
install -o agent -g agent -m 644 /etc/xdg/xfce4/panel/default.xml \
  /home/agent/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
```

```bash
chmod 755 tools/build-deb.sh
```

- [ ] **Step 5: CI builds the package before the image**

In `.github/workflows/build.yml`, find (it moves up, and gains the package version):
```yaml
      - name: Version
        id: ver
        run: |
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then echo "v=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          else echo "v=$(date -u +%Y.%m.%d)" >> "$GITHUB_OUTPUT"; fi

      - name: Convert
```
Replace with:
```yaml
      - name: Convert
```
Then find:
```yaml
      - name: Build image
        run: mkosi -f build
```
Replace with:
```yaml
      - name: Version
        id: ver
        run: |
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then echo "v=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"; echo "deb=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          else echo "v=$(date -u +%Y.%m.%d)" >> "$GITHUB_OUTPUT"; echo "deb=0.0.0~git$(date -u +%Y%m%d).${GITHUB_SHA::8}" >> "$GITHUB_OUTPUT"; fi

      # A tag must build a release package (repo URL and signing key set, tools/build-deb.sh fails
      # otherwise); every other build may be a development build with the AgentOS source disabled.
      - name: Build the agentos package
        env:
          AGENTOS_VERSION: ${{ steps.ver.outputs.deb }}
          AGENTOS_DEV: ${{ startsWith(github.ref, 'refs/tags/v') && '0' || '1' }}
        run: tools/build-deb.sh

      - name: Build image
        run: mkosi -f build
```
(`tools/*.sh` in the lint step already covers `build-deb.sh`; the `perl` line in Step 3 moved the `mkosi.extra/…` paths there to `package/…`.)

- [ ] **Step 6: Run the unit tests, shellcheck, and the build without `AGENTOS_DEV`**

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning tools/build-deb.sh mkosi.prepare.chroot mkosi.finalize.chroot test/checks/99-update.sh && test/env_test.sh && test/wrapper_test.sh && test/solenta_pair_test.sh && test/web_serve_test.sh && python3 test/computer_test.py && echo UNIT-OK; tools/build-deb.sh; echo rc=$?'`
Expected:
```
env.sh OK
profile.d OK
validate_setting OK
wrapper OK
solenta-pair OK
web-serve OK
core OK
UNIT-OK
build-deb: the AgentOS apt repo is not set up yet: set its URL in package/etc/apt/sources.list.d/agentos.sources and commit its public key as package/usr/share/keyrings/agentos-archive.gpg (docs/updates.md, owner steps), or build with AGENTOS_DEV=1 for a development image whose AgentOS update source is disabled
rc=1
```
And on the Mac: `/tmp/agentos-ci-venv/bin/python -m pytest -q test/ci` → `70 passed`.

- [ ] **Step 7: Build the package and the image; compare the package set; run the smoke test**

Save the previous manifest first (the build overwrites it): `.superpowers/sdd/devvm.sh sh 'cp mkosi.output/agentos.manifest /var/tmp/agentos.manifest.before'`.

Run: `.superpowers/sdd/devvm.sh run 'AGENTOS_DEV=1 tools/build-deb.sh && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed'`, then `.superpowers/sdd/devvm.sh wait <JOB>` until it isn't 124.
Expected in the log: `mkosi.packages/agentos_0.0.0~git<date>.local_amd64.deb`, then mkosi's `Rebuilding local package repository`, `Unpacking polkitd …` before `Unpacking agentos (0.0.0~git<date>.local)`, `image invariants OK`, every earlier check passing, plus:
```
PASS [uefi] check_agentos_package_installed
PASS [bios] check_agentos_package_installed
ALL CHECKS PASSED (N skipped)
```
Then compare the package sets:
```bash
.superpowers/sdd/devvm.sh sh 'python3 -c "
import json
names = lambda p: {x[\"name\"] for x in json.load(open(p))[\"packages\"]}
a, b = names(\"/var/tmp/agentos.manifest.before\"), names(\"mkosi.output/agentos.manifest\")
print(len(a), len(b), sorted(b - a), sorted(a - b))"'
```
Expected: `643 644 ['agentos'] []`. Any other difference means the `Depends:` list doesn't match the two deleted conf files: fix it before committing.

- [ ] **Step 8: Commit**

```bash
git add -A package mkosi.extra mkosi.conf.d mkosi.prepare.chroot mkosi.finalize.chroot tools/build-deb.sh .gitignore \
  .github/workflows/build.yml test installer/mkosi.extra/usr/lib/agentos-installer/lib.sh
git commit -m "feat(package): AgentOS ships as the agentos .deb; the image installs it from mkosi.packages"
```

---

### Task 2: postinst: new units, migrations, restarts, `register-mcp --update`

**Files:**
- Create: `package/DEBIAN/postinst` (mode 755), `package/usr/local/lib/agentos/configure` (mode 755), `package/usr/local/lib/agentos/migrations/001-units-to-usr-lib.sh` (mode 755)
- Modify: `package/usr/local/lib/agentos/register-mcp` (whole file), `.github/workflows/build.yml`
- Test: `test/configure_test.sh`, `test/register_mcp_test.sh` (new, mode 755)

**Interfaces:**
- Consumes: `units.new` (Task 1), the preset file, `register-mcp`.
- Produces:
  - `configure configure [old-version]` (the postinst). State in `/var/lib/agentos/`: `units.seen`, `migrations.done` (file names, one per line). Test overrides: `AGENTOS_LIB`, `AGENTOS_STATE`, `AGENTOS_RUN` (where `systemd/system` marks a running systemd), `AGENTOS_OLD_UNITS`.
  - A migration is `/usr/local/lib/agentos/migrations/NNN-name.sh`, run with `bash` as root, safe to run again.
  - `register-mcp --update`; `AGENTOS_CI` overrides the `agentos-ci` path (tests).
  - Task 4 adds tmpfiles entries that `configure` creates with `systemd-tmpfiles --create`.

- [ ] **Step 1: Write the failing tests**

`test/configure_test.sh`:
```bash
#!/bin/bash
# Unit test for the agentos package's postinst logic (configure): the image-build (chroot) path, new
# units, migrations (order, run once, a failure stops the run and is retried, re-runs), the restarts
# and register-mcp --update. systemctl, systemd-tmpfiles, runuser and id are fakes that log argv.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
C=$R/package/usr/local/lib/agentos/configure
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
L=$d/calls
mkdir -p "$d/bin" "$d/lib/migrations" "$d/state" "$d/run" "$d/old"
for c in systemd-tmpfiles runuser; do printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$c" "$L" > "$d/bin/$c"; done
# systemctl: logs; is-enabled says "disabled" for units whose name contains "off" (as a preset would).
cat > "$d/bin/systemctl" <<EOS
#!/bin/sh
echo "systemctl \$*" >> "$L"
[ "\$1" = is-enabled ] && case "\$3" in *off*) exit 1 ;; esac
exit 0
EOS
printf '#!/bin/sh\n[ "$1" = agent ]\n' > "$d/bin/id"
chmod +x "$d/bin/"*
printf 'agentos-web.service\nagentos-new.timer\nagentos-new-off.service\n' > "$d/lib/units.new"
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

# Live upgrade: agentos-web is known; the two new units get the preset, only the enabled one starts.
mkdir -p "$d/run/systemd/system"
reset; echo agentos-web.service > "$d/state/units.seen"; touch "$d/fail-002-flaky"
if run configure 1.0 >/dev/null 2>&1; then fail "a failing migration must fail the configure"; fi
[ "$(cat "$d/ran")" = 001-first ] || fail "order/stop: $(cat "$d/ran")"
[ "$(cat "$d/state/migrations.done")" = 001-first.sh ] || fail "done after failure"
want="systemctl daemon-reload
systemd-tmpfiles --create /usr/lib/tmpfiles.d/agentos.conf
systemctl preset agentos-new.timer
systemctl is-enabled --quiet agentos-new.timer
systemctl start --no-block agentos-new.timer
systemctl preset agentos-new-off.service
systemctl is-enabled --quiet agentos-new-off.service"
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

# First configure on a box from before the package: units it already had (old place) count as seen.
reset; touch "$d/old/agentos-web.service"; mkdir -p "$d/old/multi-user.target.wants"
run configure >/dev/null
[ "$(cat "$d/state/units.seen")" = $'agentos-web.service\nagentos-new.timer\nagentos-new-off.service' ] || fail "seed: $(cat "$d/state/units.seen")"
! grep -q 'preset agentos-web' "$L" || fail "seed: existing unit got the preset"
echo "configure OK"
```

`test/register_mcp_test.sh`:
```bash
#!/bin/bash
# Unit test for register-mcp: a fresh registration, a plain run leaving existing entries alone, and
# --update rewriting AgentOS's own entries (a changed tool_timeout_sec) while keeping the user's
# entries byte for byte, idempotently. claude and agentos-ci are fakes.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
RM=$R/package/usr/local/lib/agentos/register-mcp
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
h=$d/home; mkdir -p "$h" "$d/bin"
# claude: "mcp get|add|remove" against a "name command" list in $d/claude.
cat > "$d/bin/claude" <<EOS
#!/bin/bash
db=$d/claude; touch "\$db"
case "\$2" in
  get) grep -q "^\$3 " "\$db" ;;
  add) [ "\$3 \$4" = "--scope user" ] && ! grep -q "^\$5 " "\$db" && echo "\$5 \$7" >> "\$db" ;;
  remove) grep -v "^\$5 " "\$db" > "\$db.t" || true; mv "\$db.t" "\$db" ;;
esac
EOS
printf '#!/bin/sh\necho "$*" >> %s/skill\n' "$d" > "$d/bin/agentos-ci"
chmod +x "$d/bin/"*
run() { env -i HOME="$h" PATH="$d/bin:/usr/bin:/bin" AGENTOS_CI="$d/bin/agentos-ci" "$RM" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fresh box: every CLI gets both servers; Codex's agentos-ci has the timeout.
run
[ "$(cat "$d/claude")" = $'agentos-computer /usr/local/bin/agentos-computer\nagentos-ci /usr/local/bin/agentos-ci-mcp' ] || fail "claude fresh"
grep -A2 '^\[mcp_servers\.agentos-ci\]$' "$h/.codex/config.toml" | grep -qx 'tool_timeout_sec = 1900' || fail "codex fresh"
grep -qx '\[mcp\]' "$h/.grok/config.toml" || fail "grok [mcp]"
jq -e '.mcp["agentos-ci"].command == ["/usr/local/bin/agentos-ci-mcp"] and .mcp["agentos-computer"].enabled' "$h/.config/opencode/opencode.json" >/dev/null || fail "opencode fresh"
[ "$(cat "$d/skill")" = install-skill ] || fail "skill"

# A box from an older release: old values in AgentOS's entries, the user's own entries around them.
cat > "$h/.codex/config.toml" <<'T'
model = "gpt-5"

[mcp_servers.mine]
command = "/opt/mine"

[mcp_servers.agentos-ci]
command = "/usr/local/bin/agentos-ci-mcp"
tool_timeout_sec = 1800

[mcp_servers.agentos-ci.env]
OLD = "1"

[mcp_servers.agentos-computer]
command = "/usr/local/bin/agentos-computer"

[profiles.fast]
model = "gpt-5-mini"
T
printf '{"$schema":"x","mcp":{"mine":{"type":"local","command":["/opt/mine"]},"agentos-ci":{"type":"local","command":["/old"],"enabled":false}},"theme":"dark"}\n' > "$h/.config/opencode/opencode.json"
printf 'agentos-ci /old\nmine /opt/mine\n' > "$d/claude"
cp "$h/.codex/config.toml" "$d/codex.before"

# Without --update nothing of ours changes.
run
cmp -s "$h/.codex/config.toml" "$d/codex.before" || fail "plain run changed codex"
grep -qx 'agentos-ci /old' "$d/claude" || fail "plain run changed claude"

# --update rewrites only AgentOS's entries; running it again changes nothing.
run --update
want='model = "gpt-5"

[mcp_servers.mine]
command = "/opt/mine"

[profiles.fast]
model = "gpt-5-mini"

[mcp_servers.agentos-computer]
command = "/usr/local/bin/agentos-computer"

[mcp_servers.agentos-ci]
command = "/usr/local/bin/agentos-ci-mcp"
tool_timeout_sec = 1900'
[ "$(cat "$h/.codex/config.toml")" = "$want" ] || { diff <(echo "$want") "$h/.codex/config.toml"; fail "codex --update"; }
cp "$h/.codex/config.toml" "$d/codex.once"
run --update
cmp -s "$h/.codex/config.toml" "$d/codex.once" || fail "--update not idempotent"
grep -qx 'mine /opt/mine' "$d/claude" && grep -qx 'agentos-ci /usr/local/bin/agentos-ci-mcp' "$d/claude" || fail "claude --update: $(cat "$d/claude")"
jq -e '.mcp.mine.command == ["/opt/mine"] and .theme == "dark" and .mcp["agentos-ci"] == {type: "local", command: ["/usr/local/bin/agentos-ci-mcp"], enabled: true}' \
  "$h/.config/opencode/opencode.json" >/dev/null || fail "opencode --update"
[ "$(grep -c '^\[mcp\]$' "$h/.grok/config.toml")" = 1 ] || fail "grok [mcp] duplicated"
[ "$(wc -l < "$d/skill")" = 4 ] || fail "skill install runs every time"
echo "register-mcp OK"
```

- [ ] **Step 2: Run them to see them fail**

Run: `chmod 755 test/configure_test.sh test/register_mcp_test.sh && .superpowers/sdd/devvm.sh sh 'test/configure_test.sh; test/register_mcp_test.sh'`
Expected: `configure_test.sh: line …: …/package/usr/local/lib/agentos/configure: No such file or directory`, then `register_mcp_test.sh` fails at the first `run`: the current `register-mcp` calls `/usr/local/bin/agentos-ci install-skill`, which devvm doesn't have (`agentos-ci: skill install failed`, exit 1).

- [ ] **Step 3: Write `configure`, the postinst and the first migration**

`package/usr/local/lib/agentos/configure`:
```bash
#!/bin/bash
# The agentos package's postinst (DEBIAN/postinst execs this). On "configure", in order:
#   1. daemon-reload (and tmpfiles, for new entries)
#   2. new units: enabled per the preset, started if enabled; existing units keep the owner's state
#   3. one-time migrations (migrations/NNN-name.sh, each recorded in migrations.done once it succeeds)
#   4. restart AgentOS's services (never agentos-solenta, desktops, tmux sessions or CI runs)
#   5. re-register the MCP servers and the skill for agent (register-mcp --update)
# A failing migration fails the configure, so dpkg reports it and the next update retries it.
# During the image build (mkosi: a chroot, no running systemd, no agent user yet) the image already
# is in this release's state: it only records the units as seen and the migrations as done.
# AGENTOS_LIB, AGENTOS_STATE, AGENTOS_RUN and AGENTOS_OLD_UNITS point the unit tests at scratch dirs.
set -euo pipefail
[ "${1:-}" = configure ] || exit 0
LIB=${AGENTOS_LIB:-/usr/local/lib/agentos}
STATE=${AGENTOS_STATE:-/var/lib/agentos}
RUN=${AGENTOS_RUN:-/run}
OLD_UNITS=${AGENTOS_OLD_UNITS:-/etc/systemd/system}
SERVICES=(agentos-web.service agentos-mcp-http.service agentos-novnc.service agentos-firewall.service)

migrate() {  # migrate [--mark-all]
  local m name done=$STATE/migrations.done
  touch "$done"
  for m in "$LIB"/migrations/[0-9][0-9][0-9]-*.sh; do
    [ -e "$m" ] || continue
    name=${m##*/}
    grep -qxF "$name" "$done" && continue
    if [ "${1:-}" != --mark-all ]; then
      echo "agentos: migration $name"
      bash "$m" || { echo "agentos: migration $name failed; the next update retries it" >&2; return 1; }
    fi
    echo "$name" >> "$done"
  done
}

new_units() {
  local u seen=$STATE/units.seen
  # First configure on a box installed before the package existed: the units it already has (in the
  # old place, /etc/systemd/system) count as seen, so they keep the owner's enabled/disabled state.
  if [ ! -f "$seen" ]; then
    { ls -A "$OLD_UNITS" 2>/dev/null || true; } | grep -xFf "$LIB/units.new" > "$seen" || true
  fi
  while IFS= read -r u; do
    grep -qxF "$u" "$seen" && continue
    systemctl preset "$u"
    if systemctl is-enabled --quiet "$u"; then systemctl start --no-block "$u"; fi
    echo "$u" >> "$seen"
  done < "$LIB/units.new"
}

install -d -m 755 "$STATE"
if [ ! -d "$RUN/systemd/system" ]; then
  cp "$LIB/units.new" "$STATE/units.seen"
  migrate --mark-all
  exit 0
fi

systemctl daemon-reload
systemd-tmpfiles --create /usr/lib/tmpfiles.d/agentos.conf
new_units
migrate
systemctl try-restart "${SERVICES[@]}"
if id agent >/dev/null 2>&1; then
  timeout 120 runuser -u agent -- env -i HOME=/home/agent USER=agent \
    PATH=/home/agent/.local/bin:/home/agent/.cargo/bin:/home/agent/.bun/bin:/home/agent/.opencode/bin:/home/agent/.grok/bin:/usr/local/bin:/usr/bin:/bin \
    "$LIB/register-mcp" --update || echo "agentos: warning: MCP registration or skill install incomplete (agentos-config apply retries it)" >&2
fi
```

`package/DEBIAN/postinst`:
```bash
#!/bin/bash
# The agentos package's postinst: the steps live in /usr/local/lib/agentos/configure (unit-tested).
set -euo pipefail
exec /usr/local/lib/agentos/configure "$@"
```

`package/usr/local/lib/agentos/migrations/001-units-to-usr-lib.sh` (it runs only on a box bootstrapped from an image without the package; on images built with the package it is marked done in the chroot):
```bash
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
```

```bash
chmod 755 package/DEBIAN/postinst package/usr/local/lib/agentos/configure package/usr/local/lib/agentos/migrations/001-units-to-usr-lib.sh
```

- [ ] **Step 4: `register-mcp --update`**

`package/usr/local/lib/agentos/register-mcp` (whole file):
```bash
#!/bin/bash
# Register AgentOS's MCP servers (agentos-computer, agentos-ci) with every agent CLI, and install
# the agentos-ci skill. Idempotent, runs as agent at every boot (from agentos-firstboot), never
# edits other entries. Done at boot, not build time, so no CLI state is baked into the image.
#   register-mcp            add AgentOS's entries that are missing; existing ones are left alone
#   register-mcp --update   also rewrite AgentOS's own entries to this release's values (the
#                           package's postinst runs this after an update)
set -euo pipefail
rc=0
UPDATE=0; [ "${1:-}" = --update ] && UPDATE=1
CI=${AGENTOS_CI:-/usr/local/bin/agentos-ci}   # tests point this at a fake

# Hold one lock for the whole run: a concurrent run (e.g. two boots racing, or a manual re-apply)
# must not interleave writes to the same config files.
LOCKDIR=$HOME/.config/agentos
mkdir -p "$LOCKDIR"
exec 9>"$LOCKDIR/register-mcp.lock"
flock 9

# append_atomically <file> <printf-fmt> [args...]: copy, append to the copy, then mv over the
# original (keeping its mode), so a reader never sees a half-written file.
append_atomically() {
  local f=$1; shift
  f=$(readlink -f "$f")
  local tmp; tmp=$(mktemp "$f.XXXXXX")
  # shellcheck disable=SC2059 # the format string is a fixed caller-supplied literal, not data
  cp -p "$f" "$tmp" && printf "$@" >>"$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# drop_toml_table <file> <name>: rewrite the file without the [mcp_servers.<name>] table (and its
# sub-tables), and without the blank lines just before it, so the re-appended table doesn't grow
# the file. Everything else is kept byte for byte.
drop_toml_table() {
  local f; f=$(readlink -f "$1")
  local tmp; tmp=$(mktemp "$f.XXXXXX")
  # shellcheck disable=SC2016 # awk program, not shell
  awk -v h="[mcp_servers.$2]" -v p="[mcp_servers.$2." '
    /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
    $0 == h || index($0, p) == 1 { skip = 1; blanks = ""; next }
    /^\[/ { skip = 0 }
    !skip { printf "%s%s\n", blanks, $0 }
    { blanks = "" }
    END { if (!skip) printf "%s", blanks }' "$f" > "$tmp" && cp --attributes-only -p "$f" "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# register <name> <command> [codex-extra]: the command takes no arguments (a launcher per server),
# so every CLI's config shape stays the same. codex-extra is one more TOML line for Codex only.
register() {
  local name=$1 cmd=$2 extra=${3:-} f tmp x op='//='
  # Claude Code (user scope, ~/.claude.json)
  if [ "$UPDATE" = 1 ]; then claude mcp remove --scope user "$name" >/dev/null 2>&1 || true; fi
  if ! claude mcp get "$name" >/dev/null 2>&1; then
    claude mcp add --scope user "$name" -- "$cmd" >/dev/null || { echo "claude: registering $name failed" >&2; rc=1; }
  fi
  # Codex and Grok share the TOML shape
  for f in "$HOME/.codex/config.toml" "$HOME/.grok/config.toml"; do
    mkdir -p "$(dirname "$f")"; touch "$f"
    [[ $f == */.codex/* && -n $extra ]] && x="$extra"$'\n' || x=
    if [ "$UPDATE" = 1 ]; then drop_toml_table "$f" "$name" || { echo "$f: updating $name failed" >&2; rc=1; continue; }; fi
    grep -q "^\[mcp_servers\.$name\]" "$f" || append_atomically "$f" '\n[mcp_servers.%s]\ncommand = "%s"\n%s' "$name" "$cmd" "$x"
  done
  # opencode (JSON)
  f=$HOME/.config/opencode/opencode.json
  mkdir -p "$(dirname "$f")"
  [ -s "$f" ] || printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$f"
  tmp=$(mktemp "$f.XXXXXX")
  if [ "$UPDATE" = 1 ]; then op='='; fi
  if jq --arg n "$name" --arg c "$cmd" ".mcp[\$n] $op {type: \"local\", command: [\$c], enabled: true}" "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; echo "opencode: $f is not valid JSON, left untouched" >&2; rc=1
  fi
}

register agentos-computer /usr/local/bin/agentos-computer
# ci_wait blocks until a run ends; Codex cuts an MCP tool call off after 300 s by default.
# 1900 s leaves headroom over ci_wait's own 1800 s default, so ci_wait returns its structured
# "still running" result before Codex cuts the call off.
register agentos-ci /usr/local/bin/agentos-ci-mcp 'tool_timeout_sec = 1900'
grep -q '^\[mcp\]' "$HOME/.grok/config.toml" || append_atomically "$HOME/.grok/config.toml" '\n[mcp]\nmax_output_bytes = 4000000\n'

"$CI" install-skill >/dev/null || { echo "agentos-ci: skill install failed" >&2; rc=1; }
exit "$rc"
```
The skill blocks keep the existing rules: `agentos-ci install-skill` already rewrites a well-formed managed block and keeps a malformed one with a warning (`skill.py`).

- [ ] **Step 5: CI runs the new tests**

In `.github/workflows/build.yml`, find:
```yaml
            package/usr/local/lib/agentos/ci/post-receive tools/solenta-bridge \
            test/wrapper_test.sh test/solenta_pair_test.sh test/bridge_test.sh \
```
Replace with:
```yaml
            package/usr/local/lib/agentos/ci/post-receive tools/solenta-bridge \
            package/usr/local/lib/agentos/configure package/usr/local/lib/agentos/migrations/*.sh package/DEBIAN/postinst \
            test/wrapper_test.sh test/solenta_pair_test.sh test/bridge_test.sh \
            test/configure_test.sh test/register_mcp_test.sh \
```
Find:
```yaml
          test/bridge_test.sh

```
Replace with:
```yaml
          test/bridge_test.sh
          test/configure_test.sh
          test/register_mcp_test.sh

```

- [ ] **Step 6: Run the tests and shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'test/configure_test.sh && test/register_mcp_test.sh && shellcheck -S warning package/usr/local/lib/agentos/configure package/usr/local/lib/agentos/register-mcp package/usr/local/lib/agentos/migrations/*.sh package/DEBIAN/postinst test/configure_test.sh test/register_mcp_test.sh && echo SC-OK'`
Expected:
```
configure OK
register-mcp OK
SC-OK
```

- [ ] **Step 7: The postinst in a chroot, as mkosi runs it**

Build the package and install it into a throwaway trixie container (no running systemd there, like mkosi's chroot):
```bash
.superpowers/sdd/devvm.sh sh 'AGENTOS_DEV=1 tools/build-deb.sh >/dev/null && docker run --rm -v "$PWD:/src:ro" debian:trixie bash -c "
  set -e; export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq; apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
  install -d /etc/apt/keyrings; cp /src/apt/keyrings/nodesource.gpg /etc/apt/keyrings/; cp /src/apt/sources.list.d/nodesource.sources /etc/apt/sources.list.d/
  apt-get update -qq; cp /src/mkosi.packages/agentos_*.deb /tmp/
  apt-get install -y -qq --no-install-recommends /tmp/agentos_*.deb >/dev/null 2>&1
  wc -l < /var/lib/agentos/units.seen; cat /var/lib/agentos/migrations.done; echo dpkg-V=[\$(dpkg -V agentos)]
  stat -c \"%a %U:%G\" /etc/polkit-1/rules.d"'
```
Expected (Task 4 adds two units; until then 10):
```
10
001-units-to-usr-lib.sh
dpkg-V=[]
750 root:polkitd
```

- [ ] **Step 8: Commit**

```bash
git add package/DEBIAN/postinst package/usr/local/lib/agentos/configure package/usr/local/lib/agentos/migrations \
  package/usr/local/lib/agentos/register-mcp test/configure_test.sh test/register_mcp_test.sh .github/workflows/build.yml
git commit -m "feat(package): postinst enables new units, runs one-time migrations, restarts services, re-registers MCP"
```

---
### Task 3: Publishing: the signed apt repo on `gh-pages`

**Files:**
- Create: `tools/apt-publish.sh` (mode 755), `docs/releases/1.0.0.md`
- Modify: `.github/workflows/build.yml`
- Test: `test/apt_publish_test.sh` (new, mode 755)

**Interfaces:**
- Consumes: a release `.deb` from `tools/build-deb.sh` (Task 1), with `/etc/apt/sources.list.d/agentos.sources` and `/usr/share/keyrings/agentos-archive.gpg` inside.
- Produces:
  - `tools/apt-publish.sh <deb> <notes.md> <site>`: signs with the only secret key in `$GNUPGHOME`; `AGENTOS_APT_KEEP` (default 10).
  - The repo layout under `https://<owner>.github.io/<repo>/apt/`: `dists/stable/{InRelease,Release,Release.gpg}`, `dists/stable/main/binary-amd64/Packages{,.gz}`, `pool/main/a/agentos/agentos_<V>_amd64.deb`, `notes/<V>.md`, `latest.json`, `agentos-archive.gpg`. Task 4's `--check` reads `<URIs>/notes/<V>.md`.
  - The workflow artifact `deb` (tags only) and the release job's publish step.

- [ ] **Step 1: Write the failing test**

`test/apt_publish_test.sh`:
```bash
#!/bin/bash
# Unit test for tools/apt-publish.sh with a throwaway signing key and stand-in agentos packages:
# signed InRelease and Release.gpg, every kept version listed, notes and latest.json, pruning to
# AGENTOS_APT_KEEP, and the refusals (development build, foreign keyring, missing notes).
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
export GNUPGHOME=$d/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg -q --batch --passphrase '' --quick-gen-key 'AgentOS test <test@invalid>' ed25519 sign never 2>/dev/null
gpg -q --batch --export > "$d/key.gpg"
G2=$d/other; mkdir -m 700 "$G2"
GNUPGHOME=$G2 gpg -q --batch --passphrase '' --quick-gen-key 'Other <o@invalid>' ed25519 sign never 2>/dev/null
GNUPGHOME=$G2 gpg -q --batch --export > "$d/other.gpg"
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdeb() {  # mkdeb VERSION [KEYRING] [extra sources line]
  local t=$d/pkg-$1
  mkdir -p "$t/DEBIAN" "$t/etc/apt/sources.list.d" "$t/usr/share/keyrings"
  printf 'Package: agentos\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@t>\nDescription: t\n' "$1" > "$t/DEBIAN/control"
  printf '%sTypes: deb\nURIs: https://o.github.io/agentos/apt\nSuites: stable\nComponents: main\n' "${3:-}" > "$t/etc/apt/sources.list.d/agentos.sources"
  cp "${2:-$d/key.gpg}" "$t/usr/share/keyrings/agentos-archive.gpg"
  dpkg-deb --root-owner-group -b "$t" "$d/agentos_$1_amd64.deb" >/dev/null
}
echo "What's new" > "$d/notes.md"
pub() { AGENTOS_APT_KEEP=3 "$R/tools/apt-publish.sh" "$d/agentos_$1_amd64.deb" "$d/notes.md" "$d/site" >/dev/null; }
A=$d/site/apt

for v in 1.0.0 1.1.0; do mkdeb $v; pub $v; done
gpgv -q --keyring "$d/key.gpg" "$A/dists/stable/InRelease" 2>/dev/null || fail "InRelease signature"
gpgv -q --keyring "$d/key.gpg" "$A/dists/stable/Release.gpg" "$A/dists/stable/Release" 2>/dev/null || fail "Release.gpg signature"
! gpgv -q --keyring "$d/other.gpg" "$A/dists/stable/InRelease" 2>/dev/null || fail "verified with the wrong key"
[ "$(grep '^Version:' "$A/dists/stable/main/binary-amd64/Packages" | sort | tr '\n' ' ')" = 'Version: 1.0.0 Version: 1.1.0 ' ] || fail "Packages lists both versions"
grep -qx 'Origin: AgentOS' "$A/dists/stable/Release" && grep -qx 'Suite: stable' "$A/dists/stable/Release" || fail "Release fields"
sha=$(sha256sum "$A/dists/stable/main/binary-amd64/Packages" | cut -d' ' -f1)
grep -q " $sha .* main/binary-amd64/Packages$" "$A/dists/stable/Release" || fail "Release hash of Packages"
cmp -s "$A/agentos-archive.gpg" "$d/key.gpg" || fail "public key export"
[ "$(cat "$A/notes/1.1.0.md")" = "What's new" ] || fail "notes"
jq -e '.version == "1.1.0" and .notes_url == "https://o.github.io/agentos/apt/notes/1.1.0.md" and (.published | test("Z$"))' "$A/latest.json" >/dev/null || fail "latest.json"
[ -e "$d/site/.nojekyll" ] || fail ".nojekyll"

# Pruning: with KEEP=3, publishing 1.2.0, 1.10.0 drops 1.0.0 (and its notes); 1.10.0 sorts last.
for v in 1.2.0 1.10.0; do mkdeb $v; pub $v; done
[ "$(ls "$A/pool/main/a/agentos" | sort -V | tr '\n' ' ')" = 'agentos_1.1.0_amd64.deb agentos_1.2.0_amd64.deb agentos_1.10.0_amd64.deb ' ] || fail "prune: $(ls "$A/pool/main/a/agentos")"
[ ! -e "$A/notes/1.0.0.md" ] && [ "$(jq -r .version "$A/latest.json")" = 1.10.0 ] || fail "prune notes / latest"

# Refusals: nothing changes.
cp "$A/dists/stable/InRelease" "$d/before"
mkdeb 2.0.0 "$d/key.gpg" $'Enabled: no\n'; pub 2.0.0 2>/dev/null && fail "published a development build"
mkdeb 2.0.1 "$d/other.gpg"; pub 2.0.1 2>/dev/null && fail "published with a foreign keyring"
mkdeb 2.0.2; AGENTOS_APT_KEEP=3 "$R/tools/apt-publish.sh" "$d/agentos_2.0.2_amd64.deb" "$d/none.md" "$d/site" 2>/dev/null && fail "published without notes"
cmp -s "$A/dists/stable/InRelease" "$d/before" && [ ! -e "$A/pool/main/a/agentos/agentos_2.0.0_amd64.deb" ] || fail "a refusal changed the repo"
echo "apt-publish OK"
```

- [ ] **Step 2: Run it to see it fail**

Run: `chmod 755 test/apt_publish_test.sh && .superpowers/sdd/devvm.sh sh 'test/apt_publish_test.sh'`
Expected: a non-zero exit; `pub` can't run the missing `tools/apt-publish.sh` (`No such file or directory`).

- [ ] **Step 3: Write the publisher and the first release notes**

`tools/apt-publish.sh`:
```bash
#!/bin/bash
# Add an agentos .deb to the apt repo in SITE/apt (the gh-pages tree) and re-sign it.
#   tools/apt-publish.sh <agentos_V_amd64.deb> <notes.md> <SITE>
# Layout: apt/pool/main/a/agentos/*.deb, apt/dists/stable/{InRelease,Release,Release.gpg},
# apt/dists/stable/main/binary-amd64/Packages{,.gz}, apt/notes/<V>.md, apt/latest.json and
# apt/agentos-archive.gpg (the public key, for the one-time bootstrap of older boxes).
# Signs with the only secret key in $GNUPGHOME. Refuses a development build (source disabled) and a
# package whose keyring is not the signing key: boxes could not verify the next release.
# ponytail: keeps the newest AGENTOS_APT_KEEP (10) versions for rollback; GitHub Pages sites are
# capped at 1 GB and a release is ~26 MB.
set -euo pipefail
die() { echo "apt-publish: $*" >&2; exit 1; }
DEB=$(realpath "${1:?usage: apt-publish.sh <deb> <notes.md> <site>}") NOTES=${2:?} SITE=${3:?}
KEEP=${AGENTOS_APT_KEEP:-10}
A=$SITE/apt P=$SITE/apt/pool/main/a/agentos
V=$(dpkg-deb -f "$DEB" Version)
[ "$(dpkg-deb -f "$DEB" Package)" = agentos ] || die "$DEB is not the agentos package"
[ -s "$NOTES" ] || die "no release notes: $NOTES"

x=$(mktemp -d); trap 'rm -rf "$x"' EXIT
dpkg-deb -x "$DEB" "$x"
s=$x/etc/apt/sources.list.d/agentos.sources
grep -qiE '^Enabled:[[:space:]]*no' "$s" && die "$V is a development build (its AgentOS source is disabled)"
grep -q 'OWNER\.github\.io/REPO' "$s" && die "$V still has the placeholder repo URL"
fpr() { gpg --batch --with-colons "$@" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}'; }
want=$(fpr --list-secret-keys)
[ -n "$want" ] || die "no signing key in GNUPGHOME"
[ "$(fpr --show-keys "$x/usr/share/keyrings/agentos-archive.gpg")" = "$want" ] || die "$V ships a keyring that is not the signing key ($want)"

mkdir -p "$P" "$A/notes" "$A/dists/stable/main/binary-amd64"
cp "$DEB" "$P/agentos_${V}_amd64.deb"
# Keep the newest $KEEP versions (sort -V orders Debian versions like 1.10.0 > 1.9.0 and ~ first).
mapfile -t old < <(ls "$P" | sed -n 's/^agentos_\(.*\)_amd64\.deb$/\1/p' | sort -V | head -n "-$KEEP")
for o in "${old[@]}"; do rm -f "$P/agentos_${o}_amd64.deb" "$A/notes/$o.md"; done

cp "$NOTES" "$A/notes/$V.md"
(cd "$A" && apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages)
gzip -9nkf "$A/dists/stable/main/binary-amd64/Packages"
apt-ftparchive -o APT::FTPArchive::Release::Origin=AgentOS -o APT::FTPArchive::Release::Label=AgentOS \
  -o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 -o APT::FTPArchive::Release::Components=main \
  release "$A/dists/stable" > "$x/Release"
mv "$x/Release" "$A/dists/stable/Release"
gpg --batch --yes --clearsign -o "$A/dists/stable/InRelease" "$A/dists/stable/Release"
gpg --batch --yes -abs -o "$A/dists/stable/Release.gpg" "$A/dists/stable/Release"
gpg --batch --yes --export -o "$A/agentos-archive.gpg" "$want"
base=$(sed -n 's/^URIs:[[:space:]]*//p' "$s" | head -1); base=${base%/}
latest=$(ls "$P" | sed -n 's/^agentos_\(.*\)_amd64\.deb$/\1/p' | sort -V | tail -1)
jq -n --arg v "$latest" --arg u "$base/notes/$latest.md" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: $v, notes_url: $u, published: $t}' > "$A/latest.json"
touch "$SITE/.nojekyll"   # Pages serves the files as they are, without a Jekyll build
echo "published agentos $V to $A"
```

`docs/releases/1.0.0.md` (the owner may rewrite it before tagging; the release job requires the file):
```
AgentOS 1.0.0

- AgentOS updates itself. agentos-update (or Update on the web UI's System page) installs new AgentOS releases from AgentOS's signed apt repository, then the Debian packages, then the agent CLIs.
- The box checks for a new release once a day and says so on the web UI, the console and at SSH login. Nothing installs on its own.
- agentos-update --rollback goes back to an earlier release.
```

```bash
chmod 755 tools/apt-publish.sh
```

- [ ] **Step 4: The workflow publishes on tags**

In `.github/workflows/build.yml`, find:
```yaml
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils mtools pipx shellcheck zstd tmux jq
```
Replace with (`apt-ftparchive` for `apt_publish_test.sh` and `99-update.sh`):
```yaml
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-image-utils mtools pipx shellcheck zstd tmux jq apt-utils
```
Find:
```yaml
            test/configure_test.sh test/register_mcp_test.sh \
```
Replace with:
```yaml
            test/configure_test.sh test/register_mcp_test.sh test/apt_publish_test.sh \
```
Find:
```yaml
          test/register_mcp_test.sh

```
Replace with:
```yaml
          test/register_mcp_test.sh
          test/apt_publish_test.sh

```
Find:
```yaml
          retention-days: 1
          compression-level: 0   # already compressed
```
Replace with:
```yaml
          retention-days: 1
          compression-level: 0   # already compressed

      - name: Hand the agentos package to the release job
        if: startsWith(github.ref, 'refs/tags/v')
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: deb
          path: mkosi.packages/agentos_*_amd64.deb
          retention-days: 1
          compression-level: 0
```
Find:
```yaml
          gh release upload "$tag" release/* --clobber
```
Replace with:
```yaml
          gh release upload "$tag" release/* --clobber

      # The apt repo on gh-pages (docs/updates.md). Tags only; the signing key is used here and
      # nowhere else. Fails closed: no key, no notes, a development build or a foreign keyring.
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        if: startsWith(github.ref, 'refs/tags/v')
        with:
          persist-credentials: false
          path: src
      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0
        if: startsWith(github.ref, 'refs/tags/v')
        with:
          name: deb
          path: deb
      - name: Publish the package to the apt repo (gh-pages)
        if: startsWith(github.ref, 'refs/tags/v')
        env:
          AGENTOS_APT_KEY: ${{ secrets.AGENTOS_APT_KEY }}
          GH_TOKEN: ${{ github.token }}
          V: ${{ needs.build.outputs.version }}
        run: |
          [ -n "$AGENTOS_APT_KEY" ] || { echo "the AGENTOS_APT_KEY secret is not set (docs/updates.md, owner steps)" >&2; exit 1; }
          notes=src/docs/releases/$V.md
          [ -s "$notes" ] || { echo "write $notes (what's new in $V) and tag again" >&2; exit 1; }
          export GNUPGHOME="$RUNNER_TEMP/gnupg"
          install -d -m 700 "$GNUPGHOME"
          printf '%s\n' "$AGENTOS_APT_KEY" | gpg --batch --quiet --import
          repo="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
          git clone --quiet --depth 1 --branch gh-pages "$repo" site || { git init --quiet -b gh-pages site && git -C site remote add origin "$repo"; }
          src/tools/apt-publish.sh deb/agentos_*_amd64.deb "$notes" site
          # One commit, force-pushed: pruned versions leave nothing behind in the branch's history.
          cd site
          git checkout --quiet --orphan publish
          git add -A
          git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit --quiet -m "apt: agentos $V"
          git push --quiet --force origin publish:gh-pages
```
The build job keeps `contents: read`; the release job already has `contents: write`, and it is still the only job with a write scope and the only one that references `AGENTOS_APT_KEY`. Nothing in this step runs on a pull request or a branch build.

- [ ] **Step 5: Run the test, shellcheck, and parse the workflow**

Run: `.superpowers/sdd/devvm.sh sh 'test/apt_publish_test.sh && shellcheck -S warning tools/apt-publish.sh test/apt_publish_test.sh && echo SC-OK'`
Expected:
```
apt-publish OK
SC-OK
```
Run: `/tmp/agentos-ci-venv/bin/python -c "import yaml; y = yaml.safe_load(open('.github/workflows/build.yml')); print([s.get('name', s.get('uses')) for s in y['jobs']['release']['steps']][-3:])"`
Expected: `['actions/checkout@11d5960a326750d5838078e36cf38b85af677262', 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093', 'Publish the package to the apt repo (gh-pages)']`

- [ ] **Step 6: Commit**

```bash
git add tools/apt-publish.sh test/apt_publish_test.sh docs/releases/1.0.0.md .github/workflows/build.yml
git commit -m "feat(release): publish the agentos package to a signed apt repo on gh-pages on v* tags"
```

---

### Task 4: `agentos-update`: the AgentOS step, `--check`, `--rollback`, `--version`, and the daily timer

**Files:**
- Modify: `package/usr/local/bin/agentos-update` (whole file), `package/usr/lib/systemd/system-preset/10-agentos.preset`, `package/usr/lib/tmpfiles.d/agentos.conf`, `.github/workflows/build.yml`
- Create: `package/usr/lib/systemd/system/agentos-update-check.service`, `package/usr/lib/systemd/system/agentos-update-check.timer`
- Test: `test/update_check_test.sh` (new, mode 755)

**Interfaces:**
- Consumes: the source file (Task 1), the repo layout (Task 3), `agentos-ci list --json`.
- Produces:
  - `agentos-update` (as agent): steps `agentos`, `apt`, `claude`, `codex`, `opencode`, `grok`, `rustup`, `bun`, `playwright`; `skip  agentos (<why>)` on a development build. Lines `ok    <step>`, `FAIL  <step> (see below)`, `== agentos-update … <time>` first and `== done: ok|with failures` last. Exit 1 on any failure, 2 when not `agent`, 3 when another run holds the lock.
  - `agentos-update --check` (root; re-execs with `sudo -n`) writes `/var/lib/agentos/update.json` (0644): `{installed, available, notes_url, notes, checked_at, error}`, prints one summary line (`AgentOS X is available (installed: Y)`, `AgentOS Y is up to date` or `AgentOS update check failed: <cause>`), and refreshes `/run/issue.d/60-agentos-update.issue`.
  - `--rollback [V]` (as agent), `--version`, `--notice` (prints `AgentOS X available: run agentos-update (or use the web UI)` or nothing), `--issue` (root).
  - Lock: `/run/lock/agentos-update.lock` (`flock`; the web server probes it with `flock -n … true`, Task 5). Log: `/var/log/agentos-update.log`, truncated at each run (Task 5 serves its tail).
  - Test overrides: `AGENTOS_STATE` (also skips the `sudo` re-exec), `AGENTOS_SOURCES`, `AGENTOS_ISSUE`, `AGENTOS_UPDATE_LOCK`, `AGENTOS_UPDATE_LOG`.

- [ ] **Step 1: Write the failing test**

`test/update_check_test.sh`:
```bash
#!/bin/bash
# Unit test for agentos-update --check, --notice, --issue and --version: update available (notes cut
# to 4 KB), up to date, a bad signature, no network, a disabled source, a hostile version string,
# and a running update. apt-get, apt-cache, dpkg-query and curl are fakes; dpkg (version compare)
# and jq are real.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=$R/package/usr/local/bin/agentos-update
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/state"
touch "$d/lock"
src=$d/agentos.sources
printf 'Types: deb\nURIs: https://example.github.io/agentos/apt/\nSuites: stable\nComponents: main\nSigned-By: /usr/share/keyrings/agentos-archive.gpg\n' > "$src"
cat > "$d/bin/apt-get" <<EOS
#!/bin/sh
echo "\$*" >> "$d/apt-get.calls"
case "\$(cat "$d/apt")" in
  ok) exit 0 ;;
  badsig) echo "W: An error occurred during the signature verification. The repository is not updated and the previous index files will be used."
          echo "E: Failed to fetch https://example.github.io/agentos/apt/dists/stable/InRelease  Sub-process /usr/bin/sqv returned an error code (1), error message is: Missing key 0123ABCD, which is needed to verify signature."
          echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100 ;;
  nonet)  echo "E: Failed to fetch https://example.github.io/agentos/apt/dists/stable/InRelease  Could not resolve 'example.github.io'"
          echo "E: Some index files failed to download. They have been ignored, or old ones used instead."; exit 100 ;;
esac
EOS
printf '#!/bin/sh\nprintf "agentos:\\n  Installed: 1.0.0\\n  Candidate: %%s\\n" "$(cat %s/cand)"\n' "$d" > "$d/bin/apt-cache"
printf '#!/bin/sh\nprintf 1.0.0\n' > "$d/bin/dpkg-query"
printf '#!/bin/sh\nfor a; do u=$a; done\necho "$u" >> %s/curl.calls\ncat %s/notes\n' "$d" "$d" > "$d/bin/curl"
chmod +x "$d/bin/"*
run() { env PATH="$d/bin:$PATH" AGENTOS_STATE="$d/state" AGENTOS_SOURCES="$src" AGENTOS_ISSUE="$d/issue.d/60-agentos-update.issue" \
          AGENTOS_UPDATE_LOCK="$d/lock" "$U" "$@"; }
j() { jq -r "$1" "$d/state/update.json"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
LINE='AgentOS 1.1.0 available: run agentos-update (or use the web UI)'

# An update is available: notes are fetched for the signed candidate and cut to 4 KB.
echo ok > "$d/apt"; echo 1.1.0 > "$d/cand"; { echo '<b>What is new</b>'; head -c 6000 /dev/zero | tr '\0' x; } > "$d/notes"
out=$(run --check)
[[ $out == "AgentOS 1.1.0 is available (installed: 1.0.0)"* ]] || fail "summary: $out"
[ "$(j '[.installed, .available, .notes_url, .error] | @json')" = '["1.0.0","1.1.0","https://example.github.io/agentos/apt/notes/1.1.0.md",null]' ] || fail "available: $(cat "$d/state/update.json")"
[ "$(j '.notes | length')" = 4096 ] && [ "$(j '.notes' | head -1)" = '<b>What is new</b>' ] || fail "notes"
[[ $(j .checked_at) =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "checked_at"
[ "$(stat -c %a "$d/state/update.json")" = 644 ] || fail "update.json mode"
[ "$(cat "$d/apt-get.calls")" = "update -qq --error-on=any -o Dir::Etc::sourcelist=$src -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0" ] || fail "apt-get args: $(cat "$d/apt-get.calls")"
[ "$(cat "$d/curl.calls")" = https://example.github.io/agentos/apt/notes/1.1.0.md ] || fail "curl url"
[ "$(run --notice)" = "$LINE" ] || fail "notice"
[ "$(cat "$d/issue.d/60-agentos-update.issue")" = "$LINE" ] || fail "issue"
[ "$(run --version)" = 1.0.0 ] || fail "--version"

# Up to date: no notes fetched, the notices go away.
echo 1.0.0 > "$d/cand"; : > "$d/curl.calls"
[ "$(run --check)" = "AgentOS 1.0.0 is up to date" ] || fail "up to date summary"
[ "$(j '[.available, .notes_url, .notes, .error] | @json')" = '[null,null,"",null]' ] || fail "up to date"
[ -z "$(run --notice)" ] && [ ! -e "$d/issue.d/60-agentos-update.issue" ] && [ ! -s "$d/curl.calls" ] || fail "up to date notices"

# A bad signature: an error with apt's cause, never "available" (the old lists still say 1.1.0).
echo badsig > "$d/apt"; echo 1.1.0 > "$d/cand"
[[ $(run --check) == "AgentOS update check failed: Failed to fetch"* ]] || fail "badsig summary"
[ "$(j .available)" = null ] && [[ $(j .error) == *"Missing key 0123ABCD, which is needed to verify signature."* ]] || fail "badsig: $(j .error)"
[ -z "$(run --notice)" ] || fail "badsig notice"

# No network.
echo nonet > "$d/apt"
run --check >/dev/null
[ "$(j .available)" = null ] && [[ $(j .error) == *"Could not resolve 'example.github.io'" ]] || fail "nonet: $(j .error)"

# A development build: the source is disabled, apt is not asked.
echo ok > "$d/apt"; : > "$d/apt-get.calls"; sed -i '1i Enabled: no' "$src"
run --check >/dev/null
[ "$(j .error)" = "the AgentOS update source is disabled (development build)" ] && [ ! -s "$d/apt-get.calls" ] || fail "disabled"
sed -i '1d' "$src"

# A candidate that isn't a plain version is never offered (it would reach /run/issue.d and the MOTD).
printf '1.1.0\\e[2J\n' > "$d/cand"; run --check >/dev/null
[ "$(j .available)" = null ] || fail "hostile candidate"
printf '{"available":"9.9\\\\nroot"}' > "$d/state/update.json"
[ -z "$(run --notice)" ] || fail "hostile update.json"

# An update is running (it holds the lock): the check is skipped, update.json untouched.
cp "$d/state/update.json" "$d/before"
( flock 9; run --check 2>"$d/err"; ) 9<"$d/lock"
cmp -s "$d/state/update.json" "$d/before" && grep -qx 'agentos-update is running; check skipped' "$d/err" || fail "lock"
echo "update check OK"
```

- [ ] **Step 2: Run it to see it fail**

Run: `chmod 755 test/update_check_test.sh && .superpowers/sdd/devvm.sh sh 'test/update_check_test.sh'`
Expected: a non-zero exit at the first `run --check`: today's `agentos-update` refuses anyone but `agent` (`run as the agent user`).

- [ ] **Step 3: Write `agentos-update`**

`package/usr/local/bin/agentos-update` (whole file):
```bash
#!/bin/bash
# Update AgentOS itself, the Debian packages, and every agent CLI/toolchain. Manual by design (never
# mid-task): the box checks daily and tells the owner, it never installs AgentOS on its own.
#   agentos-update                 as agent: the agentos package, then apt, then the CLIs and toolchains
#   agentos-update --check         refresh only the AgentOS source and write update.json (root, via sudo)
#   agentos-update --rollback [V]  as agent: list the AgentOS versions in the repo and install V
#                                  (default: the newest one older than the installed one)
#   agentos-update --version       print the installed AgentOS version
#   agentos-update --notice        print "AgentOS X available: ..." when update.json says so (MOTD)
#   agentos-update --issue         refresh the console notice in /run/issue.d from update.json (root)
set -euo pipefail
# Tests point AGENTOS_STATE (and the rest) at scratch paths and run unprivileged, without sudo.
STATE=${AGENTOS_STATE:-/var/lib/agentos}
SOURCES=${AGENTOS_SOURCES:-/etc/apt/sources.list.d/agentos.sources}
ISSUE=${AGENTOS_ISSUE:-/run/issue.d/60-agentos-update.issue}
LOCK=${AGENTOS_UPDATE_LOCK:-/run/lock/agentos-update.lock}
ULOG=${AGENTOS_UPDATE_LOG:-/var/log/agentos-update.log}
VERSION_RE='^[0-9][A-Za-z0-9.+~]*$'
# Refresh only the AgentOS source: List-Cleanup=0 keeps the other sources' lists, and --error-on=any
# makes a bad signature or an unreachable repo an error (plain apt-get update exits 0 on both and
# keeps the old lists).
APT_AGENTOS="-o Dir::Etc::sourcelist=$(printf %q "$SOURCES") -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0"
# A locally edited conffile is kept (the new one is saved as .dpkg-dist): an update never prompts.
APT_CONF="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300"

installed() { dpkg-query -W -f '${Version}' agentos 2>/dev/null || true; }
as_root() { [ "$(id -u)" = 0 ] || [ -n "${AGENTOS_STATE:-}" ] || exec sudo -n "$0" "$@"; }
source_problem() {  # why the AgentOS source can't be used, or nothing
  if [ ! -f "$SOURCES" ]; then echo "no AgentOS update source ($SOURCES is missing)"
  elif grep -qiE '^Enabled:[[:space:]]*no[[:space:]]*$' "$SOURCES"; then echo "the AgentOS update source is disabled (development build)"
  fi
}
notice() {
  local a
  a=$(jq -r '.available // empty' "$STATE/update.json" 2>/dev/null) || return 0
  if [[ $a =~ $VERSION_RE ]]; then printf 'AgentOS %s available: run agentos-update (or use the web UI)\n' "$a"; fi
}
write_issue() {  # agetty shows /run/issue.d/*.issue after /etc/issue (the version can't hold a "\")
  local n; n=$(notice)
  if [ -n "$n" ]; then install -d "$(dirname "$ISSUE")"; printf '%s\n\n' "$n" > "$ISSUE"; else rm -f "$ISSUE"; fi
}

check() {
  local inst cand avail="" err out base notes="" tmp
  exec 9<"$LOCK"
  flock -n 9 || { echo "agentos-update is running; check skipped" >&2; return 0; }
  inst=$(installed)
  err=$(source_problem)
  [ -n "$err" ] || [ -n "$inst" ] || err="the agentos package is not installed"
  if [ -z "$err" ]; then
    # shellcheck disable=SC2086 # APT_AGENTOS is a list of words
    if out=$(apt-get update -qq --error-on=any $APT_AGENTOS 2>&1); then
      cand=$(apt-cache policy agentos | sed -n 's/^ *Candidate: //p')
      if [[ $cand =~ $VERSION_RE ]] && dpkg --compare-versions "$cand" gt "$inst"; then avail=$cand; fi
    else
      err=$(printf '%s\n' "$out" | sed -n 's/^E: //p' | head -1 | cut -c1-300)
      err=${err:-apt-get update failed}
    fi
  fi
  base=$(sed -n 's/^URIs:[[:space:]]*//p' "$SOURCES" 2>/dev/null | head -1); base=${base%/}
  # The notes are untrusted text: at most 4 KB, shown as plain text by the web UI and the console.
  if [ -n "$avail" ]; then
    notes=$(curl -fsS --max-time 20 --max-filesize 65536 "$base/notes/$avail.md" 2>/dev/null | head -c 4096) || notes=
  fi
  tmp=$(mktemp "$STATE/.update.json.XXXXXX")
  jq -n --arg i "$inst" --arg a "$avail" --arg u "${avail:+$base/notes/$avail.md}" --arg n "$notes" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg e "$err" \
    'def opt: if . == "" then null else . end;
     {installed: ($i | opt), available: ($a | opt), notes_url: ($u | opt), notes: $n, checked_at: $t, error: ($e | opt)}' > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$STATE/update.json"
  write_issue
  if [ -n "$err" ]; then echo "AgentOS update check failed: $err"
  elif [ -n "$avail" ]; then echo "AgentOS $avail is available (installed: $inst)"; [ -z "$notes" ] || printf '\n%s\n' "$notes"
  else echo "AgentOS $inst is up to date"; fi
}

FAILED=0
say() {  # to the update log, and to stdout while anyone still reads it
  printf '%s\n' "$*" >> "$ULOG"
  printf '%s\n' "$*" 2>/dev/null || true
}
step() {  # step <label> <command...>
  local label=$1 l; shift
  if "$@" >"$LOG" 2>&1; then say "ok    $label"
  else say "FAIL  $label (see below)"; while IFS= read -r l; do say "      $l"; done < <(tail -5 "$LOG"); FAILED=1; fi
}
begin() {  # lock, then log: shared by the update and the rollback
  [ "$(id -un)" = agent ] || { echo "run as the agent user" >&2; exit 2; }
  exec 9<"$LOCK"
  flock -n 9 || { echo "agentos-update is already running" >&2; exit 3; }
  # Started from the web UI, this process outlives agentos-web's restart (KillMode=process), but its
  # stdout then has no reader: ignore SIGPIPE and keep going; the web UI reads $ULOG instead.
  trap '' PIPE
  : > "$ULOG"
  LOG=$(mktemp /tmp/agentos-update.XXXXXX.log)
  trap 'rm -f "$LOG"' EXIT
  say "== agentos-update $* $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
finish() {  # unlock, refresh update.json (and the console/MOTD notice), report
  flock -u 9
  sudo -n "$0" --check >/dev/null 2>&1 || true
  say "== done: $([ "$FAILED" = 0 ] && echo ok || echo 'with failures')"
  exit "$FAILED"
}

update() {
  local why ids
  begin
  # shellcheck source=/dev/null
  . /etc/profile.d/agentos.sh
  ids=$(agentos-ci list --json --limit 200 2>/dev/null | jq -r '[.[] | select(.status == "running" or .status == "queued") | .id] | join(" ")' 2>/dev/null) || ids=
  [ -z "$ids" ] || say "warning: CI runs in progress: $ids (they keep running; agentos-web restarts during the update)"
  why=$(source_problem)
  if [ -n "$why" ]; then say "skip  agentos ($why)"
  else step "agentos" sudo bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq --error-on=any $APT_AGENTOS && apt-get -y -qq $APT_CONF install --only-upgrade agentos"
  fi
  step "apt"      sudo bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq $APT_CONF full-upgrade"
  step "claude"   claude update
  step "codex"    npm install -g @openai/codex@latest
  step "opencode" opencode upgrade
  step "grok"     bash -c 'set -o pipefail; grok update 2>/dev/null || curl -fsSL https://x.ai/cli/install.sh | bash'
  step "rustup"   rustup update
  step "bun"      bun upgrade
  step "playwright" bash -c 'npm install -g playwright@latest && playwright install chromium'
  finish
}

rollback() {
  local why inst target v vers=()
  begin --rollback "$@"
  why=$(source_problem)
  [ -z "$why" ] || { say "FAIL  rollback ($why)"; exit 1; }
  # shellcheck disable=SC2086,SC2024 # APT_AGENTOS is a list of words; $LOG is agent's own file
  if ! sudo apt-get update -qq --error-on=any $APT_AGENTOS >"$LOG" 2>&1; then
    say "FAIL  rollback (the AgentOS repo could not be read)"; while IFS= read -r v; do say "      $v"; done < <(tail -5 "$LOG"); exit 1
  fi
  inst=$(installed)
  mapfile -t vers < <(apt-cache madison agentos | awk -F'|' '{gsub(/ /, "", $2); print $2}')   # newest first
  say "AgentOS versions in the repo (installed: ${inst:-none}):"
  for v in "${vers[@]}"; do say "  $v"; done
  target=${1:-}
  if [ -z "$target" ]; then
    for v in "${vers[@]}"; do if dpkg --compare-versions "$v" lt "$inst"; then target=$v; break; fi; done
    [ -n "$target" ] || { say "FAIL  rollback (no version older than $inst in the repo)"; exit 1; }
  fi
  printf '%s\n' "${vers[@]}" | grep -qxF -- "$target" || { say "FAIL  rollback ($target is not in the repo)"; exit 1; }
  # Migrations are forward-only and safe to run again: a rollback does not undo them.
  step "agentos $target" sudo bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get -y -qq --allow-downgrades $APT_CONF install agentos=$(printf %q "$target")"
  finish
}

case "${1:-}" in
  "")         update ;;
  --check)    as_root "$@"; check ;;
  --rollback) shift; rollback "$@" ;;
  --version)  v=$(installed); [ -n "$v" ] || { echo "agentos is not installed" >&2; exit 1; }; echo "$v" ;;
  --notice)   notice ;;
  --issue)    as_root "$@"; write_issue ;;
  *)          sed -n '4,10s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
```
Notes for the reviewer:
- `sudo` resets the environment, so the `AGENTOS_*` test overrides never reach a root run, and the `--rollback VERSION` argument must be in the repo's list before it reaches apt (no option injection).
- The full-upgrade step also gets the conffile options: an `agentos` conffile can change there too when the AgentOS step was skipped.

- [ ] **Step 4: The timer, the preset, the lock and the log**

`package/usr/lib/systemd/system/agentos-update-check.service`:
```ini
[Unit]
Description=Check for a new AgentOS release (writes /var/lib/agentos/update.json; installs nothing)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/agentos-update --check
```

`package/usr/lib/systemd/system/agentos-update-check.timer`:
```ini
[Unit]
Description=Daily check for a new AgentOS release

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
```

In `package/usr/lib/systemd/system-preset/10-agentos.preset`, find:
```
enable agentos-reap-desktops.timer
```
Replace with:
```
enable agentos-reap-desktops.timer
enable agentos-update-check.timer
```

Append to `package/usr/lib/tmpfiles.d/agentos.conf`:
```
# agentos-update: one run at a time (root's --check and agent's update share it), and the last
# run's log, which the web UI shows after agentos-web restarted mid-update.
f /run/lock/agentos-update.lock 0644 agent agent -
f /var/log/agentos-update.log   0644 agent agent -
```
`build-deb.sh` lists the two new units in `units.new`, so a box updating from a release without them gets the timer enabled and started by the postinst's "new units" step, and `configure` creates the lock and the log (`systemd-tmpfiles --create`).

- [ ] **Step 5: CI runs the test**

In `.github/workflows/build.yml`, find:
```yaml
            test/configure_test.sh test/register_mcp_test.sh test/apt_publish_test.sh \
```
Replace with:
```yaml
            test/configure_test.sh test/register_mcp_test.sh test/apt_publish_test.sh test/update_check_test.sh \
```
Find:
```yaml
          test/apt_publish_test.sh

```
Replace with:
```yaml
          test/apt_publish_test.sh
          test/update_check_test.sh

```

- [ ] **Step 6: Run the test and shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'test/update_check_test.sh && shellcheck -S warning package/usr/local/bin/agentos-update test/update_check_test.sh && echo SC-OK'`
Expected:
```
update check OK
SC-OK
```
The update, the rollback and the timer run in the VM in Task 7 (`check_update_end_to_end`, `check_agentos_update`, `check_agentos_package_installed`).

- [ ] **Step 7: Commit**

```bash
git add package/usr/local/bin/agentos-update package/usr/lib/systemd/system/agentos-update-check.service \
  package/usr/lib/systemd/system/agentos-update-check.timer package/usr/lib/systemd/system-preset/10-agentos.preset \
  package/usr/lib/tmpfiles.d/agentos.conf test/update_check_test.sh .github/workflows/build.yml
git commit -m "feat(update): agentos-update installs AgentOS first; --check, --rollback, --version; daily check timer"
```

---
### Task 5: Web UI: the update state, "Check now", the banner, the footer, and the reconnect

**Files:**
- Create: `web/server/src/update.ts`, `web/ui/src/components/UpdateCard.tsx`
- Modify: `web/server/src/actions.ts`, `web/server/src/app.ts`, `web/server/test/helpers.ts`, `web/ui/src/pages/System.tsx` (whole file), `web/ui/src/pages/Overview.tsx`, `web/ui/src/App.tsx`, `web/ui/src/types.ts`, `web/ui/src/style.css`
- Test: `web/server/test/update.test.ts` (new), `web/ui/test/System.test.tsx` (whole file), `web/ui/test/Overview.test.tsx` (new)

**Interfaces:**
- Consumes: `agentos-update --check` (as root through `sudo -n`), `--version`, the lock `/run/lock/agentos-update.lock`, `/var/lib/agentos/update.json` and `/var/log/agentos-update.log` (Task 4); the existing `ci-list` action.
- Produces:
  - `GET /api/update` → `UpdateState` `{installed, available, notes_url, notes, checked_at, error, running, ciActive}`. `installed` is live (`agentos-update --version`); `error` is `"not checked yet"` when `update.json` has no `checked_at`; `available` is `null` unless it matches `^[0-9][A-Za-z0-9.+~]*$`; strings are capped (notes 4096, error 512).
  - `POST /api/update/check` (CSRF, audited as `update-check -`) → the new `UpdateState`; 500 with stderr if the check fails to run.
  - `GET /api/update/log` → `{running, text}` (the log's last 64 KiB).
  - Actions `update-check`, `update-version`, `update-running`; `Deps.updateState`, `Deps.updateLog`.
  - The UI types `UpdateState`, `UpdateLog`; `UpdateCard` on the System page; the Overview banner; the footer `AgentOS <version>`.

- [ ] **Step 1: Write the failing tests**

`web/server/test/update.test.ts`:
```ts
import { writeFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { argv } from '../src/actions.js';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const UPDATE = '/usr/local/bin/agentos-update';
const LOCK = ['flock', '-n', '/run/lock/agentos-update.lock', 'true'];
const STATE = { installed: '1.0.0', available: '1.1.0', notes_url: 'https://o.github.io/r/apt/notes/1.1.0.md',
  notes: '<b>new</b>', checked_at: '2026-10-29T03:12:00Z', error: null };
const RUNS = JSON.stringify([{ id: '20261029-101500-0001', status: 'running' }, { id: '20261029-101400-0000', status: 'passed' },
  { id: '20261029-101600-0002', status: 'queued' }]);

// A runner for the update calls: version 1.0.0, the lock free unless `locked`, two active CI runs.
const reply = (locked = false) => (a: string[]) =>
  a[0] === UPDATE && a[1] === '--version' ? { stdout: '1.0.0\n' }
    : a[0] === 'flock' ? { code: locked ? 1 : 0 }
      : a[1] === 'list' ? { stdout: RUNS } : {};

describe('updates', () => {
  it('builds exact argv', () => {
    expect(argv({ name: 'update-check' })).toEqual(['sudo', '-n', UPDATE, '--check']);
    expect(argv({ name: 'update-version' })).toEqual([UPDATE, '--version']);
    expect(argv({ name: 'update-running' })).toEqual(LOCK);
  });
  it('GET /api/update: update.json, the live version, the lock and active CI runs', async () => {
    const { deps } = fakeDeps(reply());
    writeFileSync(deps.updateState, JSON.stringify(STATE));
    const app = await buildApp(deps);
    const r = await app.inject({ url: '/api/update', headers: H });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ ...STATE, running: false, ciActive: ['20261029-101500-0001', '20261029-101600-0002'] });
  });
  it('not checked yet; running while the lock is held; a hostile version is dropped', async () => {
    const { deps } = fakeDeps(reply(true));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/update', headers: H })).json()).toMatchObject({ installed: '1.0.0', available: null, error: 'not checked yet', running: true });
    writeFileSync(deps.updateState, JSON.stringify({ ...STATE, available: '1.1.0\u001b[2J', error: 'x'.repeat(2000), extra: 'dropped' }));
    const j = (await app.inject({ url: '/api/update', headers: H })).json();
    expect(j.available).toBeNull();
    expect(j.error).toHaveLength(512);
    expect(j).not.toHaveProperty('extra');
  });
  it('an error from the check is passed on, never turned into "up to date"', async () => {
    const { deps } = fakeDeps(reply());
    writeFileSync(deps.updateState, JSON.stringify({ ...STATE, available: null, error: 'Failed to fetch … Missing key 0123ABCD' }));
    const j = (await (await buildApp(deps)).inject({ url: '/api/update', headers: H })).json();
    expect([j.available, j.error]).toEqual([null, 'Failed to fetch … Missing key 0123ABCD']);
  });
  it('POST /api/update/check: CSRF, then agentos-update --check as root, audited', async () => {
    const { deps, calls, audits } = fakeDeps(reply());
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/update/check', headers: H })).statusCode).toBe(403);
    expect(calls).toEqual([]);
    const r = await app.inject({ method: 'POST', url: '/api/update/check', headers: HM });
    expect(r.statusCode).toBe(200);
    expect(calls[0].argv).toEqual(argv({ name: 'update-check' }));
    expect(audits).toEqual([`${LOGIN} update-check -`]);
    expect(r.json().installed).toBe('1.0.0');
  });
  it('GET /api/update/log: the last run, and whether it still runs', async () => {
    const { deps } = fakeDeps(reply(true));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/update/log', headers: H })).json()).toEqual({ running: true, text: '' });
    writeFileSync(deps.updateLog, 'x'.repeat(70 * 1024) + '\nok    agentos\n== done: ok\n');
    const j = (await app.inject({ url: '/api/update/log', headers: H })).json();
    expect(j.text).toHaveLength(64 * 1024);
    expect(j.text.endsWith('ok    agentos\n== done: ok\n')).toBe(true);
  });
});
```

`web/ui/test/System.test.tsx` (whole file; the existing test now routes `fetch` by URL, because the page reads `/api/update`):
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { System } from '../src/pages/System';
import type { UpdateLog, UpdateState } from '../src/types';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
HTMLElement.prototype.scrollTo = () => {};   // jsdom has no layout

// A fake WebSocket: the test ends the stream by calling onclose itself.
class FakeWS {
  static all: FakeWS[] = [];
  onmessage: ((e: { data: string }) => void) | null = null;
  onclose: ((e: { reason: string }) => void) | null = null;
  constructor(public url: string) { FakeWS.all.push(this); }
  close() {}
}

const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
const STATE: UpdateState = { installed: '1.0.0', available: '1.1.0', notes_url: 'https://o.github.io/r/apt/notes/1.1.0.md',
  notes: '<b>Faster</b> updates', checked_at: '2026-10-29T03:12:00Z', error: null, running: false, ciActive: [] };
// Routes the page's GETs; after a POST to /api/update/check, /api/update returns `after` (the
// server's check rewrote update.json).
function stubFetch(state: UpdateState, log: UpdateLog = { running: false, text: '' }, after = state) {
  const f = vi.fn(async (url: string, _init?: RequestInit) => {
    if (url === '/api/update/check') { state = after; return json(after); }
    if (url === '/api/update') return json(state);
    if (url === '/api/update/log') return json(log);
    if (url === '/api/system/updates') return json({ lastUnattended: null });
    return json([]);
  });
  vi.stubGlobal('fetch', f);
  return f;
}

it('disables "Run agentos-update" while its stream is open', async () => {
  stubFetch({ ...STATE, available: null });
  vi.stubGlobal('WebSocket', FakeWS);
  render(<System me={null} />);
  const run = screen.getByText('Run agentos-update') as HTMLButtonElement;
  await screen.findByText(/up to date/);
  expect(run.disabled).toBe(false);
  fireEvent.click(run);
  expect(run.disabled).toBe(true);
  const ws = FakeWS.all.at(-1)!;
  expect(ws.url).toMatch(/\/api\/system\/update$/);
  ws.onclose!({ reason: '' });
  await vi.waitFor(() => expect(run.disabled).toBe(false));
});

it('shows the versions, the notes as plain text and the CI warning; "Check now" posts and re-reads', async () => {
  const f = stubFetch({ ...STATE, ciActive: ['20261029-101500-0001'] }, undefined, { ...STATE, available: null, checked_at: '2026-10-29T09:00:00Z' });
  const { container } = render(<System me={null} />);
  await screen.findByText(/1\.1\.0 available/);
  expect(screen.getByText('AgentOS 1.0.0', { exact: false })).toBeTruthy();
  expect(screen.getByText('<b>Faster</b> updates')).toBeTruthy();
  expect(container.querySelector('.notes b')).toBeNull();
  expect(screen.getByText(/CI runs in progress: 20261029-101500-0001/)).toBeTruthy();
  fireEvent.click(screen.getByText('Check now'));
  await screen.findByText(/up to date/);
  const post = f.mock.calls.find(([u]) => u === '/api/update/check')!;
  expect(post[1]).toMatchObject({ method: 'POST', headers: { 'X-AgentOS': '1' } });
});

it('shows a failed check as a warning, never as "up to date"', async () => {
  stubFetch({ ...STATE, available: null, error: 'Failed to fetch https://o.github.io/r/apt/dists/stable/InRelease  Missing key 0123ABCD' });
  render(<System me={null} />);
  await screen.findByText(/update check failed: Failed to fetch .* Missing key 0123ABCD/);
  expect(screen.queryByText(/up to date/)).toBeNull();
});

it('after agentos-web restarted mid-update: shows the running update\'s log and keeps the buttons off', async () => {
  stubFetch({ ...STATE, running: true }, { running: true, text: 'ok    agentos\n' });
  render(<System me={null} />);
  await screen.findByText('agentos-update is running:');
  expect(screen.getByText(/ok\s+agentos/)).toBeTruthy();
  expect((screen.getByText('Run agentos-update') as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByText('Check now') as HTMLButtonElement).disabled).toBe(true);
});
```

`web/ui/test/Overview.test.tsx`:
```tsx
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Overview } from '../src/pages/Overview';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
const stub = (update: object) => vi.stubGlobal('fetch', vi.fn(async (url: string) =>
  url === '/api/update' ? json(update)
    : url === '/api/system/health' ? json({ cpuPercent: 1, load: [0, 0, 0], memory: { totalBytes: 1, usedBytes: 0 }, disk: { totalBytes: 1, usedBytes: 0 } })
      : url === '/api/desktops' ? json({ desktops: [] }) : url === '/api/system/tailscale' ? json({ state: 'Running', serve: 'ok' }) : json([])));

it('shows the "available" banner with the notes, as plain text, on demand', async () => {
  stub({ installed: '1.0.0', available: '1.1.0', notes: '<img src=x onerror=alert(1)> Faster', error: null, ciActive: [] });
  const { container } = render(<Overview />);
  await screen.findByText('AgentOS 1.1.0 is available');
  expect(screen.queryByText(/Faster/)).toBeNull();
  fireEvent.click(screen.getByText("What's new"));
  expect(screen.getByText('<img src=x onerror=alert(1)> Faster')).toBeTruthy();
  expect(container.querySelector('img')).toBeNull();
});

it('no banner when up to date', async () => {
  stub({ installed: '1.1.0', available: null, notes: '', error: null, ciActive: [] });
  render(<Overview />);
  await screen.findByText('CPU');
  expect(screen.queryByText(/is available/)).toBeNull();
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd web/server && npx vitest run test/update.test.ts; cd ../ui && npx vitest run test/System.test.tsx test/Overview.test.tsx`
Expected: the server tests fail (`argv({ name: 'update-check' })` returns `undefined`; `deps.updateState` is undefined, so `writeFileSync` throws a `TypeError`). The UI tests fail with `Unable to find an element with the text: /up to date/` (System) and `Unable to find an element with the text: AgentOS 1.1.0 is available` (Overview). vitest doesn't typecheck, so the missing `UpdateState` type is not an error yet.

- [ ] **Step 3: Server**

In `web/server/src/actions.ts`, find:
```ts
export const CI_ID_RE = /^\d{8}-\d{6}-[0-9a-f]{4}$/;
```
Replace with:
```ts
export const CI_ID_RE = /^\d{8}-\d{6}-[0-9a-f]{4}$/;
export const UPDATE = '/usr/local/bin/agentos-update';
export const UPDATE_LOCK = '/run/lock/agentos-update.lock';
```
Find:
```ts
  | { name: 'update' }
```
Replace with:
```ts
  | { name: 'update' }
  | { name: 'update-check' }                         // as root: refreshes only the AgentOS source
  | { name: 'update-version' }
  | { name: 'update-running' }                       // exits non-zero while agentos-update holds its lock
```
Find:
```ts
    case 'update': return ['/usr/local/bin/agentos-update'];
```
Replace with:
```ts
    case 'update': return [UPDATE];
    case 'update-check': return [...sudo, UPDATE, '--check'];
    case 'update-version': return [UPDATE, '--version'];
    case 'update-running': return ['flock', '-n', UPDATE_LOCK, 'true'];
```

`web/server/src/update.ts`:
```ts
// AgentOS updates: the state the daily check wrote (update.json), "Check now", and the last run's
// log. Installing stays the existing WebSocket action (/api/system/update) with its lock.
import { open } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import type { Deps } from './app.js';
import { HttpError } from './run.js';

export interface UpdateState {
  installed: string | null; available: string | null; notes_url: string | null; notes: string;
  checked_at: string | null; error: string | null; running: boolean; ciActive: string[];
}

const VERSION_RE = /^[0-9][A-Za-z0-9.+~]*$/;   // agentos-update's own check, again
const str = (v: unknown, max: number): string | null => (typeof v === 'string' && v !== '' ? v.slice(0, max) : null);

// The tail of a file (at most max bytes), or '' when it doesn't exist.
async function tail(path: string, max: number): Promise<string> {
  try {
    const f = await open(path, 'r');
    try {
      const { size } = await f.stat();
      const buf = Buffer.alloc(Math.min(size, max));
      await f.read(buf, 0, buf.length, size - buf.length);
      return buf.toString('utf8');
    } finally { await f.close(); }
  } catch { return ''; }
}

async function running(deps: Deps): Promise<boolean> {
  return (await runAction(deps.run, { name: 'update-running' })).code !== 0;
}

// update.json is untrusted text (the notes come from the repo): only known fields, typed and capped.
// The UI renders the notes as plain text.
export async function updateState(deps: Deps): Promise<UpdateState> {
  let j: Record<string, unknown> = {};
  try { j = JSON.parse(await tail(deps.updateState, 64 * 1024)) ?? {}; } catch { /* not checked yet */ }
  const [ver, isRunning, ci] = await Promise.all([
    runAction(deps.run, { name: 'update-version' }),
    running(deps),
    runAction(deps.run, { name: 'ci-list', limit: 200 }, { timeoutMs: 60_000 }),
  ]);
  let ciActive: string[] = [];
  try {
    ciActive = (JSON.parse(ci.stdout) as { id: string; status: string }[])
      .filter((r) => r.status === 'running' || r.status === 'queued').map((r) => String(r.id));
  } catch { /* agentos-ci unavailable: no warning */ }
  const available = str(j.available, 64);
  return {
    installed: ver.code === 0 ? ver.stdout.trim() || null : null,
    available: available && VERSION_RE.test(available) ? available : null,
    notes_url: str(j.notes_url, 512),
    notes: str(j.notes, 4096) ?? '',
    checked_at: str(j.checked_at, 64),
    error: j.checked_at ? str(j.error, 512) : 'not checked yet',
    running: isRunning,
    ciActive,
  };
}

export function updateRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/update', async () => updateState(deps));
  app.post('/api/update/check', async (req) => {
    deps.audit(req.login, 'update-check', '-');
    const r = await runAction(deps.run, { name: 'update-check' }, { timeoutMs: 120_000 });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim() || 'agentos-update --check failed');
    return updateState(deps);
  });
  // After agentos-web restarted mid-update, the page reconnects here: the run keeps writing this log.
  app.get('/api/update/log', async () => ({ running: await running(deps), text: await tail(deps.updateLog, 64 * 1024) }));
}
```

In `web/server/src/app.ts`, find:
```ts
import { solentaRoutes } from './solenta.js';
```
Replace with:
```ts
import { solentaRoutes } from './solenta.js';
import { updateRoutes } from './update.js';
```
Find:
```ts
  bridgePath: string;     // tools/solenta-bridge, served for download by the Solenta card
}
```
Replace with:
```ts
  bridgePath: string;     // tools/solenta-bridge, served for download by the Solenta card
  updateState: string;    // update.json, written by agentos-update --check (root, world-readable)
  updateLog: string;      // the last agentos-update run's log
}
```
Find:
```ts
    bridgePath: '/usr/local/share/agentos/solenta-bridge',
  };
```
Replace with:
```ts
    bridgePath: '/usr/local/share/agentos/solenta-bridge',
    updateState: '/var/lib/agentos/update.json',
    updateLog: '/var/log/agentos-update.log',
  };
```
Find:
```ts
  solentaRoutes(app, deps);
```
Replace with:
```ts
  solentaRoutes(app, deps);
  updateRoutes(app, deps);
```

In `web/server/test/helpers.ts`, find:
```ts
    bridgePath: fileURLToPath(new URL('../../../tools/solenta-bridge', import.meta.url)),
    ...over,
```
Replace with:
```ts
    bridgePath: fileURLToPath(new URL('../../../tools/solenta-bridge', import.meta.url)),
    updateState: join(realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-update-'))), 'update.json'),
    updateLog: join(realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-update-'))), 'agentos-update.log'),
    ...over,
```
The WebSocket update action (`/api/system/update`) and its in-memory one-run lock stay as they are; after a web restart, `agentos-update`'s own `flock` refuses a second run (exit 3, "agentos-update is already running", shown in the stream).

- [ ] **Step 4: UI**

Append to `web/ui/src/types.ts`:
```ts
export interface UpdateState {
  installed: string | null; available: string | null; notes_url: string | null; notes: string;
  checked_at: string | null; error: string | null; running: boolean; ciActive: string[];
}
export interface UpdateLog { running: boolean; text: string }
```

`web/ui/src/components/UpdateCard.tsx`:
```tsx
import { useState } from 'react';
import { api } from '../api';
import type { UpdateLog, UpdateState } from '../types';
import { usePoll } from '../usePoll';
import { ErrorText } from './ErrorText';
import { LogStream } from './LogStream';

// System > Updates: the installed and available AgentOS versions, "Check now", and the existing
// agentos-update action (WebSocket, one run at a time). The release notes are untrusted text from
// the repo: rendered as text, never as HTML. When agentos-web restarts mid-update the stream ends;
// the run goes on, and its log (/api/update/log) is shown until it finishes.
export function UpdateCard() {
  const u = usePoll(() => api<UpdateState>('/api/update'), 30000);
  const log = usePoll(() => api<UpdateLog>('/api/update/log'), 3000);
  const unattended = usePoll(() => api<{ lastUnattended: string | null }>('/api/system/updates'));
  const [streaming, setStreaming] = useState(0);
  const [open, setOpen] = useState(false);
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const s = u.data;
  const running = open || !!log.data?.running;
  const check = () => {
    setChecking(true);
    setCheckError(null);
    api('/api/update/check', 'POST').then(u.reload, (e: Error) => setCheckError(e.message)).finally(() => setChecking(false));
  };
  return (
    <div className="panel">
      <h2>Updates</h2>
      <ErrorText error={u.error} />
      {s && (
        <>
          <p>
            AgentOS {s.installed ?? 'not installed'}
            {s.available ? <strong> · {s.available} available</strong>
              : s.error ? <span className="bad"> · update check failed: {s.error}</span>
                : <span className="ok"> · up to date</span>}
          </p>
          {s.checked_at && <p className="hint">Last check: {new Date(s.checked_at).toLocaleString()}</p>}
          {s.available && s.notes && <pre className="notes">{s.notes}</pre>}
          {s.ciActive.length > 0 && (
            <p className="bad">CI runs in progress: {s.ciActive.join(', ')}. They keep running, but agentos-web restarts during the update.</p>
          )}
        </>
      )}
      <p>Last unattended-upgrades run: {unattended.data?.lastUnattended ? new Date(unattended.data.lastUnattended).toLocaleString() : 'never'}</p>
      <div className="actions">
        <button disabled={checking || running} onClick={check}>Check now</button>
        <button disabled={running} onClick={() => { setOpen(true); setStreaming((n) => n + 1); }}>Run agentos-update</button>
      </div>
      <ErrorText error={checkError} />
      {open ? <LogStream key={streaming} path="/api/system/update" onEnd={() => { setOpen(false); log.reload(); u.reload(); }} />
        : log.data?.text ? (
          <>
            <p className="hint">{log.data.running ? 'agentos-update is running:' : 'Last agentos-update run:'}</p>
            <pre className="log">{log.data.text}</pre>
          </>
        ) : null}
    </div>
  );
}
```

`web/ui/src/pages/System.tsx` (whole file; the Updates panel moves into `UpdateCard`):
```tsx
import { useState } from 'react';
import { LogStream } from '../components/LogStream';
import { Power } from '../components/Power';
import { Services } from '../components/Services';
import { UpdateCard } from '../components/UpdateCard';
import { openTerminal } from '../quick';
import type { Me } from '../types';

export function System({ me }: { me: Me | null }) {
  const [unit, setUnit] = useState<string | null>(null);
  return (
    <section>
      <h1>System</h1>
      <div className="actions"><button onClick={openTerminal}>Open terminal</button></div>
      <Services onLogs={setUnit} />
      {unit && (
        <div className="panel">
          <h2>Journal: <code>{unit}</code> <button onClick={() => setUnit(null)}>Close</button></h2>
          <LogStream path={`/api/system/journal?unit=${encodeURIComponent(unit)}`} />
        </div>
      )}
      <UpdateCard />
      {me && <Power hostname={me.hostname} />}
    </section>
  );
}
```

In `web/ui/src/pages/Overview.tsx`, find:
```tsx
import { api } from '../api';
```
Replace with:
```tsx
import { useState } from 'react';
import { api } from '../api';
```
Find:
```tsx
import type { CiRun, Desktop, Health, Session, Tailscale } from '../types';
```
Replace with:
```tsx
import type { CiRun, Desktop, Health, Session, Tailscale, UpdateState } from '../types';
```
Find:
```tsx
  const ci = usePoll(() => api<CiRun[]>('/api/ci/runs?limit=1'), 10000);
```
Replace with:
```tsx
  const ci = usePoll(() => api<CiRun[]>('/api/ci/runs?limit=1'), 10000);
  const update = usePoll(() => api<UpdateState>('/api/update'), 300000);
  const [notes, setNotes] = useState(false);
  const avail = update.data?.available;
```
Find:
```tsx
      <h1>Overview</h1>
```
Replace with:
```tsx
      <h1>Overview</h1>
      {avail && (
        <div className="panel banner">
          <strong>AgentOS {avail} is available</strong>{' '}
          {update.data?.notes && <button onClick={() => setNotes((n) => !n)}>{notes ? 'Hide' : "What's new"}</button>}{' '}
          <Link to="/system">Update on the System page</Link>
          {notes && <pre className="notes">{update.data?.notes}</pre>}
        </div>
      )}
```

In `web/ui/src/App.tsx`, find:
```tsx
import type { Me } from './types';
```
Replace with:
```tsx
import type { Me, UpdateState } from './types';
```
Find:
```tsx
  const { data: me } = usePoll(() => api<Me>('/api/me'));
```
Replace with:
```tsx
  const { data: me } = usePoll(() => api<Me>('/api/me'));
  const { data: update } = usePoll(() => api<UpdateState>('/api/update'));
```
Find:
```tsx
      <main>{page(path, me)}</main>
```
Replace with:
```tsx
      <main>{page(path, me)}</main>
      <footer>AgentOS {update?.installed ?? ''}</footer>
```

In `web/ui/src/style.css`, find:
```css
.layout { display: grid; grid-template: "head head" auto "nav main" 1fr / 180px 1fr; min-height: 100vh; }
```
Replace with:
```css
.layout { display: grid; grid-template: "head head" auto "nav main" 1fr "nav foot" auto / 180px 1fr; min-height: 100vh; }
```
Find:
```css
main { grid-area: main; padding: 16px 24px; min-width: 0; }
@media (max-width: 800px) { .layout { grid-template: "head" auto "nav" auto "main" 1fr / 1fr; } nav { flex-direction: row; overflow-x: auto; border-right: 0; } }
```
Replace with:
```css
main { grid-area: main; padding: 16px 24px; min-width: 0; }
footer { grid-area: foot; padding: 8px 24px; color: var(--muted); font-size: 12px; }
@media (max-width: 800px) { .layout { grid-template: "head" auto "nav" auto "main" 1fr "foot" auto / 1fr; } nav { flex-direction: row; overflow-x: auto; border-right: 0; } }
```
Append:
```css
.banner { border-color: var(--accent); }
.notes { white-space: pre-wrap; max-height: 240px; overflow: auto; background: var(--bg); padding: 8px; }
```
The notes are only ever a text child of `<pre>`: no `dangerouslySetInnerHTML` anywhere (the tests check that `<b>` and `<img>` in the notes are not elements).

- [ ] **Step 5: Run the tests, typecheck, build**

Run: `cd web/server && npx tsc -p tsconfig.json --noEmit && npx vitest run && cd ../ui && npx tsc -p tsconfig.json --noEmit && npx vitest run && npm run build`
Expected: server `Tests  106 passed | 1 skipped (107)`; UI `Tests  23 passed (23)`; `✓ built`.

- [ ] **Step 6: Commit**

```bash
git add web/server/src/update.ts web/server/src/actions.ts web/server/src/app.ts web/server/test/helpers.ts web/server/test/update.test.ts \
  web/ui/src/components/UpdateCard.tsx web/ui/src/pages/System.tsx web/ui/src/pages/Overview.tsx web/ui/src/App.tsx \
  web/ui/src/types.ts web/ui/src/style.css web/ui/test/System.test.tsx web/ui/test/Overview.test.tsx
git commit -m "feat(web): AgentOS update state, Check now, the available banner, the version footer, reconnect to a running update"
```

---

### Task 6: The console and MOTD notice

**Files:**
- Create: `package/etc/update-motd.d/60-agentos-update` (mode 755)
- Modify: `package/usr/local/sbin/agentos-firstboot`, `.github/workflows/build.yml`, `test/checks/99-update.sh` (append a check)

**Interfaces:**
- Consumes: `agentos-update --notice` and `--issue` (Task 4).
- Produces: the line `AgentOS X available: run agentos-update (or use the web UI)` in `/run/motd.dynamic` at every login (pam_motd) and in `/run/issue.d/60-agentos-update.issue` (agetty), rewritten at every boot and `agentos-config apply` (firstboot) and after every check, update and rollback.

- [ ] **Step 1: Write the failing check**

Append to `test/checks/99-update.sh`:
```bash

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
```
On the image from Task 1 it fails at `sudo agentos-update --check` (that `agentos-update` refuses root); Task 4's `agentos-update` gets past it and fails at the issue file, until Step 2.

- [ ] **Step 2: The MOTD script and firstboot**

`package/etc/update-motd.d/60-agentos-update`:
```sh
#!/bin/sh
# AgentOS: one line at login when a new release is available (agentos-update-check.timer, daily).
exec /usr/local/bin/agentos-update --notice
```
```bash
chmod 755 package/etc/update-motd.d/60-agentos-update
```
It is a conffile (it is in `/etc`), like the rest of AgentOS's `/etc`.

In `package/usr/local/sbin/agentos-firstboot`, find:
```bash
# 6. Console lockout prevention last, so it sees Tailscale. It restarts getty@tty1, which is
```
Replace with:
```bash
# 5e. The console's "AgentOS X available" line, from the last daily check (update.json survives a
# reboot, /run/issue.d does not).
/usr/local/bin/agentos-update --issue || echo "warning: AgentOS update notice not refreshed" >&2

# 6. Console lockout prevention last, so it sees Tailscale. It restarts getty@tty1, which is
```

In `.github/workflows/build.yml`, find:
```yaml
            package/usr/local/lib/agentos/configure package/usr/local/lib/agentos/migrations/*.sh package/DEBIAN/postinst \
```
Replace with:
```yaml
            package/usr/local/lib/agentos/configure package/usr/local/lib/agentos/migrations/*.sh package/DEBIAN/postinst \
            package/etc/update-motd.d/60-agentos-update \
```

- [ ] **Step 3: shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning package/etc/update-motd.d/60-agentos-update package/usr/local/sbin/agentos-firstboot test/checks/99-update.sh && echo SC-OK'`
Expected: `SC-OK`.

- [ ] **Step 4: Build and run the checks in the VM (UEFI)**

Run: `.superpowers/sdd/devvm.sh run 'AGENTOS_DEV=1 tools/build-deb.sh && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi'`, then `.superpowers/sdd/devvm.sh wait <JOB>` until it isn't 124.
Expected, among every earlier check passing:
```
PASS [uefi] check_agentos_package_installed
PASS [uefi] check_agentos_update
PASS [uefi] check_update_notice_console_and_motd
ALL CHECKS PASSED (N skipped)
```
`check_agentos_update` now also exercises the development-build path: its log has `skip  agentos (the AgentOS update source is disabled (development build))`.

- [ ] **Step 5: Commit**

```bash
git add package/etc/update-motd.d/60-agentos-update package/usr/local/sbin/agentos-firstboot test/checks/99-update.sh .github/workflows/build.yml
git commit -m "feat(update): the AgentOS update notice on the console and at SSH login"
```

---
### Task 7: The end-to-end update in the VM, docs, the full smoke run

**Files:**
- Modify: `test/checks/99-update.sh` (replace one function, add helpers and two checks), `test/web_ws.mjs` (whole file)
- Create: `docs/updates.md`

**Interfaces:**
- Consumes: everything above. From `smoke.sh`: `vm`, `vml`, `$WORK`, `$HERE`, `$MODE`. From `96-web.sh`: `$WEB` (`U`, `w`, `wm`, `code`, `up`) and `web_users`. From `98-ci.sh`: `$CI_REPO` (`ci_repo`). Host tools: `dpkg-deb`, `apt-ftparchive`, `gpg` (devvm has them; CI installs `apt-utils`, Task 3).
- Produces: `node web_ws.mjs update` (starts the update over the WebSocket, prints the stream, exits 0 when it ends); `docs/updates.md`.

- [ ] **Step 1: Write the checks**

In `test/checks/99-update.sh`, replace `check_agentos_package_installed` with (the version now comes from `agentos-update`, and the timer, the lock and the log exist):
```bash
check_agentos_package_installed() {  # sorts before check_agentos_update and check_update_*
  # The image carries the .deb this build made, untouched, and no unit files in the old place.
  local want; want=$(dpkg-deb -f "$(ls "$HERE"/../mkosi.packages/agentos_*_amd64.deb)" Version) || return 1
  vm 'test "$(agentos-update --version)" = "'"$want"'" && test -z "$(sudo dpkg -V agentos)" &&
      test -z "$(find /etc/systemd/system -maxdepth 1 -name "agentos-*" -print -quit)" &&
      test ! -e /etc/systemd/system/docker.service.d/10-agentos.conf &&
      systemctl is-enabled --quiet agentos-update-check.timer && systemctl is-active --quiet agentos-update-check.timer &&
      test "$(stat -c "%U %a" /var/log/agentos-update.log /run/lock/agentos-update.lock | sort -u)" = "agent 644"'
}
```
Then insert after it:
```bash
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

```

How `check_update_end_to_end` maps to the spec's in-VM list:
1. N+1 is N's own package repacked (`upd_deb`): a migration writing a marker, a changed unit (`agentos-web` gets `AGENTOS_SMOKE=1`), a new enabled unit, a changed conffile.
2. A local repo signed with a throwaway key, served on the VM's loopback (`smoke-repo` unit), through an edited `agentos.sources` (a local conffile edit) with `Signed-By: /etc/apt/keyrings/agentos-smoke.gpg`, a path no package owns, so neither the update nor the rollback removes it.
3. `--check` reports N+1, in `update.json`, `/run/issue.d` and the MOTD.
4. The update runs through the web UI's WebSocket; `agentos-web` restarts during it.
5. Verified: the version; the marker written once, and once still after the postinst runs again; `agentos-web` answers with a new PID and the changed unit; the new unit enabled and active; a tmux session and a CI run started through the web UI (so inside `agentos-web`'s cgroup) and a running desktop all survived; the edited conffile kept, the new one as `.dpkg-dist`; the update's log has `ok    agentos` and `== done`.
6. `--rollback` returns to N.
7. The repo re-signed with another key (now offering N+2): `--check` records the error, and `--rollback N+2` fails before installing anything.

Replace `test/web_ws.mjs` with:
```js
// In-VM WebSocket probe for the web UI, using the ws package shipped with the server.
//   node web_ws.mjs term <session-id> <text-to-type> <expected-output>
//   node web_ws.mjs vnc <desktop-number>        (expects the VNC server's "RFB 003.008" banner)
//   node web_ws.mjs cilog <run-id> <step> <expected-output>
//   node web_ws.mjs update                      (starts agentos-update and prints the stream; exits 0
//                                               when it ends: the run finished, or agentos-web restarted)
// Prints "WS OK" and exits 0 once the expected text arrives; exits 1 on close, HTTP error or timeout.
import { createRequire } from 'node:module';
const require = createRequire('/usr/local/lib/agentos/web/server/');
const WebSocket = require('ws');
const [mode, target, typed, expected] = process.argv.slice(2);
const path = mode === 'term' ? `/api/sessions/${target}/terminal?cols=80&rows=24`
  : mode === 'cilog' ? `/api/ci/runs/${target}/log?step=${encodeURIComponent(typed)}`
    : mode === 'update' ? '/api/system/update' : `/api/desktops/${target}/vnc`;
const want = mode === 'vnc' ? 'RFB 003.008' : expected;
const ws = new WebSocket(`ws://127.0.0.1:7070${path}`, {
  headers: { 'Tailscale-User-Login': process.env.LOGIN ?? 'smoke@example.com', Origin: 'http://127.0.0.1:7070' },
});
let got = '';
const bail = (why) => { console.error(`WS FAIL: ${why}; got ${JSON.stringify(got.slice(-300))}`); process.exit(1); };
setTimeout(() => bail('timeout'), mode === 'update' ? 30 * 60_000 : 20000);
ws.on('unexpected-response', (_req, res) => bail(`HTTP ${res.statusCode}`));
ws.on('close', (code, reason) => {
  if (mode === 'update') { console.log(got); process.exit(0); }
  bail(`closed ${code} ${reason}`);
});
ws.on('open', () => { if (mode === 'term') setTimeout(() => ws.send(JSON.stringify({ t: 'i', d: `${typed}\r` })), 1000); });
ws.on('message', (d) => {
  got += d.toString('latin1');
  if (mode !== 'update' && got.includes(want)) { console.log('WS OK'); process.exit(0); }
});
```

- [ ] **Step 2: Lint the checks**

Run: `.superpowers/sdd/devvm.sh sh 'shellcheck -S warning test/smoke.sh test/checks/*.sh && node --check test/web_ws.mjs && echo SC-OK'`
Expected: `SC-OK`.

- [ ] **Step 3: Docs**

`docs/updates.md`:
````markdown
# Updating AgentOS

AgentOS updates itself from its own signed apt repository. The box checks once a day and tells you; nothing installs until you say so.

## What gets updated

`agentos-update` (or **Update** on the web UI's System page) runs three steps, in this order:

1. **AgentOS:** the `agentos` package. It holds everything AgentOS installs itself: the scripts in `/usr/local/{bin,sbin}`, `/usr/local/lib/agentos` (the web UI, `agentos-ci`, the MCP servers and their Python venv, the migrations), `act`, the Solenta bridge, the systemd units and AgentOS's files in `/etc`. It runs first, so the remaining steps run the new code.
2. **Debian packages:** a full upgrade, which also pulls in any Debian package a new AgentOS release depends on.
3. **The agent CLIs and toolchains** (Claude Code, Codex, opencode, Grok, rustup, bun, Playwright), through their own updaters.

Each step prints `ok` or `FAIL`; the command exits 1 if any step failed. Your settings (`/etc/agentos/agentos.env`), your API keys and everything in `/home` are never part of the package.

**Configuration files.** If you edited one of AgentOS's files in `/etc` (for example `/etc/sysctl.d/90-agentos.conf`), the update keeps your version and saves the new one next to it as `<file>.dpkg-dist`. It never stops to ask.

**What keeps running.** The update restarts `agentos-web`, `agentos-mcp-http`, `agentos-novnc` and the firewall. It never restarts `agentos-solenta`, running desktops, agent tmux sessions or CI runs. If CI runs are active, the update and the web UI say so first; they keep running. When you update from the web UI, the page loses its live log while `agentos-web` restarts; the update goes on, and the page shows its log (`/var/log/agentos-update.log`) until it finishes.

## Checking

`agentos-update-check.timer` runs `agentos-update --check` once a day (at a random time, and at the next boot if the box was off). It refreshes only the AgentOS source and writes `/var/lib/agentos/update.json`. When a release is available:
- the web UI's Overview shows "AgentOS X is available", with its release notes on demand, and the System page shows the installed and available versions, a **Check now** button and **Update**;
- the console and SSH logins show `AgentOS X available: run agentos-update (or use the web UI)`.

Run the check yourself with `agentos-update --check`. `agentos-update --version` prints the installed version, which the web UI also shows at the bottom of every page. An unreachable repository or a bad signature shows as a failed check, with the cause; never as "up to date".

## Rolling back

`agentos-update --rollback` lists the AgentOS versions in the repository and installs the newest one older than yours. `agentos-update --rollback 1.3.0` installs that version. The repository keeps the last 10 releases.

Migrations (one-time steps a release runs on update, from `/usr/local/lib/agentos/migrations`) run forward only. A rollback does not undo them; every migration is written so that running it again, or running an older release after it, is harmless.

## Security

- The image trusts the AgentOS repository only through its own key, `/usr/share/keyrings/agentos-archive.gpg`, named by `Signed-By:` in `/etc/apt/sources.list.d/agentos.sources`. That key is trusted for this repository and nothing else, and no other key is trusted for it. A missing or wrong signature fails the check and the update.
- The repository is served over HTTPS from GitHub Pages. The signing key's private half exists only as the GitHub Actions secret `AGENTOS_APT_KEY`, used only by the release job, only for `v*` tags.
- The key's fingerprint is:

  ```
  (the owner fills this in at step 2 below)
  ```

  Check it on a box with `gpg --show-keys /usr/share/keyrings/agentos-archive.gpg`.
- Release notes and `update.json` are untrusted text: the web UI shows them as plain text, and the console prints only the version line.
- Only the web UI's existing update action installs anything, behind the same login, CSRF check, audit log and one-at-a-time lock as before. **Check now** is audited too (`update-check`).

## Development builds

`tools/build-deb.sh` builds the package into `mkosi.packages/`, where `mkosi build` picks it up. Until the repository URL and the signing key are set (owner steps 2 and 4), only a development build works: `AGENTOS_DEV=1 tools/build-deb.sh`. Its AgentOS source ships disabled (`Enabled: no`), so the check reports "the AgentOS update source is disabled (development build)" and `agentos-update` skips the AgentOS step. Pull requests and branch builds in CI are development builds; a `v*` tag never is.

## Boxes installed before updates existed

A box installed from an image without the `agentos` package needs either a reinstall or this one-time bootstrap (as `agent`, over SSH):

```bash
curl -fsSLo /tmp/agentos-archive.gpg https://<owner>.github.io/<repo>/apt/agentos-archive.gpg
gpg --show-keys /tmp/agentos-archive.gpg      # compare the fingerprint with the one above
sudo install -m 644 /tmp/agentos-archive.gpg /usr/share/keyrings/agentos-archive.gpg
printf 'Types: deb\nURIs: https://<owner>.github.io/<repo>/apt\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/agentos-archive.gpg\n' |
  sudo tee /etc/apt/sources.list.d/agentos.sources >/dev/null
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold agentos
```

The package takes over the files the old image installed. Where you changed one of AgentOS's files in `/etc`, yours is kept and the package's version lands next to it as `.dpkg-dist`. Its first migration moves AgentOS's units from `/etc/systemd/system` to `/usr/lib/systemd/system`, keeping which ones you enabled. From then on, `agentos-update` works as described above.

## Owner steps (once, by the repository owner)

Nothing is published until these are done. The build and the release job fail with a clear message until they are.

1. **Create the GitHub repository and push** this repository to it.
2. **Create the signing key** on a trusted machine, without a passphrase (the release job signs unattended):
   ```bash
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --passphrase '' --quick-gen-key 'AgentOS archive <you@example.com>' ed25519 sign never
   gpg --armor --export-secret-keys > agentos-apt-key.asc     # the secret: keep it offline as a backup
   gpg --export > package/usr/share/keyrings/agentos-archive.gpg
   gpg --show-keys --with-fingerprint package/usr/share/keyrings/agentos-archive.gpg
   ```
   Add the contents of `agentos-apt-key.asc` as the repository's Actions secret `AGENTOS_APT_KEY` (Settings, Secrets and variables, Actions). Commit `package/usr/share/keyrings/agentos-archive.gpg`, and put the fingerprint in the Security section above.
3. **Enable GitHub Pages** for the repository: Settings, Pages, deploy from the `gh-pages` branch, root folder. The first tag's release job creates the branch.
4. **Set the repository URL** in `package/etc/apt/sources.list.d/agentos.sources`: replace `https://OWNER.github.io/REPO/apt` with `https://<owner>.github.io/<repo>/apt`, and commit.
5. **Release:** write `docs/releases/<version>.md` (what's new, plain text), commit, then tag and push: `git tag v1.0.0 && git push origin v1.0.0`. The release job publishes the package, the notes, `latest.json` and the public key to `https://<owner>.github.io/<repo>/apt/`.
````

- [ ] **Step 4: Build, run every check in every mode, and measure the size**

Size: the package changes nothing in the package set and adds about 1.3 MB of dpkg metadata; the image's root filesystem measured 5637 MiB against 5636 MiB before (fact table). Expect `check_root_size_budget` within a few MiB of the last measured value (about 6556 MiB of 7168).

Run: `.superpowers/sdd/devvm.sh run 'AGENTOS_DEV=1 tools/build-deb.sh && mkosi -f build && TMPDIR=/var/tmp test/smoke.sh mkosi.output/agentos.raw uefi bios uefi-noseed'`, then `.superpowers/sdd/devvm.sh wait <JOB>` until it isn't 124. `check_update_end_to_end` runs a full `agentos-update` (every CLI updater) and a rollback: about 5 more minutes per mode.
Expected: every earlier check still passes, and in `uefi` and `bios`:
```
PASS [uefi] check_agentos_package_installed
PASS [uefi] check_agentos_update
PASS [uefi] check_root_size_budget
PASS [uefi] check_update_dev_build_source_disabled
PASS [uefi] check_update_end_to_end
PASS [uefi] check_update_notice_console_and_motd
…
ALL CHECKS PASSED (N skipped)
```
`check_root_size_budget` prints `root used: NNNN MiB (budget 7168)` only when it fails; to record the value, run `vm 'df --output=used -BM / | tail -1'` against a booted VM (`KEEP_WORK=1`), or read it from a failing run. If it grew by more than 20 MiB, find the cause with `du -sm /usr/local/lib/agentos/* /var/lib/dpkg/info` in the VM before going on.

- [ ] **Step 5: Manual checks (from the spec; not automated)**

1. **A real release, once the owner has done the owner steps** (never done by an implementer): after `v1.0.0` is published, on a box from that release's image, `agentos-update --check` says "up to date"; after `v1.0.1`, the Overview banner, the System card and the SSH login line show it, and Update installs it.
2. **Bootstrap of a box from before this plan** (optional): keep a copy of a pre-package image (`cp mkosi.output/agentos.raw /var/tmp/agentos-prepackage.raw` before Task 1's build), install it in a VM, serve a repo as `check_update_end_to_end` does, and follow "Boxes installed before updates existed" in `docs/updates.md` with that URL and key. Expect: `agentos-update --version` prints the package's version; `/var/lib/agentos/migrations.done` lists `001-units-to-usr-lib.sh`; `ls /etc/systemd/system/agentos-*` finds nothing; units that were enabled are still enabled (`systemctl is-enabled agentos-web agentos-firstboot agentos-solenta.path`); `agentos-update-check.timer` is enabled; edited `/etc` files are kept with a `.dpkg-dist` beside them.

- [ ] **Step 6: Commit**

```bash
git add test/checks/99-update.sh test/web_ws.mjs docs/updates.md
git commit -m "test: the AgentOS update end to end in the VM (web restart, survivors, rollback, wrong key); docs"
```

---

## Spec coverage

| Spec item | Task (test) |
|---|---|
| One `agentos` amd64 package, version from the tag, `0.0.0~git<date>.<sha>` otherwise | 1 (`build-deb.sh`; workflow `deb` output) |
| Contents: scripts, `computer/`, `ci/`, venv, web build + production `node_modules`, `migrations/`, `act` (pinned + sha256), `solenta-bridge`, units, timer and `.path` units, preset | 1 (Step 7 container listing in the fact table, `check_agentos_package_installed`), 2 (`migrations/`), 4 (timer) |
| Units in `/usr/lib/systemd/system`; true local drop-ins stay in `/etc` | 1 (finalize invariant, `check_agentos_package_installed`); adjustment 3 |
| `/etc` files as conffiles; edited one kept with `.dpkg-dist`; `--force-confdef --force-confold` | 1 (`DEBIAN/conffiles`), 4 (`APT_CONF`), 7 (`check_update_end_to_end`: sysctl edit kept, `.dpkg-dist`); adjustment 2 (`/etc/issue`, `20auto-upgrades`) |
| Debian packages in `Depends:`, minimal base in mkosi; image package set unchanged | 1 (Step 7 manifest diff: only `agentos` added); adjustment 15 |
| Not in the package: CLIs, toolchains, user state | 1 (prepare keeps them; finalize invariants unchanged) |
| Built with `dpkg-deb` in `debian:trixie`; the image installs the same .deb (mkosi 27 setting verified) | 1 (fact table: `mkosi.packages/`); adjustment 1 (NodeSource) |
| Finalize invariants stay | 1 (Step 7 `image invariants OK`) |
| Repo on `gh-pages`: `stable`/`main`/`amd64`, old versions kept, `InRelease` + `Release.gpg`, `AGENTOS_APT_KEY`, only the release job writes | 3 (`apt_publish_test.sh`, workflow); adjustments 12, 17 |
| Image ships the key and `agentos.sources` with `Signed-By`; key trusted for nothing else | 1 (source file), 7 (docs); fact table (`Signed-By` scoping) |
| unattended-upgrades never installs `agentos` | fact table (unattended-upgrade dry run: pin -32768); `52agentos-unattended` unchanged |
| `notes/<version>.md` and `latest.json` | 3 (`apt_publish_test.sh`); adjustments 4, 13 |
| postinst order: daemon-reload, new units per preset, migrations (once, failure stops and retries), try-restart of the four services, `register-mcp --update`; never restarted: Solenta, desktops, tmux, CI | 2 (`configure_test.sh`), 7 (`check_update_end_to_end`: marker once, new unit, web restarted, survivors) |
| `register-mcp --update`: rewrites AgentOS's entries, keeps user edits, skill blocks under the existing rules | 2 (`register_mcp_test.sh`); adjustment 16 |
| Chroot detection; image build needs no running systemd | 2 (`configure_test.sh` chroot case, Step 7 container install); fact table (mkosi probe) |
| Daily timer with randomized delay and `Persistent=true`; `--check` as root; refresh only the AgentOS source; compare; notes (4 KB); `update.json` fields, world-readable, no secrets | 4 (`update_check_test.sh`), 7 (`check_agentos_package_installed`, `check_update_end_to_end`); adjustments 4, 10 |
| Overview banner with notes on demand; System: versions, Check now, Update; `GET /api/update`, `POST /api/update/check` through the actions table | 5 (`update.test.ts`, `System.test.tsx`, `Overview.test.tsx`) |
| Console and MOTD line | 6 (`check_update_notice_console_and_motd`), 4 (`--notice`/`--issue` in `update_check_test.sh`), 7 (`check_update_end_to_end`) |
| Unreachable repo / bad signature → `error` with the cause, a warning, never "up to date" | 4 (`update_check_test.sh` badsig, nonet), 5 (`System.test.tsx` failed check, `update.test.ts`), 7 (wrong key) |
| `agentos-update` shape; steps agentos → apt → CLIs; CI warning | 4; 7 (`check_update_end_to_end` log), 5 (`ciActive` in the UI) |
| `--rollback` (list, previous, VERSION), migrations not undone (documented) | 4, 7 (`check_update_end_to_end`, docs) |
| Update survives the web restart; the page reconnects and shows the log | 4 (`trap '' PIPE`, log, lock), 5 (`/api/update/log`, `System.test.tsx` reconnect), 7 (update through the WebSocket, then the log); fact table (KillMode probe); adjustment 9 |
| `--version`; the footer | 4 (`update_check_test.sh`), 5 (`App.tsx`, `update.test.ts`) |
| Security: `Signed-By` over HTTPS, key only in the secret and the release job, fingerprint in the docs, notes as plain text, `printf %s`, check audited, same auth/CSRF/lock for installs | 3, 5 (CSRF 403 and audit in `update.test.ts`; `<b>`/`<img>` not rendered), 7 (docs); adjustment 17 |
| Unit tests: version compare and `update.json` writer (bad signature, no network, up to date, available); migration runner; `register-mcp --update`; `/api/update` and UI | 2, 4, 5 |
| Build checks: `agentos` at the build version, `dpkg -V` clean, no old unit paths, finalize invariants | 1 (finalize, `check_agentos_package_installed`), 7 |
| In-VM `99-update.sh` steps 1–7 | 7 (`check_update_end_to_end`) |
| Owner steps documented, never executed; build fails until the URL is set; dev builds work | 1 (`build-deb.sh` refusal, `AGENTOS_DEV`), 3 (publish refusals), 7 (`docs/updates.md`); adjustment 5 |
| Bootstrap of older boxes (documented; dpkg takes over files) | 2 (migration 001, units seeding), 7 (docs, manual check 2); fact table |
| Size budget | 1 (Step 7), 7 (Step 4) |

## Self-review

- **Spec coverage:** every row above maps to a task and a test. Deviations are listed under "Spec adjustments", each with its evidence.
- **Placeholders:** none in code. Every new file is complete; every edit to an existing file gives the exact text to find and its replacement, or the whole file. The repo URL placeholder in `agentos.sources` and the fingerprint line in `docs/updates.md` are deliberate: they are owner steps 2 and 4, and the build fails closed on the first. The only value left open is the measured root size (Task 7).
- **Names and types across tasks:**
  - `units.new` (Task 1, `build-deb.sh`) is read by `configure` (Task 2), and the two units Task 4 adds land in it automatically.
  - `configure` (Task 2) creates the tmpfiles entries Task 4 adds (`/run/lock/agentos-update.lock`, `/var/log/agentos-update.log`), which `agentos-update` (Task 4) and `update.ts` (Task 5, `UPDATE_LOCK`, `Deps.updateLog`) use with the same paths.
  - `update.json`'s fields (Task 4) are the server's `UpdateState` minus `running` and `ciActive` (Task 5), which match the UI's `UpdateState` type, the tests' fixtures and the `jq` paths in `99-update.sh`.
  - The notice line is the same string in `agentos-update` (Task 4), `update_check_test.sh`, `99-update.sh` and the spec.
  - The repo layout from `apt-publish.sh` (Task 3) is what `--check` reads (`<URIs>/notes/<V>.md`) and what `upd_repo` builds in the VM (Task 7).
  - `AGENTOS_DEV` (Task 1) is set by the workflow for non-tags (Task 1 Step 5) and refused at publish time (Task 3).
- **Ordering:** each task's tests pass with only the earlier tasks applied: the bash tests and vitest suites were run in this order; `configure`'s chroot path was checked in a container with the Task 2 package (10 units before Task 4 adds 2); the image with everything applied passed the focused VM checks listed in the fact table.
