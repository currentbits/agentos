import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

CI_DIR = Path(__file__).resolve().parents[2] / "package/usr/local/lib/agentos/ci"
sys.path.insert(0, str(CI_DIR))


@pytest.fixture
def home(tmp_path, monkeypatch):
    h = (tmp_path / "home").resolve()
    h.mkdir()
    monkeypatch.setenv("HOME", str(h))
    monkeypatch.setenv("AGENTOS_CI_MAX_PARALLEL", "2")
    return h


def sh(*args, cwd=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@x")
    return subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def make_repo(path: Path, files: dict) -> Path:
    path.mkdir(parents=True)
    sh("git", "init", "-q", "-b", "main", cwd=path)
    for name, text in files.items():
        f = path / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    sh("git", "add", "-A", cwd=path)
    sh("git", "commit", "-qm", "init", cwd=path)
    return path


def wait_final(run_id, timeout=60):
    from agentos_ci import runs
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        run = runs.status(run_id)
        if run["status"] in runs.FINAL:
            return run
        time.sleep(0.2)
    raise AssertionError(f"run {run_id} still {runs.status(run_id)['status']}")


def ci_yml(*steps, extra=""):
    body = "".join(f"  - name: {n}\n    run: {r!r}\n" for n, r in steps)
    return f"{extra}steps:\n{body}"
