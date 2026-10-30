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
    def __init__(self, url, status, headers, body):
        self.url, self.status_code, self.headers, self.body = url, status, headers, body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass

    def close(self):
        pass

    def raise_for_status(self):
        if self.body is None:
            raise RuntimeError(f"{self.status_code} {self.url}")

    def iter_content(self, n):
        return (self.body[i:i + n] for i in range(0, len(self.body), n))


class FakeGitHub:
    """Release asset URLs on github.com answer with a real 302 to release-assets.githubusercontent.com
    (Location header, empty body), like GitHub's actual redirect; mirror.py must follow it itself."""

    def __init__(self):
        self.files, self.calls, self.redirects = {}, [], {}

    def get(self, url, stream=True, timeout=None, allow_redirects=False):
        self.calls.append(url)
        target = self.redirects.get(url)
        if target is not None:
            return Resp(url, 302, {"Location": target}, None)
        return Resp(url, 200 if url in self.files else 404, {}, self.files.get(url))


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
    for n, b in assets.items():
        dl_url = f"{DL}/v{v}/{n}"
        asset_url = f"{ASSETS}/{n}"
        gh.redirects[dl_url] = asset_url
        gh.files[asset_url] = b
    gh.files[API] = json.dumps({
        "tag_name": f"v{v}", "draft": False, "prerelease": False,
        "html_url": f"https://github.com/currentbits/agentos/releases/tag/v{v}", "published_at": "2026-10-30T12:39:00Z",
        "assets": [{"name": n, "browser_download_url": f"{DL}/v{v}/{n}"} for n in assets],
    }).encode()


IMG1 = os.urandom(20000) + b"\0" * 30000 + b"one"  # 50003 bytes: 7 parts of 8 KiB
IMG2 = os.urandom(9000) + b"two"


@pytest.fixture(autouse=True)
def _reset_backoff_state():
    """mirror._failed is process-memory global state (the hash-mismatch backoff); without this it
    leaks between tests that happen to mirror the same version, in whichever order pytest runs them."""
    mirror._failed.clear()
    yield
    mirror._failed.clear()


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
    # Each part is requested on github.com, then its redirect hop; filtering to the first hop
    # checks the parts were fetched in order (the redirect-hop fix means gh.calls now also holds
    # the release-assets.githubusercontent.com hop that follows each one).
    assert [u for u in gh.calls if u.startswith(DL) and ".img.zst" in u] == [
        f"{DL}/v1.0.2/agentos-installer-1.0.2.img.zst.part00", f"{DL}/v1.0.2/agentos-installer-1.0.2.img.zst.part01"]


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


def test_date_shaped_tag_is_not_mirrored(s3):
    """A weekly dev build's tag (v<year>.<month>.<day>) must never be mirrored -- it has three
    dot-separated numeric parts like a real vX.Y.Z release, but GitHub would mark it "latest" and
    this mirror would then serve a dev build (update source disabled) as the download page's .iso."""
    gh = FakeGitHub()
    release(gh, "2026.11.02", IMG1)
    mirror.cycle(s3, BUCKET, gh)
    assert keys(s3) == []


def test_cycle_aborts_orphaned_uploads_every_time_not_only_at_startup(s3):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    up = s3.create_multipart_upload(Bucket=BUCKET, Key=mirror.PREFIX + "leftover")["UploadId"]
    s3.upload_part(Bucket=BUCKET, Key=mirror.PREFIX + "leftover", UploadId=up, PartNumber=1, Body=b"x" * 100)
    mirror.cycle(s3, BUCKET, gh)
    assert uploads(s3) == []
    assert get(s3, "agentos/agentos-installer-1.0.1.iso") == IMG1


def test_malicious_redirect_hop_is_refused_before_any_request(s3):
    """check_url must be run on each redirect hop before it is followed, not just on the final URL
    after requests has already followed the chain: a hijacked redirect target is refused up front."""
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    zst_url = f"{DL}/v1.0.1/agentos-installer-1.0.1.img.zst"
    gh.redirects[zst_url] = "https://evil.example/agentos-installer-1.0.1.img.zst"
    with pytest.raises(ValueError, match="outside GitHub"):
        mirror.cycle(s3, BUCKET, gh)
    assert "https://evil.example/agentos-installer-1.0.1.img.zst" not in gh.calls
    assert keys(s3) == []


def test_a_bad_link_in_the_release_is_skipped_in_index_html_not_fatal(s3):
    """check_url runs on every link going into index.html (the VM image links and the release-notes
    link); a bad one is skipped and logged, not fetched, and does not stop the rest of the page."""
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    rel = json.loads(gh.files[API])
    for a in rel["assets"]:
        if a["name"] == "agentos-1.0.1.qcow2.part00":
            a["browser_download_url"] = "https://evil.example/agentos-1.0.1.qcow2.part00"
    gh.files[API] = json.dumps(rel).encode()
    mirror.cycle(s3, BUCKET, gh)
    assert "https://evil.example/agentos-1.0.1.qcow2.part00" not in gh.calls
    page = get(s3, "agentos/index.html").decode()
    assert "evil.example" not in page
    assert "agentos-1.0.1.vmdk.zst" in page  # the other VM link is still published


def test_hash_mismatch_backs_off_then_retries_after_RETRY_AFTER(s3, monkeypatch):
    gh = FakeGitHub()
    release(gh, "1.0.1", IMG1)
    mirror.cycle(s3, BUCKET, gh)
    release(gh, "1.0.2", IMG2, iso_hash="2" * 64)
    clock = [1000.0]
    monkeypatch.setattr(mirror.time, "monotonic", lambda: clock[0])
    with pytest.raises(ValueError, match="sha256"):
        mirror.cycle(s3, BUCKET, gh)
    gh.calls.clear()
    mirror.cycle(s3, BUCKET, gh)  # still inside the backoff window: no retry, no error
    assert gh.calls == [API]
    clock[0] += mirror.RETRY_AFTER + 1
    gh.calls.clear()
    with pytest.raises(ValueError, match="sha256"):
        mirror.cycle(s3, BUCKET, gh)  # window elapsed: retries and fails again
    assert any(".img.zst" in u for u in gh.calls)


def test_index_html_escapes_every_value():
    page = mirror.index_html("1.0.1", "a<b>.iso", 10, '"sha"', "2026-10-30T00:00:00Z", "https://x/?a=1&b=2",
                             [("<script>alert(1)</script>", 'https://github.com/"onmouseover="x')])
    assert "<script>" not in page and "<b>" not in page and '"onmouseover' not in page
    assert "&lt;script&gt;" in page and "a&lt;b&gt;.iso" in page and "&quot;sha&quot;" in page and "a=1&amp;b=2" in page
