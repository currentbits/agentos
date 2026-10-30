# AgentOS downloads on dl.currentbits.net (Girder)

Date: 2026-10-30. Status: approved design.

## Goal

Offer the AgentOS installer as a single, unsplit, directly downloadable `.iso` at `https://dl.currentbits.net/agentos/`, served by Girder. GitHub releases stay the source of truth and keep every format.

## Decisions (from brainstorming)

- **URL:** `dl.currentbits.net`, through a new Girder app `agentos-dist` with its own S3 bucket and a download-kind domain. Download domains bypass Cloudflare, which suits multi-GB files.
- **Sync model:** Girder pulls from GitHub releases. GitHub holds no Girder or tailnet secrets.
- **Contents:** the latest release's `.iso` only (4.4 GB).
  - The installer image already boots from USB (`dd`, Etcher) and as a virtual CD (El Torito). The `.iso` name is what Proxmox, VMware, Hyper-V and BMC virtual-media pickers expect.
  - The VM images stay on GitHub, linked from the download page.
- **Storage budget:**
  - `data-1` (Garage S3, Postgres, every app) had 26 GB free.
  - `backup-1` had 23 GB free, and the nightly backup mirrors every bucket there.
  - So the bucket holds at most one `.iso`, plus a second one only during a switch: peak 8.8 GB.
  - Resizing `data-1` was tried and refused by Hetzner (no cx43 capacity in fsn1). It is not part of this design.

**Non-goals:** mirroring the VM formats, keeping older versions, editing the currentbits.net site (a separate app and repo, done as its own step), and a CDN.

## 1. `.iso` checksum in the release (`tools/convert.sh`)

- `convert.sh` already receives the uncompressed installer image (`installer.raw`). It adds the image's SHA-256 to `SHA256SUMS` under the name `agentos-installer-<v>.iso`. The `.iso` file itself is **not** uploaded to GitHub, since it would be 4.4 GB in parts.
- `SHA256SUMS` is already covered by the release's build-provenance attestation. The `.iso` hash is therefore attested too, and `sha256sum -c --ignore-missing SHA256SUMS` still works on GitHub downloads.
- `README-download.txt` says that the `.iso` is available at `dl.currentbits.net` and that it is the decompressed `.img`.

## 2. The mirror (`dist/` in this repo, Girder app `agentos-dist`)

- **Package:** `dist/mirror.py` (Python 3, `boto3`, `zstandard`, `requests`), `dist/Dockerfile`, and `dist/requirements.txt` (hash-pinned).
- **App setup:** worker kind (no port), with an S3 service and `app_config dockerfile=dist/Dockerfile`.
- **Configuration (environment):**
  - from Girder's S3 service: `S3_*`;
  - `GITHUB_REPO=currentbits/agentos`;
  - `PREFIX=agentos/`;
  - `INTERVAL=900`.
- **Each cycle:**
  1. `GET https://api.github.com/repos/currentbits/agentos/releases/latest`, unauthenticated (4 requests an hour, well under GitHub's limit). Ignore drafts and prereleases. The tag must match `^v[0-9]+\.[0-9]+\.[0-9]+$`. Version `V` is the tag without its `v`.
  2. Read `agentos/latest.json` from the bucket. If its version is `V`, stop.
  3. Download `SHA256SUMS` from the release, and parse the lines for `agentos-installer-V.img.zst` (required) and `agentos-installer-V.iso` (present from the next release on).
  4. Stream the installer: fetch the `.img.zst` parts (or the whole file, if it isn't split), concatenated in order. Download URLs must be on `github.com` or `objects.githubusercontent.com`.
     - Hash the compressed stream.
     - Decompress it with `zstandard` in streaming mode.
     - Multipart-upload the decompressed stream to `agentos/agentos-installer-V.iso` (64 MiB parts), hashing it as it goes.
     - No local disk is used.
  5. Verify:
     - the compressed hash must equal the `.img.zst` line;
     - the `.iso` hash must equal the `.iso` line, when that line exists.

     On any mismatch or error, **abort the multipart upload** (nothing becomes visible), leave the previous version untouched, log the error, and retry next cycle.
  6. Publish, in this order:
     - `agentos/agentos-installer-V.iso.sha256` (`<hash>  agentos-installer-V.iso`);
     - `agentos/index.html`;
     - `agentos/latest.json`: `{version, iso, size, sha256, published, release_url}`.
  7. Delete the previous version's `.iso` and `.sha256`: everything under `agentos/` with a version other than `V`.
- **Robustness:**
  - One cycle at a time.
  - A failure in one cycle never kills the loop.
  - Logs are one line per step, with sizes and hashes.
  - Startup reports orphaned multipart uploads and aborts them, so space leaked by a crash is reclaimed.
- **`index.html`** is generated, static, and has no scripts. It shows:
  - the version and date, with a link to the GitHub release notes;
  - the `.iso` link, its size and its SHA-256, with a `sha256sum` verify line;
  - how to use it: USB (`dd`/Etcher), virtual CD/BMC, Proxmox/VMware/Hyper-V;
  - links to the other formats on the GitHub release.

  Every value is HTML-escaped.

## 3. Girder setup (operator steps, run once)

1. `create_app agentos-dist` (worker), then `services_add s3`.
2. `domains_add dl.currentbits.net kind=download`. DNS and TLS are automatic, and the domain is not proxied.
3. `app_config dockerfile=dist/Dockerfile`.
4. Push this repo to the app's Girder remote. Redeploy after the S3 service exists, so the `S3_*` environment variables are injected.
5. Check that `https://dl.currentbits.net/agentos/index.html` is served after the first cycle.

## 4. Links

- The README's install section and the GitHub release notes, through `README-download.txt`, point to `https://dl.currentbits.net/agentos/index.html` for the `.iso`.

## 5. Testing

- **Unit tests** (`dist/test_mirror.py`, pytest, moto S3, fake GitHub HTTP):
  - a new release is mirrored, and every hash, `latest.json` and `index.html` are correct;
  - the same version again does nothing;
  - a compressed-hash mismatch leaves no new object and the previous version intact;
  - an `.iso` hash mismatch behaves the same way;
  - a split release (two parts) works;
  - a non-GitHub asset URL is refused;
  - the previous version is deleted only after the new one is published;
  - orphaned multipart uploads are aborted at startup;
  - HTML escaping.
- **`convert.sh` test:** `SHA256SUMS` contains the `.iso` line, and its hash equals the hash of the installer image.
- **Live:** the first cycle mirrors v1.0.1, which has no `.iso` line, so only the compressed hash is checked. Then:
  - download the `.iso` from `dl.currentbits.net` and check that its hash matches `.sha256`;
  - boot it as a CD in QEMU/OVMF on devvm (`test/installer-boot-test.sh` with `INSTALL_MEDIA=cd`, or the equivalent);
  - confirm the bucket holds about 4.4 GB, and check disk usage on `data-1` and `backup-1` after the next nightly backup.
