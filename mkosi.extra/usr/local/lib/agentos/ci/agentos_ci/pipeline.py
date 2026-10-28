"""Pick a repo's pipeline, first match wins: .agentos/ci.yml, .github/workflows via act, auto-detect."""
import json
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path

import yaml

STEP_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")    # also the log file name: no "/"
SECRET_RE = re.compile(r"^[A-Z_][A-Z0-9_]{0,63}$")
IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9._/:@-]{0,254}$")       # never starts with "-": not a docker flag
DEFAULT_TIMEOUT = 30 * 60
MAX_TIMEOUT = 24 * 3600
# act's runner images (catthehacker "medium", ~570 MB compressed). Docker pulls them on first use
# (--pull=false only skips re-pulling); they are never baked into the AgentOS image.
ACT_PLATFORMS = (
    "ubuntu-latest=catthehacker/ubuntu:act-24.04",
    "ubuntu-24.04=catthehacker/ubuntu:act-24.04",
    "ubuntu-22.04=catthehacker/ubuntu:act-22.04",
)


class ConfigError(Exception):
    pass


@dataclass
class Step:
    name: str
    run: str          # a bash script: bash -eo pipefail -c <run>


@dataclass
class Pipeline:
    kind: str         # "ci.yml" | "act" | "auto"
    steps: list
    image: str | None = None
    timeout_s: int = DEFAULT_TIMEOUT
    secrets: list = field(default_factory=list)


def parse_timeout(value) -> int:
    m = re.fullmatch(r"(\d{1,6})([smh]?)", str(value).strip())
    if not m:
        raise ConfigError(f"timeout must look like 90s, 30m or 2h, not {value!r}")
    seconds = int(m[1]) * {"": 1, "s": 1, "m": 60, "h": 3600}[m[2]]
    if not 1 <= seconds <= MAX_TIMEOUT:
        raise ConfigError("timeout must be between 1s and 24h")
    return seconds


def parse_ci_yml(text: str) -> Pipeline:
    try:
        d = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise ConfigError(f".agentos/ci.yml is not valid YAML: {e}")
    if not isinstance(d, dict):
        raise ConfigError(".agentos/ci.yml must be a mapping with a steps: list")
    unknown = sorted(str(k) for k in set(d) - {"image", "timeout", "secrets", "steps"})
    if unknown:
        raise ConfigError(f".agentos/ci.yml: unknown keys: {', '.join(unknown)}")
    image = d.get("image")
    if image is not None and not (isinstance(image, str) and IMAGE_RE.match(image)):
        raise ConfigError(f"image: not a Docker image reference: {image!r}")
    secrets = d.get("secrets") or []
    if not isinstance(secrets, list) or not all(isinstance(s, str) and SECRET_RE.match(s) for s in secrets):
        raise ConfigError("secrets: must be a list of names such as NPM_TOKEN")
    raw = d.get("steps")
    if not isinstance(raw, list) or not raw:
        raise ConfigError("steps: must be a non-empty list")
    steps, seen = [], set()
    for i, s in enumerate(raw, 1):
        if not isinstance(s, dict) or set(s) - {"name", "run"} or not isinstance(s.get("run"), str) or not s["run"].strip():
            raise ConfigError(f"step {i}: needs run: (a string) and optionally name:")
        name = s.get("name", f"step-{i}")
        if not isinstance(name, str) or not STEP_RE.match(name) or name in seen:
            raise ConfigError(f"step {i}: name must match [A-Za-z0-9][A-Za-z0-9_.-]{{0,63}} and be unique")
        seen.add(name)
        steps.append(Step(name, s["run"]))
    return Pipeline("ci.yml", steps, image, parse_timeout(d.get("timeout", "30m")), sorted(set(secrets)))


def workflow_events(text: str) -> set:
    try:
        d = yaml.safe_load(text)
    except yaml.YAMLError:
        return set()
    if not isinstance(d, dict):
        return set()
    on = d.get("on", d.get(True))     # YAML 1.1 reads a bare `on:` key as the boolean True
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return {str(e) for e in on}
    return set()


def act_steps(work: Path) -> list:
    wf = work / ".github" / "workflows"
    files = sorted(p for p in wf.iterdir() if p.suffix in (".yml", ".yaml") and p.is_file()) if wf.is_dir() else []
    platforms = " ".join(f"-P {p}" for p in ACT_PLATFORMS)
    steps = []
    for f in files:
        events = workflow_events(f.read_text(errors="replace"))
        event = "push" if "push" in events else "workflow_dispatch" if "workflow_dispatch" in events else None
        if event:
            name = "act-" + re.sub(r"[^A-Za-z0-9_.-]", "-", f.name)[:60]
            rel = shlex.quote(str(f.relative_to(work)))
            steps.append(Step(name, f"act {event} -W {rel} {platforms} --pull=false --rm"))
    return steps


def auto_steps(work: Path) -> list:
    pj = work / "package.json"
    if pj.is_file():
        try:
            scripts = json.loads(pj.read_text()).get("scripts") or {}
        except (ValueError, AttributeError):
            scripts = {}
        if isinstance(scripts, dict) and "test" in scripts:
            return [Step("npm-test", "npm ci && npm test")]
    if any((work / f).exists() for f in ("pyproject.toml", "pytest.ini", "tests")):
        return [Step("pytest", "pytest")]
    if (work / "Cargo.toml").is_file():
        return [Step("cargo-test", "cargo test")]
    if (work / "go.mod").is_file():
        return [Step("go-test", "go test ./...")]
    mk = work / "Makefile"
    if mk.is_file() and re.search(r"^test\s*:", mk.read_text(errors="replace"), re.M):
        return [Step("make-test", "make test")]
    return []


NO_CONFIG = ("no CI configuration found. Add .agentos/ci.yml (steps: [{name: test, run: npm test}]), "
             "a .github/workflows/*.yml with an on: push trigger, or a test entry point agentos-ci detects: "
             "package.json test script, pyproject.toml/pytest.ini/tests/, Cargo.toml, go.mod, Makefile test target.")


def select(work: Path) -> Pipeline:
    ci = work / ".agentos" / "ci.yml"
    if ci.is_file():
        return parse_ci_yml(ci.read_text(errors="replace"))
    steps = act_steps(work)
    if steps:
        return Pipeline("act", steps)
    steps = auto_steps(work)
    if steps:
        return Pipeline("auto", steps)
    raise ConfigError(NO_CONFIG)
