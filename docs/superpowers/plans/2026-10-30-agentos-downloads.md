# AgentOS Downloads on dl.currentbits.net Implementation Plan (Plan 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The AgentOS installer is a single, unsplit `.iso` at `https://dl.currentbits.net/agentos/index.html`, mirrored by a Girder worker that pulls each new GitHub release, while GitHub stays the source of truth.

**Architecture:**
- **The release.** `tools/convert.sh` adds the uncompressed installer's SHA-256 to `SHA256SUMS` as `agentos-installer-<v>.iso`, so the attested checksum file covers the `.iso` without the `.iso` being uploaded. `README-download.txt` (also the top of the release notes) points to the download page.
- **The mirror.** `dist/mirror.py` runs as the Girder worker app `agentos-dist`. Every 15 minutes it reads `releases/latest`. When the bucket's `agentos/latest.json` has another version, it streams the `.img.zst` parts from GitHub, decompresses them with `zstandard`, multipart-uploads the result as `agentos/agentos-installer-<v>.iso` (64 MiB parts, no local disk), checks both hashes, then publishes `.sha256`, `index.html` and `latest.json`, and only then deletes the previous version. A mismatch or error aborts the multipart upload, so nothing becomes visible.
- **Serving.** Girder's download-kind domain `dl.currentbits.net` serves the app's bucket directly (rclone, not proxied by Cloudflare).

**Tech Stack:**
- the existing stack: bash, `zstd`, `sha256sum`, GitHub Actions;
- new: Python 3.13 (`python:3.13-slim`, pinned by digest), `boto3` 1.43, `zstandard` 0.25, `requests` 2.34 (hash-pinned); tests: pytest and moto 5 (CI-only, not in the image);
- Girder: a worker app, its S3 service (Garage) and a download domain.

**Builds on:** branch `downloads` at 664678a (the spec commit). Implement in the main checkout `/Users/willem/Projects/AgentOS`, on branch `downloads`. Read `.superpowers/sdd/context.md` for the devvm workflow (`devvm.sh sh`, no `docker system prune`, never touch existing containers or volumes).

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-10-30-agentos-downloads-design.md`). When this plan and the spec disagree, the spec wins, except for the deliberate, evidenced adjustments listed under "Spec adjustments" below.

- **URL:** `dl.currentbits.net`, through a new Girder app `agentos-dist` with its own S3 bucket and a download-kind domain. Download domains bypass Cloudflare, which suits multi-GB files.
- **Sync model:** Girder pulls from GitHub releases. GitHub holds no Girder or tailnet secrets.
- **Contents:** the latest release's `.iso` only (4.4 GB).
- The VM images stay on GitHub, linked from the download page.
- So the bucket holds at most one `.iso`, plus a second one only during a switch: peak 8.8 GB.
- **Non-goals:** mirroring the VM formats, keeping older versions, editing the currentbits.net site (a separate app and repo, done as its own step), and a CDN.
- `convert.sh` already receives the uncompressed installer image (`installer.raw`). It adds the image's SHA-256 to `SHA256SUMS` under the name `agentos-installer-<v>.iso`. The `.iso` file itself is **not** uploaded to GitHub, since it would be 4.4 GB in parts.
- `SHA256SUMS` is already covered by the release's build-provenance attestation. The `.iso` hash is therefore attested too, and `sha256sum -c --ignore-missing SHA256SUMS` still works on GitHub downloads.
- `README-download.txt` says that the `.iso` is available at `dl.currentbits.net` and that it is the decompressed `.img`.
- **Package:** `dist/mirror.py` (Python 3, `boto3`, `zstandard`, `requests`), `dist/Dockerfile`, and `dist/requirements.txt` (hash-pinned).
- **App setup:** worker kind (no port), with an S3 service and `app_config dockerfile=dist/Dockerfile`.
- **Configuration (environment):** from Girder's S3 service: `S3_*`; `GITHUB_REPO=currentbits/agentos`; `PREFIX=agentos/`; `INTERVAL=900`.
- Each cycle: `GET https://api.github.com/repos/currentbits/agentos/releases/latest`, unauthenticated (4 requests an hour, well under GitHub's limit). Ignore drafts and prereleases. The tag must match `^v[0-9]+\.[0-9]+\.[0-9]+$`. Version `V` is the tag without its `v`.
- Read `agentos/latest.json` from the bucket. If its version is `V`, stop.
- Download `SHA256SUMS` from the release, and parse the lines for `agentos-installer-V.img.zst` (required) and `agentos-installer-V.iso` (present from the next release on).
- Stream the installer: fetch the `.img.zst` parts (or the whole file, if it isn't split), concatenated in order. Download URLs must be on `github.com` or `objects.githubusercontent.com`. Hash the compressed stream. Decompress it with `zstandard` in streaming mode. Multipart-upload the decompressed stream to `agentos/agentos-installer-V.iso` (64 MiB parts), hashing it as it goes. No local disk is used.
- Verify: the compressed hash must equal the `.img.zst` line; the `.iso` hash must equal the `.iso` line, when that line exists. On any mismatch or error, **abort the multipart upload** (nothing becomes visible), leave the previous version untouched, log the error, and retry next cycle.
- Publish, in this order: `agentos/agentos-installer-V.iso.sha256` (`<hash>  agentos-installer-V.iso`); `agentos/index.html`; `agentos/latest.json`: `{version, iso, size, sha256, published, release_url}`.
- Delete the previous version's `.iso` and `.sha256`: everything under `agentos/` with a version other than `V`.
- **Robustness:** One cycle at a time. A failure in one cycle never kills the loop. Logs are one line per step, with sizes and hashes. Startup reports orphaned multipart uploads and aborts them, so space leaked by a crash is reclaimed.
- **`index.html`** is generated, static, and has no scripts. It shows: the version and date, with a link to the GitHub release notes; the `.iso` link, its size and its SHA-256, with a `sha256sum` verify line; how to use it: USB (`dd`/Etcher), virtual CD/BMC, Proxmox/VMware/Hyper-V; links to the other formats on the GitHub release. Every value is HTML-escaped.
- **Girder setup (operator steps, run once):** `create_app agentos-dist` (worker), then `services_add s3`; `domains_add dl.currentbits.net kind=download` (DNS and TLS are automatic, and the domain is not proxied); `app_config dockerfile=dist/Dockerfile`; push this repo to the app's Girder remote, redeploy after the S3 service exists, so the `S3_*` environment variables are injected; check that `https://dl.currentbits.net/agentos/index.html` is served after the first cycle.
- **Links:** The README's install section and the GitHub release notes, through `README-download.txt`, point to `https://dl.currentbits.net/agentos/index.html` for the `.iso`.
- **Unit tests** (`dist/test_mirror.py`, pytest, moto S3, fake GitHub HTTP): a new release is mirrored, and every hash, `latest.json` and `index.html` are correct; the same version again does nothing; a compressed-hash mismatch leaves no new object and the previous version intact; an `.iso` hash mismatch behaves the same way; a split release (two parts) works; a non-GitHub asset URL is refused; the previous version is deleted only after the new one is published; orphaned multipart uploads are aborted at startup; HTML escaping.
- **`convert.sh` test:** `SHA256SUMS` contains the `.iso` line, and its hash equals the hash of the installer image.
- **Live:** the first cycle mirrors v1.0.1, which has no `.iso` line, so only the compressed hash is checked. Then: download the `.iso` from `dl.currentbits.net` and check that its hash matches `.sha256`; boot it as a CD in QEMU/OVMF on devvm (`test/installer-boot-test.sh` with `INSTALL_MEDIA=cd`, or the equivalent); confirm the bucket holds about 4.4 GB, and check disk usage on `data-1` and `backup-1` after the next nightly backup.

Repo conventions (from the earlier plans):
- Bash scripts are `#!/bin/bash` with `set -euo pipefail` and must be `shellcheck -S warning` clean. Bash unit tests live in `test/*_test.sh`, print `<name> OK` on success and `FAIL: …` on failure, and are listed twice in the workflow's "Lint and unit tests" step (shellcheck and run).
- Never touch devvm's existing Docker containers or volumes; never prune. Throwaway `docker run --rm` containers are fine.
- Commit, never push.

## Facts verified while writing this plan (2026-10-30)

| Fact | How | Result |
|---|---|---|
| GitHub release JSON | `gh api repos/currentbits/agentos/releases/latest --jq '{tag_name,draft,prerelease,html_url,published_at,assets:[.assets[]\|{name,size,browser_download_url,url}]}'` | `tag_name` `v1.0.1`, `draft` false, `prerelease` false, `html_url` `https://github.com/currentbits/agentos/releases/tag/v1.0.1`, `published_at` `2026-10-30T12:39:00Z`. Each asset has `name`, `size` and `browser_download_url` (`https://github.com/currentbits/agentos/releases/download/v1.0.1/<name>`); `url` is the API URL (`api.github.com/.../assets/<id>`), not used. The installer is `agentos-installer-1.0.1.img.zst.part00` (1,992,294,400 bytes) and `.part01` (499,197,954): 2.49 GB compressed. Other assets: `MANIFEST.txt`, `README-download.txt`, `SHA256SUMS`, `SHA256SUMS.parts`, and the four VM images, each in two parts. |
| v1.0.1's `SHA256SUMS` | `curl -sL …/v1.0.1/SHA256SUMS` | Seven lines, `<64 hex>  <name>`, whole-file names: `d5ee16b9…5cec  agentos-installer-1.0.1.img.zst`. No `.iso` line (as the spec expects for the first live cycle). |
| Asset redirect host | `curl -sI https://github.com/currentbits/agentos/releases/download/v1.0.1/SHA256SUMS`; then `requests` through `mirror.fetch` | `HTTP/2 302`, `location: https://release-assets.githubusercontent.com/github-production-release-asset/…` (a signed URL, valid about an hour). **Not `objects.githubusercontent.com`.** `requests` follows it: `r.url`'s host is `release-assets.githubusercontent.com`, `r.history` `[302]`. |
| Girder's S3 variable names | Girder MCP `app_env_list` (names only, read-only) on `dist`, `solenta` and `veldo` | Exactly five: **`S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`** (all three apps). The girder-deploy skill: app containers may only reach the tailnet endpoints in their own env, "URL values with a tailnet IP: … S3_ENDPOINT", so `S3_ENDPOINT` is `http://<tailnet IP>:<port>`. |
| Garage and path-style addressing | Garage docs (`[s3_api] root_domain`: virtual-host buckets only under it); throwaway `dxflrs/garage:v2.1.0` and `dxflrs/garage:v1.0.1` containers on the Mac (single node, `127.0.0.1:39000`), `mirror.upload_iso` and `abort_orphans` with boto3 1.43.122 | Path style always works; virtual-host style needs a DNS name under `root_domain`. On an IP endpoint botocore falls back to path style by itself (the `virtual` run also passed), but `S3_ENDPOINT` is not guaranteed to stay an IP, so the client sets `addressing_style: path`. **boto3 1.43's default checksums (`when_supported`) worked on both Garage versions**: a 12 MiB, 3-part upload completed and read back byte-identical with `ContentType` kept, a hash mismatch aborted (`list_multipart_uploads` empty), and an orphaned upload was aborted. No checksum setting is needed. Containers removed afterwards. |
| Girder download domains | `curl` on `dl.rungirder.com`, `download.solenta.app`, `dl.veldo.app` | Served by `rclone/v1.70.3` (`rclone serve http`). A directory path (`/` or `/platform/`) returns rclone's **directory listing**, not `index.html`; a missing path returns 404. Files: `accept-ranges: bytes`, `Range` returns 206, `content-type` set (`application/xml`, `application/x-apple-diskimage`). So the page URL is `https://dl.currentbits.net/agentos/index.html`; `https://dl.currentbits.net/agentos/` lists the files. |
| `zstandard` 0.25.0 streaming | Probes in the test venv | `ZstdDecompressor().stream_reader(source)` calls `source.read(n)` and accepts **any non-empty return as more input** (a 1 MiB chunk for a 128 KiB request is fine); `b""` is the end. `reader.read(n)` returns at most `n`, and can return less than `n` before the end (at a frame boundary), so the mirror fills each 64 MiB part in a loop. Two concatenated frames decompress fully with repeated `read()` calls, with or without `read_across_frames`. **A truncated stream raises nothing** (50,200,576 of 50,301,000 bytes, no error): the compressed hash, which is required, is what catches it. Garbage raises `ZstdError: … Unknown frame descriptor`. |
| How many frames `zstd -T0` writes | devvm, zstd 1.5.7: `zstd -T0 -10` on the first 1.5 GB of `mkosi.output/agentos-installer.raw`, `zstd -l` | `Frames 1`. The tests still use two frames (concatenated frames are valid zstd). |
| boto3 multipart API, and moto | boto3 1.43.122, moto 5.2.5 (`mock_aws`) | `create_multipart_upload(Bucket, Key, ContentType)["UploadId"]`; `upload_part(Bucket, Key, UploadId, PartNumber, Body)["ETag"]`; `complete_multipart_upload(Bucket, Key, UploadId, MultipartUpload={"Parts": [{"PartNumber", "ETag"}]})`; `abort_multipart_upload(Bucket, Key, UploadId)`; `list_multipart_uploads(Bucket, Prefix)["Uploads"]` (each with `Key`, `UploadId`, `Initiated`; the key is absent when there are none). **moto supports all five**, keeps `ContentType`, and lists then forgets aborted uploads. moto enforces S3's 5 MiB minimum part size unless `S3_UPLOAD_PART_MIN_SIZE` is set before `moto` is imported; the tests set it to 1. A missing key raises `s3.exceptions.NoSuchKey`. moto rejects one-letter bucket names (`InvalidBucketName`). botocore's `provide-client-params.s3` event sees every call's operation name and `Key`, which the ordering test uses. |
| The installer image | devvm `ls -l mkosi.output/agentos-installer.raw` | 4,389,529,600 bytes (4.39 GB): 66 parts of 64 MiB, far under S3's 10,000-part limit. The mirror holds at most two 64 MiB buffers (about 130 MB of memory). |
| The Python image and dependencies | `docker buildx imagetools inspect python:3.13-slim`; `pip-compile --generate-hashes` (pip-tools 7.6.2) inside that image, `--platform linux/amd64` | `python:3.13-slim@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb` (the multi-arch index; Python 3.13.18, Debian trixie). Resolved: `boto3==1.43.122`, `botocore==1.43.122`, `certifi==2026.10.23`, `charset-normalizer==3.5.2`, `idna==3.20`, `jmespath==1.1.0`, `python-dateutil==2.9.0.post0`, `requests==2.34.2`, `s3transfer==0.19.3`, `six==1.17.0`, `urllib3==2.8.0`, `zstandard==0.25.0`, every one with all of its files' hashes (so cp312 wheels for CI are covered too). Running the regeneration command a second time gave an identical file. |
| The image builds and starts | `docker build --platform linux/amd64 -f dist/Dockerfile .` on the Mac; `docker run --rm` | Builds with `--require-hashes`. Without the S3 variables it exits at once with `KeyError: 'S3_ENDPOINT'` (a crash Girder shows), and it imports `boto3`, `zstandard` and `requests`. Image removed afterwards. |
| CI's Python | Throwaway `ubuntu:24.04` container (`--platform linux/amd64`), the exact workflow lines | Python 3.12.3; `pip install --require-hashes -r dist/requirements.txt` works; `test/convert_test.sh` prints `convert OK`; pytest `11 passed`. |

All code in this plan was run while writing it:
- **pytest:** `dist/test_mirror.py`, 11 passed on Python 3.13.14 (Mac venv) and 3.12.3 (`ubuntu:24.04`), with moto 5.2.5 and pytest 9.2.0. Mutations each fail at least one test: no abort on error (2 fail), no HTML escaping (1), no `.iso` hash check (1), no URL check (1), deleting every version (4), parts in reverse order (1).
- **bash:** `test/convert_test.sh` fails before Task 1's change (no `.iso` line) and prints `convert OK` after, on devvm and in `ubuntu:24.04`. `shellcheck -S warning` (0.10.0) is clean on `tools/convert.sh` and `test/convert_test.sh`.
- **Workflow:** the edited `build.yml` parses (PyYAML), and the "Lint and unit tests" step's new lines ran as written in `ubuntu:24.04`.

## Spec adjustments (with evidence)

1. **The allowed download hosts add `release-assets.githubusercontent.com`.** GitHub's asset redirect goes there now, not to `objects.githubusercontent.com` (fact table); with the spec's list alone, every download would be refused. `objects.githubusercontent.com` stays allowed (the older host), and `api.github.com` is allowed for the release API call, which goes through the same fetch code. Every URL must be `https`. The mirror checks the asset URL before requesting it and the final URL after the redirect, before reading any of the body.
2. **The S3 client uses path-style addressing** explicitly, with `S3_REGION` (default `garage`). No checksum override: boto3's defaults worked on Garage 1.0.1 and 2.1.0 (fact table).
3. **`latest.json`'s `published`** is the GitHub release's `published_at`, and the page's date is its first 10 characters. The spec doesn't say which time it means; the release time is the one users care about and is stable across re-mirrors.
4. **The page is `agentos/index.html`; `agentos/` itself is rclone's file listing** (fact table). The README and `README-download.txt` link to `index.html`. Objects get a `ContentType` (`application/x-iso9660-image`, `text/html; charset=utf-8`, `application/json`, `text/plain; charset=utf-8`).
5. **The fake GitHub is a tiny session object, not a library.** `mirror.py` takes its HTTP session as a parameter (`requests.Session()` in `main`), and the tests pass a `FakeGitHub` whose `get` maps URLs to bytes and rewrites `github.com/…/releases/download` to the redirect host, like GitHub. No `responses` dependency.
6. **pytest and moto are CI-only and not hash-pinned**, like the `test/ci` step's pytest. `dist/requirements.txt` (the image's dependencies) is hash-pinned and installed with `--require-hashes` in CI too, so the tests run against exactly the image's versions.
7. **SIGTERM exits through `SystemExit`.** Python as PID 1 would otherwise ignore SIGTERM until Docker's SIGKILL; the `except BaseException` around the upload then aborts an upload in flight on a redeploy or stop. A SIGKILL mid-upload leaves an orphan, which the next start aborts (spec).
8. **Two extra tests:** drafts, prereleases and tags that aren't `vX.Y.Z` are skipped; a release without an `.iso` line (v1.0.1) mirrors with the compressed hash only (the first live cycle).
9. **The README also gets a `dist/` row in "Repository layout" and one sentence in "Releasing"**, so maintainers know a release reaches `dl.currentbits.net` within 15 minutes.

## File map

```
tools/convert.sh                MOD  .iso line in SHA256SUMS; README-download.txt names the .iso and its page
test/convert_test.sh            NEW  bash unit test for convert.sh's checksums and notes (fakes for qemu-img, sudo, lsblk, cp)
dist/mirror.py                  NEW  the agentos-dist worker: GitHub release -> S3 .iso, page, latest.json
dist/test_mirror.py             NEW  pytest: moto S3 and a fake GitHub
dist/requirements.txt           NEW  hash-pinned boto3, requests, zstandard (and their dependencies)
dist/Dockerfile                 NEW  python:3.13-slim by digest; runs mirror.py as nobody
.github/workflows/build.yml     MOD  "Lint and unit tests": shellcheck and run convert_test.sh; venv + pytest for dist/
README.md                       MOD  Install: the .iso row and link; Repository layout: dist/; Releasing: the mirror
```

## Working locally

- **Bash unit test and shellcheck** run on devvm (GNU `stat`, `zstd`, `shellcheck`): `.superpowers/sdd/devvm.sh sh 'test/convert_test.sh'`. `devvm.sh` rsyncs the working tree first.
- **Python tests** on the Mac, in a venv that mirrors CI:
  ```bash
  python3 -m venv /tmp/agentos-dist-venv     # any Python 3.12 or 3.13; uv venv -p 3.13 works too
  /tmp/agentos-dist-venv/bin/pip install -q --require-hashes -r dist/requirements.txt
  /tmp/agentos-dist-venv/bin/pip install -q pytest 'moto[s3]>=5,<6'
  /tmp/agentos-dist-venv/bin/python -m pytest -q dist
  ```
  (Task 2 creates `dist/requirements.txt`; until then, Step 2's failing run is the only Python run.)
- **Docker** runs on the Mac (Docker Desktop); if it doesn't, use devvm with a throwaway `docker run --rm`. Never prune, never touch existing containers.

---

### Task 1: The `.iso` checksum and download notes in the release (`tools/convert.sh`)

**Files:**
- Modify: `tools/convert.sh` (the installer paragraph of `README-download.txt`, lines 60–65, and after the `SHA256SUMS` line, line 86)
- Modify: `.github/workflows/build.yml` ("Lint and unit tests" step)
- Test: `test/convert_test.sh` (new, mode 755)

**Interfaces:**
- Consumes: `tools/convert.sh <agentos.raw> <version> <outdir> [installer.raw]` as today.
- Produces:
  - In `<outdir>/SHA256SUMS`, when an installer is given, a last line `<sha256 of installer.raw>  agentos-installer-<version>.iso`. No `.iso` file in `<outdir>`. Task 2's mirror reads this line from the release.
  - `README-download.txt` names `agentos-installer-<version>.iso` and `https://dl.currentbits.net/agentos/index.html`.

- [ ] **Step 1: Write the failing test**

`test/convert_test.sh`:
```bash
#!/bin/bash
# Unit test for tools/convert.sh's checksums and download notes: SHA256SUMS carries an
# agentos-installer-<v>.iso line (the uncompressed installer's SHA-256; the .iso itself is served
# from dl.currentbits.net, not uploaded), `sha256sum -c --ignore-missing` still passes on the
# release directory, and README-download.txt points to the download page. qemu-img, sudo, lsblk and
# cp (for the manifest copy out of the image's mounted root only) are fakes; zstd and sha256sum are real.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$d/bin"
# qemu-img convert ... <in> <out>: write a stand-in for the output image.
printf '#!/bin/sh\nfor a; do out=$a; done\necho "image $out" > "$out"\n' > "$d/bin/qemu-img"
# sudo: losetup --find prints a loop device; mount, umount, udevadm and losetup -d do nothing.
printf '#!/bin/sh\n[ "$1" = losetup ] && [ "$2" = --find ] && echo /dev/loop9\nexit 0\n' > "$d/bin/sudo"
printf '#!/bin/sh\necho "/dev/loop9p1 root-x86-64"\n' > "$d/bin/lsblk"
cat > "$d/bin/cp" <<'EOS'
#!/bin/sh
[ "$1" = /mnt/agentos-root/var/lib/agentos-manifest.txt ] && { echo "agentos 9.9.9" > "$2"; exit 0; }
exec /bin/cp "$@"
EOS
chmod +x "$d/bin"/*
head -c 3000000 /dev/urandom > "$d/installer.raw"
echo raw > "$d/agentos.raw"
PATH=$d/bin:$PATH "$R/tools/convert.sh" "$d/agentos.raw" 9.9.9 "$d/out" "$d/installer.raw" >/dev/null

want="$(sha256sum < "$d/installer.raw" | cut -d' ' -f1)  agentos-installer-9.9.9.iso"
grep -qxF "$want" "$d/out/SHA256SUMS" || fail "no .iso line in SHA256SUMS: $(cat "$d/out/SHA256SUMS")"
[ ! -e "$d/out/agentos-installer-9.9.9.iso" ] || fail "the .iso must not be a release asset"
grep -q '  agentos-installer-9.9.9.img.zst$' "$d/out/SHA256SUMS" || fail "no .img.zst line"
(cd "$d/out" && sha256sum -c --ignore-missing --quiet SHA256SUMS) || fail "sha256sum -c on the release directory"
zstd -dc "$d/out/agentos-installer-9.9.9.img.zst" | sha256sum | grep -q "^${want%% *} " || fail ".img.zst does not decompress to the .iso's hash"
grep -qF 'https://dl.currentbits.net/agentos/index.html' "$d/out/README-download.txt" || fail "README-download.txt has no download page link"
grep -qF 'agentos-installer-9.9.9.iso' "$d/out/README-download.txt" || fail "README-download.txt does not name the .iso"
echo "convert OK"
```

- [ ] **Step 2: Run it to see it fail**

Run: `chmod 755 test/convert_test.sh && .superpowers/sdd/devvm.sh sh 'test/convert_test.sh'`
Expected: exit 1, with `FAIL: no .iso line in SHA256SUMS:` followed by today's seven lines (`agentos-9.9.9.qcow2` … `README-download.txt`).

- [ ] **Step 3: Add the `.iso` line and the download note to `convert.sh`**

In `tools/convert.sh`, find:
```bash
    echo "DVD), and boot it in UEFI mode (Secure Boot works)."
    echo
  fi
```
and replace it with:
```bash
    echo "DVD), and boot it in UEFI mode (Secure Boot works)."
    echo
    echo "agentos-installer-$VER.iso is the same image, already decompressed, as one direct download"
    echo "(no parts, nothing to reassemble) at https://dl.currentbits.net/agentos/index.html. That page"
    echo "has the latest release only; SHA256SUMS lists the .iso's SHA-256 too."
    echo
  fi
```

Then find:
```bash
(cd "$OUT" && sha256sum agentos-* MANIFEST.txt README-download.txt > SHA256SUMS)
```
and add after it:
```bash
# The .iso is the uncompressed installer, served from dl.currentbits.net (dist/mirror.py) and too
# big to upload here. Its line makes the attested SHA256SUMS cover it; --ignore-missing skips it.
if [ -n "$INSTALLER" ]; then
  echo "$(sha256sum < "$INSTALLER" | cut -d' ' -f1)  agentos-installer-$VER.iso" >> "$OUT/SHA256SUMS"
fi
```

The line is appended after the whole-file checksums and before the split, like the other whole-file lines; the release job's attestation (`subject-checksums: release/SHA256SUMS`) picks it up unchanged. Hashing 4.39 GB adds about 15 seconds to the Convert step.

- [ ] **Step 4: Run the test and shellcheck**

Run: `.superpowers/sdd/devvm.sh sh 'test/convert_test.sh && shellcheck -S warning tools/convert.sh test/convert_test.sh && echo shellcheck-clean'`
Expected:
```
convert OK
shellcheck-clean
```

- [ ] **Step 5: Wire the test into CI**

In `.github/workflows/build.yml`, step "Lint and unit tests", find the shellcheck argument line:
```
            test/build_deb_version_test.sh \
```
and replace it with:
```
            test/build_deb_version_test.sh test/convert_test.sh \
```
Then find the end of the step's run list:
```
          test/update_check_test.sh
          test/build_deb_version_test.sh
```
and add one line after it:
```
          test/convert_test.sh
```
(`zstd` is already installed by "Host setup".)

Run: `uv run -q --with pyyaml python -c 'import yaml; d = yaml.safe_load(open(".github/workflows/build.yml")); print([s for s in d["jobs"]["build"]["steps"] if s.get("name") == "Lint and unit tests"][0]["run"].count("convert_test.sh"))'`
Expected: `2`

- [ ] **Step 6: Commit**

```bash
git add tools/convert.sh test/convert_test.sh .github/workflows/build.yml
git commit -m "feat(release): SHA256SUMS lists the installer .iso; download notes point to dl.currentbits.net"
```

---

### Task 2: The mirror (`dist/`): GitHub release to a single `.iso` in Girder's bucket

**Files:**
- Create: `dist/mirror.py`, `dist/Dockerfile`, `dist/requirements.txt`
- Modify: `.github/workflows/build.yml` ("Lint and unit tests" step)
- Test: `dist/test_mirror.py`

**Interfaces:**
- Consumes: a GitHub release with `SHA256SUMS` holding `agentos-installer-<V>.img.zst` (required) and `agentos-installer-<V>.iso` (Task 1; optional), and the installer as `agentos-installer-<V>.img.zst` or `….img.zst.partNN`.
- Produces:
  - Environment: `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` (Girder), `GITHUB_REPO` (default `currentbits/agentos`), `PREFIX` (default `agentos/`), `INTERVAL` (default `900`).
  - Bucket layout under `PREFIX`: `agentos-installer-<V>.iso`, `agentos-installer-<V>.iso.sha256` (`<hash>  agentos-installer-<V>.iso\n`), `index.html`, `latest.json` (`{"version", "iso", "size", "sha256", "published", "release_url"}`). Task 3 links to `https://dl.currentbits.net/agentos/index.html`.
  - Functions the tests call: `cycle(s3, bucket, http)`, `abort_orphans(s3, bucket)`, `index_html(v, iso, size, sha, published, release_url, others)`, `check_url(url)`; module variable `PART` (bytes per part).

- [ ] **Step 1: Write the failing tests**

`dist/test_mirror.py`:
```python
"""Unit tests for dist/mirror.py: moto's in-memory S3 and a fake GitHub (a dict of URL -> bytes).
Run: python -m pytest -q dist"""
import hashlib
import json
import os

os.environ.setdefault("S3_UPLOAD_PART_MIN_SIZE", "1")  # read by moto at import: lets the tests use tiny parts
import boto3  # noqa: E402
import pytest  # noqa: E402
import zstandard  # noqa: E402
from moto import mock_aws  # noqa: E402

import mirror  # noqa: E402

BUCKET = "agentos-dist"
API = "https://api.github.com/repos/currentbits/agentos/releases/latest"
DL = "https://github.com/currentbits/agentos/releases/download"
ASSETS = "https://release-assets.githubusercontent.com/github-production-release-asset/1"


class Resp:
    def __init__(self, url, body):
        self.url, self.body = url, body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass

    def raise_for_status(self):
        if self.body is None:
            raise RuntimeError(f"404 {self.url}")

    def iter_content(self, n):
        return (self.body[i:i + n] for i in range(0, len(self.body), n))


class FakeGitHub:
    """Release asset URLs on github.com answer from release-assets.githubusercontent.com, like GitHub's 302."""

    def __init__(self):
        self.files, self.calls = {}, []

    def get(self, url, stream=True, timeout=None):
        self.calls.append(url)
        final = url.replace(DL, ASSETS) if url.startswith(DL) else url
        return Resp(final, self.files.get(url))


def sha(b):
    return hashlib.sha256(b).hexdigest()


def release(gh, v, img, parts=1, iso_line=True, zst_hash=None, iso_hash=None):
    """Publish release v on the fake GitHub: img compressed into `parts` assets, SHA256SUMS, two VM assets."""
    # Two zstd frames: the CLI writes one (zstd -T0), but a concatenation of frames is valid zstd too.
    comp = zstandard.ZstdCompressor().compress(img[:1000]) + zstandard.ZstdCompressor().compress(img[1000:])
    zst = f"agentos-installer-{v}.img.zst"
    sums = f"{zst_hash or sha(comp)}  {zst}\n{'0' * 64}  agentos-{v}.qcow2\n"
    if iso_line:
        sums += f"{iso_hash or sha(img)}  agentos-installer-{v}.iso\n"
    names = [zst] if parts == 1 else [f"{zst}.part{i:02d}" for i in range(parts)]
    step = -(-len(comp) // parts)
    assets = {n: comp[i * step:(i + 1) * step] for i, n in enumerate(names)}
    assets.update({"SHA256SUMS": sums.encode(), f"agentos-{v}.qcow2.part00": b"q", f"agentos-{v}.vmdk.zst": b"m"})
    gh.files.update({f"{DL}/v{v}/{n}": b for n, b in assets.items()})
    gh.files[API] = json.dumps({
        "tag_name": f"v{v}", "draft": False, "prerelease": False,
        "html_url": f"https://github.com/currentbits/agentos/releases/tag/v{v}", "published_at": "2026-10-30T12:39:00Z",
        "assets": [{"name": n, "browser_download_url": f"{DL}/v{v}/{n}"} for n in assets],
    }).encode()


IMG1 = os.urandom(20000) + b"\0" * 30000 + b"one"  # 50003 bytes: 7 parts of 8 KiB
IMG2 = os.urandom(9000) + b"two"


@pytest.fixture
def s3(monkeypatch):
    monkeypatch.setattr(mirror, "PART", 8192)
    with mock_aws():
        c = boto3.client("s3", region_name="us-east-1")
        c.create_bucket(Bucket=BUCKET)
        yield c


def get(s3, key):
    return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()


def keys(s3):
    return sorted(o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET).get("Contents", []))


def uploads(s3):
    return s3.list_multipart_uploads(Bucket=BUCKET).get("Uploads", [])


def test_new_release_is_mirrored(s3):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    mirror.cycle(s3, BUCKET, gh)
    assert get(s3, "agentos/agentos-installer-1.0.1.iso") == IMG1
    assert s3.head_object(Bucket=BUCKET, Key="agentos/agentos-installer-1.0.1.iso")["ContentType"] == "application/x-iso9660-image"
    assert get(s3, "agentos/agentos-installer-1.0.1.iso.sha256") == f"{sha(IMG1)}  agentos-installer-1.0.1.iso\n".encode()
    assert json.loads(get(s3, "agentos/latest.json")) == {
        "version": "1.0.1", "iso": "agentos-installer-1.0.1.iso", "size": len(IMG1), "sha256": sha(IMG1),
        "published": "2026-10-30T12:39:00Z", "release_url": "https://github.com/currentbits/agentos/releases/tag/v1.0.1"}
    page = get(s3, "agentos/index.html").decode()
    for s in ['href="agentos-installer-1.0.1.iso"', sha(IMG1), "2026-10-30", "releases/tag/v1.0.1", "sha256sum -c",
              f"{DL}/v1.0.1/agentos-1.0.1.qcow2.part00", "agentos-1.0.1.vmdk.zst", "Proxmox"]:
        assert s in page
    assert "<script" not in page
    assert uploads(s3) == []


def test_same_version_again_does_nothing(s3):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    mirror.cycle(s3, BUCKET, gh)
    before = {k: get(s3, k) for k in keys(s3)}
    gh.calls.clear()
    mirror.cycle(s3, BUCKET, gh)
    assert gh.calls == [API]
    assert {k: get(s3, k) for k in keys(s3)} == before


def test_release_without_iso_line_checks_the_compressed_hash_only(s3):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1, iso_line=False)
    mirror.cycle(s3, BUCKET, gh)
    assert get(s3, "agentos/agentos-installer-1.0.1.iso") == IMG1


def test_split_release(s3):
    gh = FakeGitHub()
    release(gh, "1.0.2", IMG2, parts=2)
    mirror.cycle(s3, BUCKET, gh)
    assert get(s3, "agentos/agentos-installer-1.0.2.iso") == IMG2
    assert [u for u in gh.calls if ".img.zst" in u] == [f"{DL}/v1.0.2/agentos-installer-1.0.2.img.zst.part00",
                                                        f"{DL}/v1.0.2/agentos-installer-1.0.2.img.zst.part01"]


@pytest.mark.parametrize("bad", [{"zst_hash": "1" * 64}, {"iso_hash": "2" * 64}])
def test_hash_mismatch_publishes_nothing_and_keeps_the_previous_version(s3, bad):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    mirror.cycle(s3, BUCKET, gh)
    before = {k: get(s3, k) for k in keys(s3)}
    release(gh, "1.0.2", IMG2, **bad)
    with pytest.raises(ValueError, match="sha256"):
        mirror.cycle(s3, BUCKET, gh)
    assert {k: get(s3, k) for k in keys(s3)} == before
    assert uploads(s3) == []


def test_non_github_asset_url_is_refused(s3):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    rel = json.loads(gh.files[API])
    for a in rel["assets"]:
        if a["name"].startswith("agentos-installer-"):
            a["browser_download_url"] = "https://evil.example/agentos-installer-1.0.1.img.zst"
    gh.files[API] = json.dumps(rel).encode()
    with pytest.raises(ValueError, match="outside GitHub"):
        mirror.cycle(s3, BUCKET, gh)
    assert "https://evil.example/agentos-installer-1.0.1.img.zst" not in gh.calls
    assert keys(s3) == []
    with pytest.raises(ValueError, match="outside GitHub"):
        mirror.check_url("http://github.com/x")  # https only


def test_draft_prerelease_and_odd_tags_are_skipped(s3):
    gh = FakeGitHub()
    for change in [{"draft": True}, {"prerelease": True}, {"tag_name": "v1.0.1-rc1"}, {"tag_name": "nightly"}]:
        release(gh, "1.0.1", IMG1)
        gh.files[API] = json.dumps({**json.loads(gh.files[API]), **change}).encode()
        mirror.cycle(s3, BUCKET, gh)
    assert keys(s3) == []


def test_previous_version_deleted_only_after_publishing(s3):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    mirror.cycle(s3, BUCKET, gh)
    ops = []
    s3.meta.events.register("provide-client-params.s3", lambda params, model, **kw: ops.append((model.name, params.get("Key"))))
    release(gh, "1.0.2", IMG2)
    mirror.cycle(s3, BUCKET, gh)
    assert keys(s3) == ["agentos/agentos-installer-1.0.2.iso", "agentos/agentos-installer-1.0.2.iso.sha256",
                        "agentos/index.html", "agentos/latest.json"]
    deletes = [i for i, (op, _) in enumerate(ops) if op == "DeleteObject"]
    assert sorted(ops[i][1] for i in deletes) == ["agentos/agentos-installer-1.0.1.iso", "agentos/agentos-installer-1.0.1.iso.sha256"]
    assert ops.index(("PutObject", "agentos/latest.json")) < min(deletes)


def test_orphaned_multipart_uploads_are_aborted_at_startup(s3):
    up = s3.create_multipart_upload(Bucket=BUCKET, Key="agentos/agentos-installer-1.0.1.iso")["UploadId"]
    s3.upload_part(Bucket=BUCKET, Key="agentos/agentos-installer-1.0.1.iso", UploadId=up, PartNumber=1, Body=b"x" * 100)
    mirror.abort_orphans(s3, BUCKET)
    assert uploads(s3) == []
    assert keys(s3) == []


def test_index_html_escapes_every_value():
    page = mirror.index_html("1.0.1", "a<b>.iso", 10, '"sha"', "2026-10-30T00:00:00Z", "https://x/?a=1&b=2",
                             [("<script>alert(1)</script>", 'https://github.com/"onmouseover="x')])
    assert "<script>" not in page and "<b>" not in page and '"onmouseover' not in page
    assert "&lt;script&gt;" in page and "a&lt;b&gt;.iso" in page and "&quot;sha&quot;" in page and "a=1&amp;b=2" in page
```

- [ ] **Step 2: Run them to see them fail**

Run (any Python 3.12+ venv with pytest and moto; see "Working locally"): `uv run -q -p 3.13 --with pytest --with 'moto[s3]>=5,<6' --with zstandard python -m pytest -q dist`
Expected: `ImportError while importing test module '…/dist/test_mirror.py'` … `ModuleNotFoundError: No module named 'mirror'`, `1 error`.

- [ ] **Step 3: Write the mirror**

`dist/mirror.py`:
```python
#!/usr/bin/env python3
"""Mirror the latest AgentOS release's installer to this app's S3 bucket as one .iso.

Runs as the Girder worker app `agentos-dist`; dl.currentbits.net serves the bucket. Every INTERVAL
seconds: read the latest GitHub release; if the bucket's latest.json has another version, stream the
installer's .img.zst (parts concatenated) from GitHub, decompress it and multipart-upload it as
PREFIX/agentos-installer-<V>.iso, check both SHA-256s against the release's SHA256SUMS, then publish
the .sha256, index.html and latest.json, and only then delete the previous version. Nothing touches
local disk. Spec: docs/superpowers/specs/2026-10-30-agentos-downloads-design.md.
"""
import hashlib
import html
import json
import os
import re
import signal
import sys
import time
from urllib.parse import urlparse

import boto3
import requests
import zstandard
from botocore.config import Config

REPO = os.environ.get("GITHUB_REPO", "currentbits/agentos")
PREFIX = os.environ.get("PREFIX", "agentos/")
INTERVAL = int(os.environ.get("INTERVAL", "900"))
PART = 64 * 1024 * 1024
TAG = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")
# Release asset URLs are on github.com and redirect to release-assets.githubusercontent.com (seen
# 2026-10-30); objects.githubusercontent.com is the older redirect host.
HOSTS = {"api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"}


def log(msg):
    print(msg, flush=True)


def check_url(url):
    u = urlparse(url)
    if u.scheme != "https" or u.hostname not in HOSTS:
        raise ValueError(f"refusing a URL outside GitHub: {url}")


def chunks(http, urls):
    """The bytes of urls, concatenated, in 1 MiB chunks. Each URL, and where it redirected to, must be on GitHub."""
    for url in urls:
        check_url(url)
        with http.get(url, stream=True, timeout=60) as r:
            r.raise_for_status()
            check_url(r.url)
            yield from r.iter_content(1 << 20)


def fetch(http, url):
    return b"".join(chunks(http, [url]))


class Source:
    """A file-like view of a chunk iterator for zstandard's stream_reader; hashes what it hands out.
    read() may return less than asked for (one chunk); an empty result is the end."""

    def __init__(self, it):
        self.it, self.sha, self.size = it, hashlib.sha256(), 0

    def read(self, _size=-1):
        c = next(self.it, b"")
        self.sha.update(c)
        self.size += len(c)
        return c


def upload_iso(s3, bucket, key, src, want_zst, want_iso):
    """Decompress src (a Source) into a multipart upload of key. Completes it only if the compressed
    hash is want_zst and, when want_iso is set, the .iso hash is want_iso; otherwise, and on any
    error or exit, aborts it, so nothing becomes visible. Returns (size, sha256 hex) of the .iso."""
    up = s3.create_multipart_upload(Bucket=bucket, Key=key, ContentType="application/x-iso9660-image")["UploadId"]
    parts, sha, size = [], hashlib.sha256(), 0
    try:
        reader = zstandard.ZstdDecompressor().stream_reader(src)
        while True:
            buf = bytearray()
            while len(buf) < PART and (b := reader.read(PART - len(buf))):
                buf += b
            if not buf and parts:
                break
            sha.update(buf)
            size += len(buf)
            n = len(parts) + 1
            etag = s3.upload_part(Bucket=bucket, Key=key, UploadId=up, PartNumber=n, Body=bytes(buf))["ETag"]
            parts.append({"PartNumber": n, "ETag": etag})
            log(f"part {n}: {size} bytes so far")
            if len(buf) < PART:
                break
        got_zst, got_iso = src.sha.hexdigest(), sha.hexdigest()
        log(f"compressed {src.size} bytes sha256 {got_zst}; iso {size} bytes sha256 {got_iso}")
        if got_zst != want_zst:
            raise ValueError(f"compressed sha256 {got_zst} != SHA256SUMS {want_zst}")
        if want_iso and got_iso != want_iso:
            raise ValueError(f"iso sha256 {got_iso} != SHA256SUMS {want_iso}")
        s3.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=up, MultipartUpload={"Parts": parts})
    except BaseException:
        s3.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=up)
        log(f"aborted the upload of {key}")
        raise
    return size, got_iso


def index_html(v, iso, size, sha, published, release_url, others):
    """The download page. others: [(asset name, url)] of the VM images on the GitHub release."""
    e = html.escape
    items = "\n".join(f'<li><a href="{e(u)}">{e(n)}</a></li>' for n, u in others)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AgentOS {e(v)} download</title></head>
<body style="font-family:system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;line-height:1.5">
<h1>AgentOS {e(v)}</h1>
<p>Released {e(published[:10])}. <a href="{e(release_url)}">Release notes</a></p>
<h2>Installer</h2>
<p><a href="{e(iso)}"><strong>{e(iso)}</strong></a> ({size / 1e9:.2f} GB, {size} bytes)</p>
<p>SHA-256: <code>{e(sha)}</code></p>
<pre>echo '{e(sha)}  {e(iso)}' | sha256sum -c</pre>
<h2>Use it</h2>
<ul>
<li><strong>USB stick:</strong> write it with <code>dd if={e(iso)} of=/dev/sdX bs=4M conv=fsync</code> or Etcher, then boot in UEFI mode (Secure Boot works).</li>
<li><strong>Virtual CD:</strong> attach it as virtual media in iDRAC, iLO or another BMC.</li>
<li><strong>VMs:</strong> attach it as the CD/DVD in Proxmox, VMware or Hyper-V (UEFI firmware), next to an empty disk of at least 32 GB.</li>
</ul>
<h2>Other formats</h2>
<p>VM images, on the <a href="{e(release_url)}">GitHub release</a> (files over 1900 MiB are split into parts; see README-download.txt there):</p>
<ul>
{items}
</ul>
</body></html>
"""


def put(s3, bucket, key, body, ctype):
    s3.put_object(Bucket=bucket, Key=key, Body=body.encode(), ContentType=ctype)
    log(f"published {key}")


def cycle(s3, bucket, http):
    rel = json.loads(fetch(http, f"https://api.github.com/repos/{REPO}/releases/latest"))
    tag = rel.get("tag_name", "")
    m = TAG.match(tag)
    if rel.get("draft") or rel.get("prerelease") or not m:
        log(f"skipping release {tag!r}: draft, prerelease or not vX.Y.Z")
        return
    v = m[1]
    try:
        cur = json.loads(s3.get_object(Bucket=bucket, Key=PREFIX + "latest.json")["Body"].read())
    except s3.exceptions.NoSuchKey:
        cur = {}
    if cur.get("version") == v:
        log(f"up to date: {v}")
        return
    log(f"mirroring {v} (bucket has {cur.get('version')})")
    assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
    sums = dict((n, h) for h, n in re.findall(r"^([0-9a-f]{64})  (\S+)$", fetch(http, assets["SHA256SUMS"]).decode(), re.M))
    zst, iso = f"agentos-installer-{v}.img.zst", f"agentos-installer-{v}.iso"
    if zst not in sums:
        raise ValueError(f"SHA256SUMS has no line for {zst}")
    names = [zst] if zst in assets else sorted(n for n in assets if re.fullmatch(re.escape(zst) + r"\.part[0-9]+", n))
    if not names:
        raise ValueError(f"release has no {zst} asset")
    log(f"source: {', '.join(names)}; iso hash {'from SHA256SUMS' if iso in sums else 'not in SHA256SUMS (release predates it)'}")
    src = Source(chunks(http, [assets[n] for n in names]))
    size, sha = upload_iso(s3, bucket, PREFIX + iso, src, sums[zst], sums.get(iso))
    others = sorted((n, u) for n, u in assets.items() if n.startswith(f"agentos-{v}."))
    put(s3, bucket, PREFIX + iso + ".sha256", f"{sha}  {iso}\n", "text/plain; charset=utf-8")
    put(s3, bucket, PREFIX + "index.html", index_html(v, iso, size, sha, rel["published_at"], rel["html_url"], others), "text/html; charset=utf-8")
    latest = {"version": v, "iso": iso, "size": size, "sha256": sha, "published": rel["published_at"], "release_url": rel["html_url"]}
    put(s3, bucket, PREFIX + "latest.json", json.dumps(latest, indent=2) + "\n", "application/json")
    # ponytail: one listing call; the prefix holds a handful of objects, far below its 1000-key page.
    for o in s3.list_objects_v2(Bucket=bucket, Prefix=PREFIX).get("Contents", []):
        old = re.fullmatch(re.escape(PREFIX) + r"agentos-installer-(.+?)\.iso(\.sha256)?", o["Key"])
        if old and old[1] != v:
            s3.delete_object(Bucket=bucket, Key=o["Key"])
            log(f"deleted {o['Key']}")


def abort_orphans(s3, bucket):
    """Abort multipart uploads a crash or a kill left behind, so their parts stop using disk."""
    for u in s3.list_multipart_uploads(Bucket=bucket, Prefix=PREFIX).get("Uploads", []):
        s3.abort_multipart_upload(Bucket=bucket, Key=u["Key"], UploadId=u["UploadId"])
        log(f"aborted orphaned upload of {u['Key']} from {u['Initiated']}")


def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"],
        region_name=os.environ.get("S3_REGION") or "garage",
        aws_access_key_id=os.environ["S3_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["S3_SECRET_ACCESS_KEY"],
        # Garage serves virtual-host buckets only under its configured root_domain; path style always works.
        config=Config(s3={"addressing_style": "path"}),
    )


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # PID 1 in the container; SystemExit aborts an upload in flight
    s3, bucket, http = s3_client(), os.environ["S3_BUCKET"], requests.Session()
    log(f"agentos-dist: {REPO} -> s3://{bucket}/{PREFIX} every {INTERVAL}s")
    abort_orphans(s3, bucket)
    while True:
        try:
            cycle(s3, bucket, http)
        except Exception as e:  # one bad cycle never kills the loop; the next one retries
            log(f"cycle failed: {e!r}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Pin the dependencies**

Generate the hashes inside the Dockerfile's pinned image (Docker on the Mac, or a throwaway container on devvm):
```bash
printf 'boto3\nrequests\nzstandard\n' | docker run --rm -i --platform linux/amd64 \
  python:3.13-slim@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb sh -c \
  'cd /tmp && cat > requirements.in && pip install -q --root-user-action=ignore pip-tools >/dev/null &&
   pip-compile -q --generate-hashes --strip-extras --no-header requirements.in && cat requirements.txt' \
  > /tmp/requirements.txt
```
Then write `dist/requirements.txt` as this header followed by the whole of `/tmp/requirements.txt`:
```
# Hash-pinned dependencies of dist/mirror.py (the agentos-dist Girder worker), installed by
# dist/Dockerfile with `pip install --require-hashes`. Direct: boto3, requests, zstandard.
# Regenerate in the Dockerfile's pinned image (from the repo root):
#   printf 'boto3\nrequests\nzstandard\n' | docker run --rm -i --platform linux/amd64 \
#     python:3.13-slim@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb sh -c \
#     'cd /tmp && cat > requirements.in && pip install -q --root-user-action=ignore pip-tools >/dev/null &&
#      pip-compile -q --generate-hashes --strip-extras --no-header requirements.in && cat requirements.txt' \
#     > /tmp/requirements.txt
# then replace everything below this comment with /tmp/requirements.txt.
```
(`{ cat header.txt; cat /tmp/requirements.txt; } > dist/requirements.txt`, with the nine header lines above in `header.txt`.)

Expected pins (2026-10-30; a later run may resolve newer patch versions, which is fine if Step 6 passes): `boto3==1.43.122`, `botocore==1.43.122`, `certifi==2026.10.23`, `charset-normalizer==3.5.2`, `idna==3.20`, `jmespath==1.1.0`, `python-dateutil==2.9.0.post0`, `requests==2.34.2`, `s3transfer==0.19.3`, `six==1.17.0`, `urllib3==2.8.0`, `zstandard==0.25.0`. Check: `grep -cE '^[a-z]' dist/requirements.txt` prints `12`, and every pin has at least one `--hash=sha256:` line.

- [ ] **Step 5: Write the Dockerfile**

`dist/Dockerfile`:
```dockerfile
# The agentos-dist Girder worker (dist/mirror.py). Built from the repo root: girder app_config dockerfile=dist/Dockerfile.
FROM python:3.13-slim@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb
COPY dist/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --root-user-action=ignore --require-hashes -r /app/requirements.txt
COPY dist/mirror.py /app/mirror.py
USER 65534
CMD ["python", "-u", "/app/mirror.py"]
```

Girder builds it from the repo root (`app_config dockerfile=dist/Dockerfile` passes `-f`), so the `COPY` paths are repo-relative. `USER 65534` is `nobody`; the mirror writes nothing locally.

- [ ] **Step 6: Run the tests, then build and start the image**

Run: `python3 -m venv /tmp/agentos-dist-venv && /tmp/agentos-dist-venv/bin/pip install -q --require-hashes -r dist/requirements.txt && /tmp/agentos-dist-venv/bin/pip install -q pytest 'moto[s3]>=5,<6' && /tmp/agentos-dist-venv/bin/python -m pytest -v dist`
Expected:
```
dist/test_mirror.py::test_new_release_is_mirrored PASSED
dist/test_mirror.py::test_same_version_again_does_nothing PASSED
dist/test_mirror.py::test_release_without_iso_line_checks_the_compressed_hash_only PASSED
dist/test_mirror.py::test_split_release PASSED
dist/test_mirror.py::test_hash_mismatch_publishes_nothing_and_keeps_the_previous_version[bad0] PASSED
dist/test_mirror.py::test_hash_mismatch_publishes_nothing_and_keeps_the_previous_version[bad1] PASSED
dist/test_mirror.py::test_non_github_asset_url_is_refused PASSED
dist/test_mirror.py::test_draft_prerelease_and_odd_tags_are_skipped PASSED
dist/test_mirror.py::test_previous_version_deleted_only_after_publishing PASSED
dist/test_mirror.py::test_orphaned_multipart_uploads_are_aborted_at_startup PASSED
dist/test_mirror.py::test_index_html_escapes_every_value PASSED
11 passed
```

Run: `tar -c dist | docker build -q --platform linux/amd64 -f dist/Dockerfile -t agentos-dist-check - && docker run --rm --platform linux/amd64 agentos-dist-check 2>&1 | tail -1; docker run --rm --platform linux/amd64 -w /app agentos-dist-check python -c 'import mirror, zstandard, boto3; print("ok", zstandard.__version__, boto3.__version__)'; docker rmi agentos-dist-check`
Expected: the build succeeds (the `--require-hashes` install passes); the first run ends with `KeyError: 'S3_ENDPOINT'` (no S3 service outside Girder); the second prints `ok 0.25.0 1.43.122`. The tar of `dist/` stands in for the repo root that Girder uses as the context (the Dockerfile only copies from `dist/`), without sending the checkout's 277 MB.

- [ ] **Step 7: Run the tests in CI**

In `.github/workflows/build.yml`, step "Lint and unit tests", after the line Task 1 added:
```
          test/convert_test.sh
```
add:
```
          # dist/mirror.py (the dl.currentbits.net mirror): its pinned dependencies, then moto for a fake S3.
          python3 -m venv "$RUNNER_TEMP/dist-venv"
          "$RUNNER_TEMP/dist-venv/bin/pip" install -q --require-hashes -r dist/requirements.txt
          "$RUNNER_TEMP/dist-venv/bin/pip" install -q pytest 'moto[s3]>=5,<6'
          "$RUNNER_TEMP/dist-venv/bin/python" -m pytest -q dist
```
The runner's `python3` is 3.12.3 (Ubuntu 24.04); `dist/requirements.txt` has its wheels' hashes too (fact table).

Run: `uv run -q --with pyyaml python -c 'import yaml; d = yaml.safe_load(open(".github/workflows/build.yml")); print([s for s in d["jobs"]["build"]["steps"] if s.get("name") == "Lint and unit tests"][0]["run"].splitlines()[-1])'`
Expected: `"$RUNNER_TEMP/dist-venv/bin/python" -m pytest -q dist`

- [ ] **Step 8: Commit**

```bash
git add dist/mirror.py dist/test_mirror.py dist/requirements.txt dist/Dockerfile .github/workflows/build.yml
git commit -m "feat(dist): agentos-dist mirrors the latest release's installer to dl.currentbits.net as one .iso"
```

---

### Task 3: The README points to the `.iso`

**Files:**
- Modify: `README.md` (Install, Repository layout, Releasing)

**Interfaces:**
- Consumes: the page URL `https://dl.currentbits.net/agentos/index.html` (Task 2) and the `.iso` line in `SHA256SUMS` (Task 1).
- Produces: nothing other tasks use.

- [ ] **Step 1: Check that the README doesn't mention it yet**

Run: `grep -c 'dl.currentbits.net' README.md`
Expected: `0` (grep exits 1).

- [ ] **Step 2: Edit the Install section**

Find:
```markdown
| File | Use it for |
|---|---|
| `agentos-installer-<v>.img.zst` | **Bare metal.**
```
and insert one row directly above the `agentos-installer-<v>.img.zst` row, so the table begins:
```markdown
| File | Use it for |
|---|---|
| [`agentos-installer-<v>.iso`](https://dl.currentbits.net/agentos/index.html) | **Bare metal, the simplest way.** The installer as one direct download from `dl.currentbits.net`: no parts, nothing to decompress. Write it to a USB stick (`dd`, Etcher), attach it as a virtual CD (iDRAC/iLO/IPMI virtual media), or as the CD/DVD of a Proxmox, VMware or Hyper-V VM, then boot in UEFI mode. Latest release only; its SHA-256 is in the release's `SHA256SUMS`. |
| `agentos-installer-<v>.img.zst` | **Bare metal.** …
```
(the `.img.zst` row and the rows after it stay as they are).

- [ ] **Step 3: Edit Repository layout and Releasing**

In "Repository layout", find:
```markdown
| `tools/` | `build-deb.sh`, `apt-publish.sh`, `build-installer.sh`, `convert.sh`, `solenta-bridge`. |
```
and add after it:
```markdown
| `dist/` | `agentos-dist`, the Girder worker that mirrors each release's installer to `dl.currentbits.net` as one `.iso`. |
```

In "Releasing (maintainers)", find:
```markdown
3. The release job builds and tests everything, publishes the GitHub release (images, installer, checksums), and publishes the signed `agentos` package and notes to the apt repo on `gh-pages`.
```
and replace it with:
```markdown
3. The release job builds and tests everything, publishes the GitHub release (images, installer, checksums), and publishes the signed `agentos` package and notes to the apt repo on `gh-pages`. Within 15 minutes, `agentos-dist` (`dist/`, on Girder) mirrors the installer to [dl.currentbits.net](https://dl.currentbits.net/agentos/index.html) as one `.iso`, after checking it against `SHA256SUMS`.
```

- [ ] **Step 4: Check**

Run: `grep -c 'dl.currentbits.net/agentos/index.html' README.md && grep -c '^| `dist/`' README.md`
Expected: `2` then `1`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README links the installer .iso on dl.currentbits.net"
```

---

## Operator steps (the controller runs these; not an implementer task)

Run after Tasks 1–3 are merged into the branch Girder deploys from. Girder MCP tools (or the `girder` CLI) as in the girder-deploy skill.

1. **Create the app:** `create_app {name: "agentos-dist"}`; `app_config {app: "agentos-dist", key: "kind", value: "worker"}`; `app_config {app: "agentos-dist", key: "dockerfile", value: "dist/Dockerfile"}`.
2. **Storage and domain:** `services_add {app: "agentos-dist", type: "s3"}`; then `domains_add {app: "agentos-dist", host: "dl.currentbits.net", kind: "download"}` (needs the S3 service first; DNS and TLS are automatic; not proxied).
3. **Environment:** `app_env_set` `GITHUB_REPO=currentbits/agentos`, `PREFIX=agentos/`, `INTERVAL=900` (the defaults, set explicitly so they are visible). Check `app_env_list {app: "agentos-dist"}` lists `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` after the first deploy; if not, redeploy (S3 variables are injected on the deploy after `services_add`).
4. **Deploy:** push this repo to the app's Girder git remote (girder-deploy skill), after `services_add`, so the first deploy already has the `S3_*` variables; an empty commit pushed again redeploys.
5. **First cycle** (`app_logs {app: "agentos-dist"}`): expect `agentos-dist: currentbits/agentos -> s3://<bucket>/agentos/ every 900s`, `mirroring 1.0.1 (bucket has None)`, `source: agentos-installer-1.0.1.img.zst.part00, agentos-installer-1.0.1.img.zst.part01; iso hash not in SHA256SUMS (release predates it)`, 66 `part N` lines, `compressed 2491492354 bytes sha256 d5ee16b9042d599e540d5552359f1ceb8f25a6265ba72861be54bbc4327e5cec; iso … bytes sha256 …`, then `published agentos/agentos-installer-1.0.1.iso.sha256`, `published agentos/index.html`, `published agentos/latest.json`. The next cycle logs `up to date: 1.0.1`. If the first cycle fails (for example on egress to GitHub), the error is one `cycle failed:` line and it retries in 15 minutes.
6. **Check the download:**
   ```bash
   curl -fsS https://dl.currentbits.net/agentos/latest.json
   curl -fsS https://dl.currentbits.net/agentos/index.html | head -20
   curl -fsSO https://dl.currentbits.net/agentos/agentos-installer-1.0.1.iso
   curl -fsSO https://dl.currentbits.net/agentos/agentos-installer-1.0.1.iso.sha256
   sha256sum -c agentos-installer-1.0.1.iso.sha256
   ```
   Expected: `agentos-installer-1.0.1.iso: OK`; `latest.json`'s `size` equals `stat -c%s agentos-installer-1.0.1.iso` (about 4.39 GB) and its `sha256` the `.sha256` file's hash.
7. **Boot it as a CD** on devvm: copy the downloaded `.iso` there (`/var/tmp`), then `INSTALL_MEDIA=cd TMPDIR=/var/tmp test/install-test.sh /var/tmp/agentos-installer-1.0.1.iso` (the El Torito CD path CI runs for every release), or `test/installer-boot-test.sh /var/tmp/agentos-installer-1.0.1.iso`.
8. **Storage:** `backup_coverage` / `nodes` for `data-1` and `backup-1` free space after the next nightly backup: the bucket should hold about 4.4 GB, and peak at 8.8 GB only while a new release is switching in.
9. **Next release:** the first release built with Task 1 has the `.iso` line, and its log shows `iso hash from SHA256SUMS`; after the switch, the previous `.iso` and `.sha256` are gone (`deleted agentos/agentos-installer-1.0.1.iso`).

## Spec coverage

| Spec item | Task (test) |
|---|---|
| URL `dl.currentbits.net`, Girder app `agentos-dist`, own bucket, download-kind domain, not proxied | Operator steps 1–2 |
| Pull model; GitHub holds no Girder secrets; unauthenticated API, 4 requests an hour | 2 (`mirror.cycle`, `INTERVAL=900`); no workflow secret added |
| Latest `.iso` only; VM images stay on GitHub, linked from the page | 2 (`test_new_release_is_mirrored`: VM asset links; `test_previous_version_deleted_only_after_publishing`: one version left) |
| Peak 8.8 GB, at most one `.iso` plus one during a switch | 2 (delete after publish), Operator step 8 |
| §1 `.iso` line in `SHA256SUMS`, `.iso` not uploaded, attested, `--ignore-missing` works | 1 (`convert_test.sh`: line equals the installer's hash, no `.iso` file, `sha256sum -c --ignore-missing` passes) |
| §1 `README-download.txt` names the `.iso`, `dl.currentbits.net`, "decompressed" | 1 (`convert_test.sh`) |
| §2 package files, hash-pinned requirements | 2 (Steps 3–5; `--require-hashes` in the Dockerfile and CI) |
| §2 worker, S3 service, `dockerfile=dist/Dockerfile`; env `S3_*`, `GITHUB_REPO`, `PREFIX`, `INTERVAL` | 2 (`s3_client`, constants), Operator steps 1–3; fact table (exact `S3_*` names) |
| Cycle 1: drafts, prereleases, tag pattern, `V` | 2 (`test_draft_prerelease_and_odd_tags_are_skipped`) |
| Cycle 2: `latest.json` has `V` → stop | 2 (`test_same_version_again_does_nothing`: only the API call, bucket unchanged) |
| Cycle 3: `SHA256SUMS`, `.img.zst` required, `.iso` optional | 2 (`test_release_without_iso_line_checks_the_compressed_hash_only`, `test_hash_mismatch…[bad1]`) |
| Cycle 4: parts in order or whole file; GitHub hosts only; hash compressed; stream-decompress; 64 MiB multipart; no local disk | 2 (`test_split_release` checks the order; `test_new_release_is_mirrored` whole file, 7 parts; `test_non_github_asset_url_is_refused`); adjustment 1 |
| Cycle 5: both hashes; abort on mismatch or error; previous version untouched; retry next cycle | 2 (`test_hash_mismatch…[bad0]`, `[bad1]`: bucket unchanged, no uploads left; `main`'s loop) |
| Cycle 6: publish `.sha256`, `index.html`, `latest.json` in order, with the listed fields | 2 (`test_new_release_is_mirrored`: exact `.sha256` and `latest.json`; order in `cycle`); adjustment 3 |
| Cycle 7: delete other versions | 2 (`test_previous_version_deleted_only_after_publishing`: `latest.json` written before the first delete) |
| Robustness: one cycle at a time; failures never kill the loop; one log line per step with sizes and hashes; orphaned uploads aborted at startup | 2 (`main`: single loop, `except Exception`; `log` lines; `test_orphaned_multipart_uploads_are_aborted_at_startup`); adjustment 7 |
| `index.html` content, no scripts, every value escaped | 2 (`test_new_release_is_mirrored` content checks, `test_index_html_escapes_every_value`) |
| §3 Girder setup | Operator steps 1–5 |
| §4 README and release-notes links | 1 (`README-download.txt` is prepended to the release notes by the release job), 3 |
| §5 unit tests (9 listed) | 2 (11 tests: the nine, plus skipped tags and the no-`.iso`-line release; adjustment 8) |
| §5 `convert.sh` test | 1 |
| §5 live: v1.0.1 mirrored, download hash, CD boot, storage | Operator steps 5–8 |

## Self-review

- **Spec coverage:** every row above maps to a task, a test or an operator step. Deviations are listed under "Spec adjustments", each with its evidence.
- **Placeholders:** none. Every new file is complete. `dist/requirements.txt` is generated by an exact command whose output was reproduced byte for byte; its header is given in full. Edits to existing files give the exact text to find and its replacement.
- **Names and types across tasks:**
  - The `.iso` name `agentos-installer-<V>.iso` is the same in `convert.sh` (Task 1), `convert_test.sh`, `mirror.cycle` (`iso`), the tests (`release(...)`) and the README (Task 3).
  - The page URL `https://dl.currentbits.net/agentos/index.html` is the same in `convert.sh`, `convert_test.sh`, the README and the operator steps; `PREFIX=agentos/` makes the key `agentos/index.html`.
  - `cycle(s3, bucket, http)`, `abort_orphans(s3, bucket)`, `index_html(v, iso, size, sha, published, release_url, others)`, `check_url(url)` and `PART` match between `mirror.py` and `test_mirror.py`.
  - The `S3_*` names in `s3_client` are the five `app_env_list` returned.
- **Ordering:** Task 1 stands alone (bash only). Task 2 doesn't need Task 1 to pass its tests (they cover releases with and without the `.iso` line). Task 3 is docs. The workflow edit is split so each task's CI step list is valid on its own.
- **Known limits (deliberate):** the bucket listing for deletes reads one page (a handful of objects, `ponytail:` comment); a redeploy that briefly overlaps two containers lets the new one abort the old one's in-flight upload at startup, which the old one logs as a failed cycle and the new one redoes; `requests` follows the redirect before the final host is checked, so a hostile redirect target would see one request but none of its body is used (and the hashes would catch it anyway).
