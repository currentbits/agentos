import pytest
from conftest import ci_yml
from agentos_ci.pipeline import ConfigError, parse_ci_yml, parse_timeout, select, workflow_events


def tree(tmp_path, files):
    for name, text in files.items():
        f = tmp_path / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    return tmp_path


WF = "on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"


def test_selection_order_ci_yml_then_workflows_then_auto(tmp_path):
    t = tree(tmp_path, {".agentos/ci.yml": ci_yml(("t", "true")), ".github/workflows/ci.yml": WF,
                        "package.json": '{"scripts":{"test":"x"}}'})
    assert select(t).kind == "ci.yml"
    (t / ".agentos/ci.yml").unlink()
    p = select(t)
    assert p.kind == "act" and p.steps[0].name == "act-ci.yml"
    assert p.steps[0].run.startswith("act push -W .github/workflows/ci.yml -P ubuntu-latest=catthehacker/ubuntu:act-24.04")
    assert "--pull=false" in p.steps[0].run
    (t / ".github/workflows/ci.yml").unlink()
    assert select(t).kind == "auto"


def test_workflow_events_and_dispatch_only(tmp_path):
    assert workflow_events("on: [push, pull_request]") == {"push", "pull_request"}
    assert workflow_events("on:\n  workflow_dispatch:\n  schedule: []\n") == {"workflow_dispatch", "schedule"}
    assert workflow_events("'on': push") == {"push"}
    assert workflow_events(": not yaml [") == set()
    t = tree(tmp_path, {".github/workflows/d.yaml": "on: workflow_dispatch\njobs: {}\n",
                        ".github/workflows/pr.yml": "on: pull_request\njobs: {}\n", "go.mod": "module x\n"})
    p = select(t)
    assert [s.name for s in p.steps] == ["act-d.yaml"] and p.steps[0].run.startswith("act workflow_dispatch ")
    (t / ".github/workflows/d.yaml").unlink()
    assert select(t).kind == "auto"     # no push/dispatch workflow: fall through


@pytest.mark.parametrize("files,cmd", [
    ({"package.json": '{"scripts":{"test":"node t.js"}}'}, "npm ci && npm test"),
    ({"pyproject.toml": ""}, "pytest"),
    ({"pytest.ini": ""}, "pytest"),
    ({"tests/test_x.py": ""}, "pytest"),
    ({"Cargo.toml": ""}, "cargo test"),
    ({"go.mod": "module x\n"}, "go test ./..."),
    ({"Makefile": "build:\n\ttrue\ntest: build\n\ttrue\n"}, "make test"),
    ({"package.json": '{"scripts":{"build":"x"}}', "go.mod": ""}, "go test ./..."),   # no test script: next rule
])
def test_auto_detect(tmp_path, files, cmd):
    assert [s.run for s in select(tree(tmp_path, files)).steps] == [cmd]


@pytest.mark.parametrize("files", [{}, {"Makefile": "build:\n\ttrue\n"}, {"package.json": "[1]"}])
def test_nothing_found(tmp_path, files):
    with pytest.raises(ConfigError, match="no CI configuration found"):
        select(tree(tmp_path, files))


def test_ci_yml_full():
    p = parse_ci_yml("image: node:24\ntimeout: 5m\nsecrets: [NPM_TOKEN, NPM_TOKEN]\n" + ci_yml(("install", "npm ci"), ("test", "npm test")))
    assert (p.kind, p.image, p.timeout_s, p.secrets) == ("ci.yml", "node:24", 300, ["NPM_TOKEN"])
    assert [(s.name, s.run) for s in p.steps] == [("install", "npm ci"), ("test", "npm test")]
    assert parse_ci_yml("steps:\n  - run: make\n").steps[0].name == "step-1"
    assert parse_ci_yml("steps:\n  - run: make\n").timeout_s == 1800


@pytest.mark.parametrize("text,why", [
    ("steps: [", "not valid YAML"),
    ("- a\n", "mapping"),
    ("stages: []\nsteps:\n  - run: x\n", "unknown keys: stages"),
    ("steps: []\n", "non-empty"),
    ("steps:\n  - name: a\n", "needs run"),
    ("steps:\n  - run: x\n    env: {}\n", "needs run"),
    ("steps:\n  - {name: a, run: x}\n  - {name: a, run: y}\n", "unique"),
    ("steps:\n  - {name: ../etc, run: x}\n", "name must match"),
    ("steps:\n  - {name: -rf, run: x}\n", "name must match"),
    ("image: --privileged\nsteps:\n  - run: x\n", "image"),
    ("image: Node\nsteps:\n  - run: x\n", "image"),
    ("secrets: [lower]\nsteps:\n  - run: x\n", "secrets"),
    ("secrets: NPM_TOKEN\nsteps:\n  - run: x\n", "secrets"),
    ("timeout: forever\nsteps:\n  - run: x\n", "timeout"),
    ("timeout: 25h\nsteps:\n  - run: x\n", "between"),
])
def test_ci_yml_rejects(text, why):
    with pytest.raises(ConfigError, match=why):
        parse_ci_yml(text)


def test_timeout_units():
    assert [parse_timeout(v) for v in ("90", "90s", "30m", "2h")] == [90, 90, 1800, 7200]
