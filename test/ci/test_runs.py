import json
import os
import re
import time
from pathlib import Path

import pytest
from conftest import ci_yml, make_repo, sh, wait_final
from agentos_ci import pipeline, runs
from agentos_ci.runs import CIError


def test_ids_are_monotonic_and_well_formed(home):
    ids = [runs.new_id() for _ in range(50)]
    assert ids == sorted(ids) and len(set(ids)) == 50
    assert all(re.fullmatch(r"\d{8}-\d{6}-[0-9a-f]{4}", i) for i in ids)


def test_paths_must_be_repos_inside_home(home, tmp_path):
    outside = make_repo(tmp_path / "outside", {"a": "1"})
    (home / "link").symlink_to(outside)
    (home / "plain").mkdir()
    for bad, why in [(outside, "inside"), (home / "link", "inside"), (home / "nope", "no such"),
                     (home / "plain", "not a git repository")]:
        with pytest.raises(CIError, match=why):
            runs.start(bad)
    repo = make_repo(home / "r", {"a": "1"})
    for ref in ("-x", "--output=/tmp/x", "a b", "HEAD;id", "", "HEAD\n"):
        with pytest.raises(CIError, match="invalid ref"):
            runs.start(repo, ref)
    with pytest.raises(CIError, match="unknown ref"):
        runs.start(repo, "no-such-branch")
    for bad in ("../x", "20260101-000000-zzzz", "x" * 30, "20260101-000000-0000\n"):
        with pytest.raises(CIError, match="invalid run id"):
            runs.status(bad)


def test_passing_run_states_and_logs(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("one", "echo first"), ("two", "echo second; pwd"))})
    rid = runs.start(repo / ".agentos")          # a subdirectory resolves to the repo
    first = runs.status(rid)
    assert first["status"] in ("queued", "running", "passed") and first["repo"] == str(repo)
    run = wait_final(rid)
    assert run["status"] == "passed" and run["pipeline"] == "ci.yml"
    assert [(s["name"], s["status"], s["exit_code"]) for s in run["steps"]] == [("one", "passed", 0), ("two", "passed", 0)]
    assert run["started"] and run["finished"] and run["commit"] == runs.git("rev-parse", "HEAD", cwd=repo)
    assert runs.logs(rid, "one")["text"] == "first\n"
    assert str(home / ".cache/agentos-ci/work" / rid) in runs.logs(rid, "two")["text"]
    assert not (home / ".cache/agentos-ci/work" / rid).exists()          # checkout removed
    assert runs.summary(run) == {"run_id": rid, "status": "passed", "failed_step": None, "log_tail": ""}


def test_failing_step_skips_the_rest_and_reports_its_tail(home):
    lines = "; ".join(f"echo line{i}" for i in range(300))
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("ok", "true"), ("bad", lines + "; false"), ("never", "touch /tmp/x"))})
    run = wait_final(runs.start(repo))
    assert run["status"] == "failed"
    assert [s["status"] for s in run["steps"]] == ["passed", "failed", "skipped"]
    s = runs.summary(run)
    assert s["failed_step"] == "bad" and s["log_tail"].splitlines() == [f"line{i}" for i in range(100, 300)]


def test_pipefail_and_exact_commit(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("p", "false | true"))})
    first = runs.git("rev-parse", "HEAD", cwd=repo)
    (repo / ".agentos/ci.yml").write_text(ci_yml(("p", "true")))
    sh("git", "commit", "-qam", "fix", cwd=repo)
    old = wait_final(runs.start(repo, first))
    assert old["status"] == "failed" and old["commit"] == first     # -o pipefail, and the old tree
    assert wait_final(runs.start(repo))["status"] == "passed"


def test_no_config_is_an_error_with_a_hint(home):
    run = wait_final(runs.start(make_repo(home / "r", {"README": "x"})))
    assert run["status"] == "error" and "no CI configuration found" in run["error"]
    assert runs.summary(run)["log_tail"].startswith("no CI configuration found")


def test_bare_repo(home):
    src = make_repo(home / "src", {".agentos/ci.yml": ci_yml(("t", "test -f .agentos/ci.yml"))})
    runs.git("clone", "-q", "--bare", str(src), str(home / "b.git"))
    assert wait_final(runs.start(home / "b.git", "main"))["status"] == "passed"


def test_clean_env_and_secrets_only_when_listed(home):
    (home / ".config/agentos").mkdir(parents=True)
    (home / ".config/agentos/secrets.env").write_text("ANTHROPIC_API_KEY=sk-secret-1\nNPM_TOKEN=npm-2==\n")
    os.environ["LEAKY_VAR"] = "leak"
    try:
        script = "env | sort; test \"$NPM_TOKEN\" = npm-2=="
        listed = make_repo(home / "a", {".agentos/ci.yml": "secrets: [NPM_TOKEN, MISSING_TOKEN]\n" + ci_yml(("e", script))})
        unlisted = make_repo(home / "b", {".agentos/ci.yml": ci_yml(("e", "env | sort"))})
        run = wait_final(runs.start(listed))
        env = runs.logs(run["id"], "e")["text"]
        assert run["status"] == "passed" and run["secrets"] == ["MISSING_TOKEN", "NPM_TOKEN"]
        assert run["missing_secrets"] == ["MISSING_TOKEN"]
        assert "sk-secret-1" not in env and "LEAKY_VAR" not in env
        assert f"AGENTOS_CI_RUN={run['id']}" in env and "CI=true" in env
        assert "npm-2==" not in (home / ".local/share/agentos-ci/runs" / run["id"] / "run.json").read_text()
        env2 = runs.logs(wait_final(runs.start(unlisted))["id"], "e")["text"]
        assert "NPM_TOKEN" not in env2 and "ANTHROPIC_API_KEY" not in env2
        keys = {line.split("=", 1)[0] for line in env2.splitlines() if "=" in line}
        assert keys <= {"PATH", "HOME", "LANG", "CI", "AGENTOS_CI_RUN", "PWD", "SHLVL", "_", "OLDPWD"}
    finally:
        del os.environ["LEAKY_VAR"]


def test_queue_respects_max_parallel(home, monkeypatch):
    monkeypatch.setenv("AGENTOS_CI_MAX_PARALLEL", "1")
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "sleep 2"))})
    a = runs.start(repo)
    b = runs.start(repo)
    deadline = time.monotonic() + 10
    while runs.status(a)["status"] != "running" and time.monotonic() < deadline:
        time.sleep(0.1)
    assert runs.status(a)["status"] == "running" and runs.status(b)["status"] == "queued"
    ra, rb = wait_final(a), wait_final(b)
    assert ra["status"] == rb["status"] == "passed" and rb["started"] >= ra["finished"]


def test_cancel_kills_the_process_group(home):
    pidfile = home / "child.pid"
    # bash -c runs without job control, so a background grandchild stays in the step's process
    # group (it does not get its own group); killpg on that group kills it too.
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", f"sleep 300 & echo $! > {pidfile}; wait"), ("after", "true"))})
    rid = runs.start(repo)
    deadline = time.monotonic() + 15
    while not pidfile.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    child = int(pidfile.read_text())
    run = runs.cancel(rid)
    assert run["status"] == "cancelled"
    assert [s["status"] for s in run["steps"]] == ["cancelled", "skipped"]
    time.sleep(0.5)
    assert not runs.alive(child)
    assert runs.cancel(rid)["status"] == "cancelled"                 # idempotent


def test_cancel_escalates_to_sigkill(home, monkeypatch):
    # Forwarded to the detached worker's env by start(), the same way AGENTOS_CI_MAX_PARALLEL is:
    # monkeypatching runs.KILL_GRACE here would only affect this test process, not the worker.
    monkeypatch.setenv("AGENTOS_CI_KILL_GRACE", "1")
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "trap '' TERM; echo ready; while :; do sleep 0.1; done"))})
    rid = runs.start(repo)
    deadline = time.monotonic() + 15
    while "ready" not in runs.logs(rid, None)["text"] and time.monotonic() < deadline:
        time.sleep(0.1)
    t = time.monotonic()
    run = runs.cancel(rid)
    elapsed = time.monotonic() - t
    assert run["status"] == "cancelled" and run["error"] is None     # the worker's own TERM->KILL, not cancel's fallback
    assert 0.9 <= elapsed < 6             # the worker's 1 s grace, well under cancel's own fallback (1 + 5 = 6s)


def test_cancel_a_queued_run(home, monkeypatch):
    monkeypatch.setenv("AGENTOS_CI_MAX_PARALLEL", "1")
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "sleep 3"))})
    a, b = runs.start(repo), runs.start(repo)
    assert runs.cancel(b)["status"] == "cancelled" and runs.status(b)["steps"] == []
    assert wait_final(a)["status"] == "passed"


def test_timeout_kills_the_step(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": "timeout: 1s\n" + ci_yml(("s", "sleep 30"))})
    t = time.monotonic()
    run = wait_final(runs.start(repo), timeout=20)
    assert run["status"] == "failed" and time.monotonic() - t < 15
    assert "timed out after 1s" in runs.logs(run["id"], "s")["text"]


def test_dead_worker_is_an_error(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("s", "sleep 30"))})
    rid = runs.start(repo)
    pid = int((home / ".local/share/agentos-ci/runs" / rid / "pid").read_text())
    time.sleep(0.5)
    os.kill(pid, 9)
    time.sleep(0.3)
    run = runs.status(rid)
    assert run["status"] == "error" and "exited unexpectedly" in run["error"]
    runs.killpg(int((home / ".local/share/agentos-ci/runs" / rid / "pgid").read_text()), 9)


def test_retention_keeps_the_newest_200_final_runs(home):
    rd = home / ".local/share/agentos-ci/runs"
    for i in range(205):
        d = rd / f"20260101-000000-{i:04x}"
        d.mkdir(parents=True)
        (d / "run.json").write_text(json.dumps({"id": d.name, "status": "running" if i == 0 else "passed"}))
    runs.prune()
    left = sorted(p.name for p in rd.iterdir())
    assert len(left) == 201 and left[0] == "20260101-000000-0000" and left[1] == "20260101-000000-0005"


def test_list_filters_by_repo(home):
    a = make_repo(home / "a", {".agentos/ci.yml": ci_yml(("t", "true"))})
    b = make_repo(home / "b", {".agentos/ci.yml": ci_yml(("t", "true"))})
    ra, rb = runs.start(a), runs.start(b)
    wait_final(ra), wait_final(rb)
    assert [r["id"] for r in runs.list_runs()] == [rb, ra]
    assert [r["id"] for r in runs.list_runs(a)] == [ra]
    assert [r["id"] for r in runs.list_runs(limit=1)] == [rb]


def test_spawn_failure_marks_the_run_error_not_queued_forever(home, monkeypatch):
    # A MAIN that doesn't exist makes python itself fail to spawn the worker (a nonzero exit,
    # not an OSError here): start() must not leave the run "queued" with nothing left to ever
    # move it out of that state.
    monkeypatch.setattr(runs, "MAIN", str(home / "no-such-main.py"))
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("t", "true"))})
    with pytest.raises(CIError, match="failed to spawn worker"):
        runs.start(repo)
    (run,) = runs.list_runs()
    assert run["status"] == "error" and "failed to spawn worker" in run["error"]


def test_image_step_docker_argv():
    """Pure unit test, no home/worker involved: pins the argv command() builds for an image: step."""
    p = pipeline.Pipeline("ci.yml", [], image="node:24", secrets=["NPM_TOKEN", "OTHER"])
    step = pipeline.Step("build", "npm test")
    argv, name = runs.command(p, step, Path("/work"), "20260101-000000-0000", 3)
    assert name == "agentos-ci-20260101-000000-0000-3"
    assert argv == ["docker", "run", "--rm", "--name", name, "-v", "/work:/w", "-w", "/w",
                     "-e", "CI", "-e", "AGENTOS_CI_RUN", "-e", "NPM_TOKEN", "-e", "OTHER",
                     "node:24", "bash", "-eo", "pipefail", "-c", "npm test"]
    argv2, name2 = runs.command(pipeline.Pipeline("ci.yml", []), step, Path("/work"), "x", 0)
    assert name2 is None and argv2 == ["bash", "-eo", "pipefail", "-c", "npm test"]
