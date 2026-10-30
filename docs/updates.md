# Updating AgentOS

AgentOS updates itself from its own signed apt repository. The box checks once a day and tells you; nothing installs until you say so.

## What gets updated

`agentos-update` (or **Update** on the web UI's System page) runs three steps, in this order:

1. **AgentOS:** the `agentos` package. It holds everything AgentOS installs itself: the scripts in `/usr/local/{bin,sbin}`, `/usr/local/lib/agentos` (the web UI, `agentos-ci`, the MCP servers and their Python venv, the migrations), `act`, the Solenta bridge, the systemd units and AgentOS's files in `/etc`. It runs first, but that alone doesn't make the rest of *this* run use the new code: bash already has this invocation's `agentos-update` script loaded into memory, so steps 2 and 3 below still run with the script that started. The new `agentos-update` takes effect the next time it's invoked — which happens right after, when this run's own `finish()` runs the post-update `agentos-update --check` as a fresh process.
2. **Debian packages:** a full upgrade, which also pulls in any Debian package a new AgentOS release depends on.
3. **The agent CLIs and toolchains** (Claude Code, Codex, opencode, Grok, rustup, bun, Playwright), through their own updaters.

Each step prints `ok` or `FAIL`; the command exits 1 if any step failed. Your settings (`/etc/agentos/agentos.env`), your API keys and everything in `/home` are never part of the package.

**Configuration files.** If you edited one of AgentOS's files in `/etc` (for example `/etc/sysctl.d/90-agentos.conf`), the update keeps your version and saves the new one next to it as `<file>.dpkg-dist`. It never stops to ask.

**What keeps running.** The update restarts `agentos-web`, `agentos-mcp-http`, `agentos-novnc` and the firewall. It never restarts `agentos-solenta`, running desktops, agent tmux sessions or CI runs. If CI runs are active, the update and the web UI say so first; they keep running. When you update from the web UI, the page loses its live log while `agentos-web` restarts; the update goes on, and the page shows its log (`/var/log/agentos-update.log`) until it finishes.

**MCP servers.** Every update re-registers AgentOS's MCP servers (`agentos-computer`, `agentos-ci`) with every agent CLI, and reinstalls the `agentos-ci` skill (`register-mcp --update`, run by the package's postinst). If you had disabled one of AgentOS's own MCP servers for a CLI, an update re-enables it: `--update` rewrites AgentOS's entries to this release's values on every update, the same way a fresh install adds them. Your own, unrelated MCP servers and comments are left alone.

## Checking

`agentos-update-check.timer` runs `agentos-update --check` once a day (at a random time, and at the next boot if the box was off). It refreshes only the AgentOS source and writes `/var/lib/agentos/update.json`. When a release is available:
- the web UI's Overview shows "AgentOS X is available", with its release notes on demand, and the System page shows the installed and available versions, a **Check now** button and **Update**;
- the console and SSH logins show `AgentOS X available: run agentos-update (or use the web UI)`.

Run the check yourself with `agentos-update --check`. `agentos-update --version` prints the installed version, which the web UI also shows at the bottom of every page (refreshed every 5 minutes). An unreachable repository or a bad signature shows as a failed check, with the cause; never as "up to date".

## Rolling back

`agentos-update --rollback` lists the AgentOS versions in the repository and installs the newest one older than yours. `agentos-update --rollback 1.3.0` installs that version. A version not in the repository (too old, pruned, or never published) is refused before anything installs. The repository keeps the last 10 releases.

Migrations (one-time steps a release runs on update, from `/usr/local/lib/agentos/migrations`) run forward only. A rollback does not undo them: an older release's code runs on top of whatever a later migration already changed. Every migration is written so that running it again, or running an older release after it, is harmless.

## Security

- The image trusts the AgentOS repository only through its own key, `/usr/share/keyrings/agentos-archive.gpg`, named by `Signed-By:` in `/etc/apt/sources.list.d/agentos.sources`. That key is trusted for this repository and nothing else, and no other key is trusted for it. A missing or wrong signature fails the check and the update.
- The repository is served over HTTPS from GitHub Pages. The signing key's private half exists only as the GitHub Actions secret `AGENTOS_APT_KEY`, used only by the release job, only for `v*` tags.
- unattended-upgrades never installs `agentos`: Debian's own default, `/etc/apt/apt.conf.d/50unattended-upgrades`, already allows regular Debian stable point updates as well as security updates; apt.conf.d files add to that same `Origins-Pattern` list rather than replace it, and AgentOS's own `/etc/apt/apt.conf.d/52agentos-unattended` adds only Tailscale and Docker to it. The AgentOS repository's `Origin: AgentOS` matches none of those origins, so apt pins it at `-32768` and unattended-upgrades always falls back to the already-installed version.
- The key's fingerprint is:

  ```
  (the owner fills this in at step 2 below)
  ```

  Check it on a box with `gpg --show-keys /usr/share/keyrings/agentos-archive.gpg`.
- Release notes and `update.json` are untrusted text: the web UI shows them as plain text, and the console prints only the version line.
- Only the web UI's existing update action installs anything, behind the same login, CSRF check, audit log and one-at-a-time lock as before. **Check now** is audited too (`update-check`).

## Development builds

`tools/build-deb.sh` builds the package into `mkosi.packages/`, where `mkosi build` picks it up. Until the repository URL and the signing key are set (owner steps 3 and 2), only a development build works: `AGENTOS_DEV=1 tools/build-deb.sh`. Its AgentOS source ships disabled (`Enabled: no`), so the check reports "the AgentOS update source is disabled (development build)" and `agentos-update` skips the AgentOS step. Pull requests and branch builds in CI are development builds; a `v*` tag never is.

## Boxes installed before updates existed

A box installed from an image without the `agentos` package needs either a reinstall or this one-time bootstrap (as `agent`, over SSH):

```bash
curl -fsSLo /tmp/agentos-archive.gpg https://<owner>.github.io/<repo>/apt/agentos-archive.gpg
# A pre-agentos image may not have gnupg installed, and may not have run `apt-get update` even
# once yet (its package lists are empty by design): refresh the lists before installing it.
command -v gpg >/dev/null || { sudo apt-get update && sudo apt-get install -y gnupg; }
gpg --show-keys /tmp/agentos-archive.gpg      # compare the fingerprint with the one above
sudo install -m 644 /tmp/agentos-archive.gpg /usr/share/keyrings/agentos-archive.gpg
printf 'Types: deb\nURIs: https://<owner>.github.io/<repo>/apt\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/agentos-archive.gpg\n' |
  sudo tee /etc/apt/sources.list.d/agentos.sources >/dev/null
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold agentos
```

The package takes over the files the old image installed. Where you changed one of AgentOS's files in `/etc`, yours is kept and the package's version lands next to it as `.dpkg-dist`. Its first migration moves AgentOS's units from `/etc/systemd/system` to `/usr/lib/systemd/system`, keeping which ones you enabled. From then on, `agentos-update` works as described above.

After the bootstrap, review `find /etc -name '*.dpkg-dist'`: each one is the package's version of a file you'd edited, saved next to yours instead of overwriting it. Merge in whatever changed, then remove it.

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
3. **Set the repository URL** in `package/etc/apt/sources.list.d/agentos.sources`: replace `https://OWNER.github.io/REPO/apt` with `https://<owner>.github.io/<repo>/apt`, and commit.
4. **Release:** write `docs/releases/<version>.md` (what's new, plain text), commit, then tag and push: `git tag v1.0.0 && git push origin v1.0.0`. The release job publishes the package, the notes, `latest.json` and the public key to `https://<owner>.github.io/<repo>/apt/`.
5. **Enable GitHub Pages** for the repository: Settings, Pages, deploy from the `gh-pages` branch, root folder. Do this after step 4: the `gh-pages` branch doesn't exist until the first tag's release job creates it, so Pages can't be pointed at it any earlier.

**Queued releases.** Release runs triggered by a `v*` tag share one concurrency group (`apt-publish`, `cancel-in-progress: false`), so a running publish is never interrupted: a tag pushed while another release is running waits and then runs on its own. A release run that doesn't publish to the apt repo (a push to `main`, the weekly rebuild) gets its own group instead, so it never queues behind — or blocks — a tag's publish. GitHub keeps only **one** waiting run per group, though: if you push a third tag while one release runs and another waits, the waiting one is cancelled (it shows as cancelled in the Actions tab). Re-run that cancelled run from the Actions tab once the others finish. Re-running is safe: `apt-publish.sh` treats republishing the identical `.deb` for a version as a no-op.
