# AgentOS updates: the `agentos` package, a signed apt repo, notify and one click

Date: 2026-10-29. Status: approved design.

## Goal

A box owner can move an installed AgentOS box to the latest AgentOS release, covering both new features and fixes, without reinstalling. Today `agentos-update` updates Debian packages and the agent CLIs. AgentOS's own parts are baked in from `mkosi.extra` and the prepare script, and never change after install. Those parts are:
- the scripts and systemd units;
- the web UI;
- `agentos-ci`, the MCP servers and the venv;
- `act` and `solenta-bridge`.

**Decisions (from brainstorming):**
- **Notify and one click.** The box checks daily and tells the owner. The owner clicks Update in the web UI, or runs `agentos-update`. Nothing installs on its own.
- **Delivery:** a signed `agentos` .deb from AgentOS's own apt repo.
- **Hosting:** GitHub Pages of the AgentOS GitHub repo. The repo doesn't exist yet. Creating it, pushing, and creating the signing key and secret are the owner's steps, and nothing is published without their go-ahead.

**Non-goals:** automatic installs, release channels (beta/stable), A/B image updates, and non-amd64 builds. All can be layered on later.

## 1. The `agentos` package

- **One binary package, `agentos`, amd64.** The version comes from the release tag (`v1.4.0` becomes `1.4.0`). Untagged builds are `0.0.0~git<date>.<sha>`.
- **Contents:** everything AgentOS owns that `mkosi.extra` and `mkosi.prepare.chroot` install today:
  - `/usr/local/bin`, `/usr/local/sbin` and `/usr/local/lib/agentos`: the scripts, `computer/`, `ci/`, the venv, the web build plus its production `node_modules`, and `migrations/`;
  - `/usr/local/bin/act`, pinned by version and sha256 as today;
  - `/usr/local/share/agentos/solenta-bridge`;
  - the systemd units, the timer and `.path` units, and the preset.
  - **Units move from `/etc/systemd/system` to `/usr/lib/systemd/system`**, so they aren't conffiles and an update never prompts. Drop-ins that are true local config stay in `/etc`.
  - The files in `/etc/profile.d`, `/etc/sudoers.d`, `/etc/sysctl.d`, `/etc/ssh/sshd_config.d`, `/etc/apt`, polkit, `/etc/issue` and docker `daemon.json` stay in `/etc` as dpkg conffiles. A locally edited conffile is kept, with the new one saved as `.dpkg-dist`; the update runs with `--force-confdef --force-confold`, so it never prompts.
- **Not in the package:**
  - Debian packages: the package declares the Debian packages AgentOS needs in `Depends:` (moved out of `mkosi.conf.d/*`, keeping a minimal base in mkosi). A new release can therefore pull in new Debian packages.
  - The agent CLIs, Rust, bun and Playwright in `~agent`: their own updaters still handle them, as today.
  - User state: `/etc/agentos/agentos.env`, `~/.config/agentos/secrets.env` and everything in `/home`.
- **Build:**
  - `tools/build-deb.sh` builds the package with `dpkg-deb` in a `debian:trixie` container, so the venv and the native `node-pty` build match the image: Debian's `nodejs` and Python 3.13.
  - The image build installs **this same .deb**, through mkosi's local package directory support (the plan verifies the exact mkosi 27 setting). A fresh install and an updated box therefore run identical AgentOS code, and every image build exercises the package.
- **Invariant:** the finalize invariants stay: no CLI state in the image.

## 2. The apt repo

- **Publishing:**
  - On a `v*` tag, the existing release workflow builds the .deb and adds it to an apt repo kept on the GitHub repo's `gh-pages` branch: suite `stable`, component `main`, arch `amd64`.
  - Old versions stay in the pool, so rollback works.
  - `InRelease` and `Release.gpg` are signed with a dedicated GPG key whose private half is the Actions secret `AGENTOS_APT_KEY`.
  - Only the release job has write scopes, and only it touches `gh-pages`; this matches today's rule.
- **What the image ships:**
  - the public key, at `/usr/share/keyrings/agentos-archive.gpg`;
  - `/etc/apt/sources.list.d/agentos.sources`, with `URIs: https://<owner>.github.io/<repo>/apt`, `Suites: stable`, `Components: main` and `Signed-By: /usr/share/keyrings/agentos-archive.gpg`.

  Only that key is trusted for this source, and the key is not trusted for any other source.
- **No automatic installs:** unattended-upgrades must never install `agentos`. Its allowed origins stay Debian security only, and the plan checks `52agentos-unattended`.
- **Release notes:** each release also publishes `apt/notes/<version>.md` (the "what's new" text) and `apt/latest.json` (`{version, notes_url, published}`).

## 3. Migrations and restarts (`postinst`)

When an upgrade is configured, these steps run in order:
1. `systemctl daemon-reload`.
2. **New units only:** units listed in the package's `/usr/local/lib/agentos/units.new` that aren't yet in `/var/lib/agentos/units.seen` are enabled per the preset, and started if their condition holds. Existing units keep the owner's enabled or disabled state.
3. **One-time migrations:** numbered scripts in `/usr/local/lib/agentos/migrations/NNN-name.sh` run once each, as root, in order. Each success is recorded in `/var/lib/agentos/migrations.done`. A failing migration stops the run and fails the configure, so `dpkg` reports it and the next update retries it. Migrations must be safe to run again.
4. **Restart AgentOS services:** `systemctl try-restart` on `agentos-web`, `agentos-mcp-http`, `agentos-novnc` and `agentos-firewall` (the firewall reloads its rules).
   - **Never restarted:** `agentos-solenta`, `agentos-desktop@*`, agent tmux sessions and CI workers.
   - All of these are separate units, or run under `KillMode=process`, so a web restart doesn't kill them.
5. **Re-register MCP servers and the skill for `agent`:** run `register-mcp --update`, a new mode. It rewrites AgentOS's own entries in each CLI config (for example a changed `tool_timeout_sec`) instead of skipping entries that are already registered, and it reinstalls the skill blocks under the existing rules: malformed blocks are kept, with a warning.

On a fresh image build, `postinst` runs inside the image and must not need a running systemd. It detects the chroot and skips steps 1 and 4.

## 4. Check and notify

- **The check:** `agentos-update-check.timer` runs daily, with a randomized delay and `Persistent=true`. It starts `agentos-update --check` as root, which:
  1. refreshes only the agentos source (`apt-get update -o Dir::Etc::sourcelist=… -o Dir::Etc::sourceparts=-`);
  2. compares the installed version with the candidate;
  3. fetches `latest.json` and the notes;
  4. writes `/var/lib/agentos/update.json`: `{installed, available|null, notes_url, notes (first 4 KB), checked_at, error|null}`. The file is world-readable and holds no secrets.
- **The web UI:**
  - **Overview** shows a banner, "AgentOS 1.4.0 is available", with the notes shown on demand.
  - **System** shows the installed and available versions, a "Check now" button, and the existing **Update** button. That button runs the existing update action, with its lock and live log.
  - `GET /api/update` reads `update.json`. `POST /api/update/check` runs the check through the actions table.
- **Console and SSH:** the console status screen and the MOTD show one line: `AgentOS 1.4.0 available: run agentos-update (or use the web UI)`.
- **Failure modes:** an unreachable repo or a bad signature produces `error`, with the cause, in `update.json`, shown as a warning, never as "up to date".

## 5. Update and rollback

`agentos-update` keeps its current shape: the `ok` and `FAIL` lines, and an exit code of 1 if any step failed. The steps become:
1. **`agentos`:** `apt-get install --only-upgrade agentos` with the conffile options above. Running it first means the newest AgentOS code runs the remaining steps.
2. **`apt`:** a full upgrade, as today.
3. **The agent CLIs and toolchains,** as today.

Supporting changes:
- **Before step 1:** if CI runs are active, print a warning with their ids, without blocking. The web UI shows the same warning before the button.
- **`agentos-update --rollback`:** installs the previous version from the repo with `--allow-downgrades`. It lists the available versions, and `--rollback VERSION` picks one. Migrations are forward-only and harmless when run again. A rollback doesn't undo migrations, which is documented.
- **The live log:** the update keeps running when `agentos-web` restarts mid-update. The process runs under `KillMode=process` and is the server's child; the plan verifies it is not killed by the restart. The System page reconnects, and shows the result from the update log in `/var/log/agentos-update.log`.
- **`agentos-update --version`** prints the installed AgentOS version. The web UI shows it in the footer.

## 6. Security

- Packages are trusted only through the AgentOS key, via `Signed-By`, over HTTPS. A missing or wrong signature fails the check and the update.
- The signing key lives only in the Actions secret, and the release job is the only job that can read it. The public key's fingerprint is printed in the docs, along with how to verify it.
- `update.json` and the notes are untrusted text. The web UI renders the notes as plain text (no HTML), and the console prints them through `printf %s`.
- Only the existing update action can install. It goes through the same auth, CSRF, audit and lock as today. `POST /api/update/check` is audited too.

## 7. Testing

- **Unit tests:**
  - the version comparison and the `update.json` writer, with a bad signature, no network, up to date, and an update available;
  - the migration runner: order, run-once, a failure that stops and is retried next time, and re-runs;
  - `register-mcp --update`: the new value is applied, user edits outside AgentOS's entries are kept, and skill blocks follow the existing rules;
  - the web server's `/api/update` and UI tests for the banner and the System card.
- **Build checks:**
  - the image contains `agentos` at the build version;
  - `dpkg -V agentos` is clean;
  - there are no files left under the old `/etc/systemd/system` paths;
  - the finalize invariants still hold.
- **In-VM check (`99-update.sh`):**
  1. Build version N+1 of the package, with a test migration that writes a marker and a changed unit.
  2. Serve a local repo, signed with a test key, through a source override.
  3. `--check` reports N+1.
  4. Run the update.
  5. Verify:
     - the version is N+1;
     - the migration marker exists, and running again doesn't re-run the migration;
     - `agentos-web` answers;
     - a tmux session, a running desktop and a running CI run all survived;
     - a locally edited conffile was kept.
  6. `--rollback` returns to N.
  7. The same repo signed with a different key gives `error`, and nothing installs.

## 8. Owner steps (manual, documented)

1. Create the GitHub repo and push.
2. Generate the signing key, add `AGENTOS_APT_KEY` as an Actions secret, and commit the public key.
3. Enable Pages on `gh-pages`.
4. Set the repo URL in `agentos.sources`. A build-time variable with a placeholder fails the build until it is set.
5. Tag `v1.0.0`.

Boxes installed before this feature have no `agentos` package. They need one reinstall, or a documented one-time bootstrap: add the source and key, then install `agentos`, which takes over the existing files.
