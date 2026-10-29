import os
import stat
import sys
from pathlib import Path

import pytest
from conftest import CI_DIR, ci_yml, make_repo, sh, wait_final
from agentos_ci import remotes, runs
from agentos_ci.runs import CIError


@pytest.mark.parametrize("bad", ["", "-x", "A", "a_b", "a.b", "../x", "a" * 64, "x/y", "a b"])
def test_remote_names(home, bad):
    with pytest.raises(CIError, match="name must match"):
        remotes.create(bad)


def test_create_and_list(home, monkeypatch):
    monkeypatch.setattr(remotes, "box_host", lambda: "box.tail.ts.net")
    r = remotes.create("demo-1")
    assert r == {"name": "demo-1", "path": str(home / "git/demo-1.git"),
                 "remote_add": "git remote add agentos agent@box.tail.ts.net:git/demo-1.git"}
    hook = home / "git/demo-1.git/hooks/post-receive"
    assert hook.is_symlink() and os.readlink(hook) == str(CI_DIR / "post-receive")
    assert os.stat(CI_DIR / "post-receive").st_mode & stat.S_IXUSR
    with pytest.raises(CIError, match="already exists"):
        remotes.create("demo-1")
    (home / "git/Bad.git").mkdir()
    assert [x["name"] for x in remotes.list_remotes()] == ["demo-1"]


def test_create_removes_half_made_repo_on_hook_failure(home, monkeypatch):
    # If the hook-symlink step fails after `git init`, a half-made repo must not be left behind
    # (it would otherwise block every future `create("broken")` with "already exists" forever).
    def boom(self, *a, **k):
        raise OSError("disk exploded")

    monkeypatch.setattr(Path, "symlink_to", boom)
    with pytest.raises(OSError):
        remotes.create("broken")
    assert not (home / "git/broken.git").exists()


def launcher(tmp_path, record=None):
    """An agentos-ci for the hook: the real CLI, or a recorder that prints a fake id."""
    f = tmp_path / "agentos-ci"
    if record:
        f.write_text(f'#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done >> {record}\necho 20260101-000000-0000\n')
    else:
        f.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{CI_DIR / "main.py"}" "$@"\n')
    f.chmod(0o755)
    return f


def test_hook_runs_ci_per_branch_and_reports_the_id(home, tmp_path, monkeypatch):
    monkeypatch.setattr(remotes, "box_host", lambda: "box")
    remote = remotes.create("app")["path"]
    src = make_repo(tmp_path / "src", {".agentos/ci.yml": ci_yml(("t", "test -f .agentos/ci.yml"))})
    import subprocess
    sh("env", f"AGENTOS_CI={launcher(tmp_path)}", f"HOME={home}", "git", "push", remote, "main",
       "main:refs/heads/feature/x", cwd=src)
    r = subprocess.run(["env", f"AGENTOS_CI={launcher(tmp_path)}", f"HOME={home}", "git", "push", "--force", remote,
                        "main:refs/heads/again"], cwd=src, capture_output=True, text=True)
    assert "agentos-ci: run " in r.stderr and "for again" in r.stderr
    ids = [r["id"] for r in runs.list_runs()]
    assert len(ids) == 3
    for rid in ids:
        run = wait_final(rid)
        assert run["status"] == "passed" and run["source"] == "push" and run["repo"] == remote
    assert sorted(runs.status(i)["ref"] for i in ids) == ["refs/heads/again", "refs/heads/feature/x", "refs/heads/main"]


def test_hook_closes_cis_stdin(home, tmp_path):
    # post-receive's own `while read -r _old new ref` loop reads ref updates from its stdin; "$CI"
    # must not share that pipe, or a descendant that reads stdin (even just once, even
    # accidentally) could steal a line meant for the next ref, corrupting a multi-ref push.
    f = tmp_path / "agentos-ci"
    rec = tmp_path / "stdin-seen"
    f.write_text(f'#!/bin/sh\nIFS= read -r line; printf "%s\\n" "${{line:-<empty>}}" >> {rec}\necho 20260101-000000-0000\n')
    f.chmod(0o755)
    remote = remotes.create("stdincheck")["path"]
    src = make_repo(tmp_path / "src", {"a": "1"})
    import subprocess
    r = subprocess.run(["env", f"AGENTOS_CI={f}", "git", "push", remote, "main:refs/heads/one", "main:refs/heads/two"],
                       cwd=src, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stderr.count("agentos-ci: run ") == 2             # both refs reached the hook's loop
    assert rec.read_text().splitlines() == ["<empty>", "<empty>"]


def test_hook_never_evaluates_ref_names(home, tmp_path):
    rec = tmp_path / "argv"
    remote = remotes.create("evil")["path"]
    src = make_repo(tmp_path / "src", {"a": "1"})
    import subprocess
    # Legal git branch names that a shell would execute: the hook runs in the bare repo, so a
    # successful injection would leave a "pwned" file there.
    r = subprocess.run(["env", f"AGENTOS_CI={launcher(tmp_path, rec)}", "git", "push", remote,
                        "main:refs/heads/$(id>pwned)", "main:refs/heads/`id>pwned`", "main:refs/heads/ok;id>pwned",
                        "main:refs/heads/fine", "main:refs/tags/v1"], cwd=src, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert not (tmp_path / "home/git/evil.git/pwned").exists()
    assert r.stderr.count("agentos-ci: skipped") == 4
    assert rec.read_text().splitlines() == ["run", "--source", "push", "--ref", "refs/heads/fine", "--", remote]
    # deleting a branch starts nothing
    rec.unlink()
    subprocess.run(["env", f"AGENTOS_CI={launcher(tmp_path, rec)}", "git", "push", remote, ":refs/heads/fine"],
                   cwd=src, capture_output=True, check=True)
    assert not rec.exists()
