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
