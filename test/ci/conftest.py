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


def wait_until_execed(pid, timeout=5):
    """Block until `pid` is no longer the bash process itself.

    Tests that simulate a stuck worker spawn `bash -c "trap '' TERM; sleep N"`: bash forks, runs
    the trap builtin (installing real SIG_IGN, which survives exec), then execs directly into
    `sleep` as its last command -- replacing its own image, keeping the same pid. Sending SIGTERM
    in the (brief but real) gap before that exec finishes hits bash's own, still-default,
    disposition instead of the trap, killing it outright -- a race observed in practice on real
    VMs, not just a theoretical one. Linux only (no /proc on macOS, same as runs.alive()); falls
    back to a short fixed wait there."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            comm = open(f"/proc/{pid}/stat").read().split("(", 1)[1].rsplit(")", 1)[0]
        except OSError:
            time.sleep(0.3)
            return
        if comm != "bash":
            return
        time.sleep(0.01)
    raise AssertionError(f"pid {pid} still bash after {timeout}s")


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
