"""agentos-ci runs: ids, run.json state, queue slots, the worker, cancel, logs and retention.

A run lives in ~/.local/share/agentos-ci/runs/<id>/ (run.json, pid, pgid, <step>.log). `start` spawns
a detached worker (its own session) that waits for a slot, checks the commit out into
~/.cache/agentos-ci/work/<id>, runs the steps and removes the checkout.
"""
import collections
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import pipeline

FINAL = ("passed", "failed", "cancelled", "error")
ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{4}$")
REF_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./@^~{}-]{0,254}$")   # never starts with "-"
KEEP = 200
KILL_GRACE = 10
BASE_PATH = "/usr/local/bin:/usr/bin:/bin"
MAIN = str(Path(__file__).resolve().parent.parent / "main.py")


class CIError(Exception):
    pass


def home() -> Path:
    return Path(os.environ.get("HOME") or "/home/agent").resolve()


def state_dir() -> Path:
    return home() / ".local/share/agentos-ci"


def runs_dir() -> Path:
    return state_dir() / "runs"


def work_root() -> Path:
    return home() / ".cache/agentos-ci/work"


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def max_parallel() -> int:
    v = os.environ.get("AGENTOS_CI_MAX_PARALLEL")
    if v is None:
        try:
            m = re.search(r"^MAX_PARALLEL=(\d+)$", Path("/etc/agentos/ci.conf").read_text(), re.M)
            v = m[1] if m else None
        except OSError:
            v = None
    try:
        n = int(v)
    except (TypeError, ValueError):
        return 2
    return n if 1 <= n <= 16 else 2


def kill_grace() -> int:
    """Seconds between TERM and KILL for a step's process group. AGENTOS_CI_KILL_GRACE overrides
    it for tests only (start() forwards it to the worker the same way as AGENTOS_CI_MAX_PARALLEL)."""
    try:
        return int(os.environ["AGENTOS_CI_KILL_GRACE"])
    except (KeyError, ValueError):
        return KILL_GRACE


def git(*args, cwd=None, check=True) -> str:
    # GIT_DIR and friends (set when a hook calls us) must not redirect these commands.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    r = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode:
        raise CIError(f"git {args[0]} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def inside_home(path) -> Path:
    try:
        real = Path(path).expanduser().resolve(strict=True)
    except (OSError, RuntimeError):
        raise CIError(f"no such directory: {path}")
    h = home()
    if real != h and h not in real.parents:
        raise CIError(f"path must be inside {h}")
    if not real.is_dir():
        raise CIError(f"not a directory: {path}")
    return real


def repo_root(path) -> Path:
    """The repository a path belongs to: the bare repo itself, or the work tree's top level."""
    p = inside_home(path)
    bare = git("rev-parse", "--is-bare-repository", cwd=p, check=False)
    if bare not in ("true", "false"):
        raise CIError(f"not a git repository: {p}")
    return p if bare == "true" else inside_home(git("rev-parse", "--show-toplevel", cwd=p))


def resolve(path, ref) -> tuple:
    if not isinstance(ref, str) or not REF_RE.fullmatch(ref):
        raise CIError(f"invalid ref: {ref!r}")
    repo = repo_root(path)
    commit = git("rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}", cwd=repo, check=False)
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
        raise CIError(f"unknown ref {ref!r} in {repo}")
    return repo, commit


def new_id() -> str:
    """YYYYMMDD-HHMMSS-<4 hex>, strictly increasing: the hex counts runs started within one second."""
    state_dir().mkdir(parents=True, exist_ok=True)
    with open(state_dir() / "last-id", "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        last = f.read().strip()
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        n = int(last[16:], 16) + 1 if last[:15] >= stamp and ID_RE.fullmatch(last) else 0
        if last[:15] > stamp:            # clock went back: keep counting on the last stamp
            stamp = last[:15]
        if n > 0xFFFF:
            raise CIError("too many runs started this second")
        run_id = f"{stamp}-{n:04x}"
        f.seek(0)
        f.truncate()
        f.write(run_id)
    return run_id


def run_dir(run_id) -> Path:
    if not isinstance(run_id, str) or not ID_RE.fullmatch(run_id):
        raise CIError(f"invalid run id: {run_id!r}")
    d = runs_dir() / run_id
    if not (d / "run.json").is_file():
        raise CIError(f"no run {run_id}")
    return d


def load(run_id) -> dict:
    return json.loads((run_dir(run_id) / "run.json").read_text())


def save(run: dict) -> None:
    d = runs_dir() / run["id"]
    tmp = d / f"run.json.{os.getpid()}.tmp"
    tmp.write_text(json.dumps(run, indent=2) + "\n")
    os.replace(tmp, d / "run.json")


def read_int(path: Path):
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def alive(pid) -> bool:
    """True while pid runs. A zombie (exited, not yet reaped by its parent) counts as gone."""
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True                        # no /proc (macOS): kill(0) is all we have


def refresh(run: dict) -> dict:
    """A queued or running run whose worker is gone ended badly: record that."""
    if run["status"] not in FINAL:
        pid = read_int(runs_dir() / run["id"] / "pid")
        if pid is not None and not alive(pid):
            run = load(run["id"])          # the worker may have finished between the two reads
            if run["status"] not in FINAL:
                run.update(status="error", error="the run's worker exited unexpectedly", finished=now())
                save(run)
    return run


def start(path, ref="HEAD", source="cli") -> str:
    if source not in ("cli", "push", "web", "mcp"):
        raise CIError(f"invalid source {source!r}")
    repo, commit = resolve(path, ref)
    run_id = new_id()
    d = runs_dir() / run_id
    d.mkdir(parents=True)
    save({"id": run_id, "repo": str(repo), "ref": ref, "commit": commit, "source": source, "status": "queued",
          "created": now(), "started": None, "finished": None, "pipeline": None, "image": None,
          "secrets": [], "missing_secrets": [], "steps": [], "error": None})
    # Double fork through `_spawn`, so the worker is nobody's child here: no zombie in a long-lived
    # caller (the MCP server, the web UI), and the worker outlives the push, the CLI and the session.
    env = {"HOME": str(home()), "PATH": BASE_PATH, "LANG": "C.UTF-8"}
    for k in ("AGENTOS_CI_MAX_PARALLEL", "AGENTOS_CI_KILL_GRACE"):
        if k in os.environ:
            env[k] = os.environ[k]
    try:
        subprocess.run([sys.executable, MAIN, "_spawn", run_id], env=env, cwd=str(home()),
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    except subprocess.CalledProcessError as e:
        raise CIError(f"failed to spawn worker for run {run_id}: {e}")
    prune()
    return run_id


def spawn(run_id) -> None:
    d = run_dir(run_id)
    with open(d / "worker.log", "ab") as log:
        # SIG_IGN (unlike a handler) survives exec: closes the window between this fork and
        # worker() installing its real handler, where a bare SIGTERM would otherwise kill the
        # new process by default before it ever runs any of our code.
        p = subprocess.Popen([sys.executable, MAIN, "_worker", run_id], start_new_session=True,
                             preexec_fn=lambda: signal.signal(signal.SIGTERM, signal.SIG_IGN),
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    (d / "pid").write_text(f"{p.pid}\n")


def prune(keep=KEEP) -> None:
    if not runs_dir().is_dir():
        return
    ids = sorted((p.name for p in runs_dir().iterdir() if ID_RE.fullmatch(p.name)), reverse=True)
    for rid in ids[keep:]:
        try:
            status = refresh(load(rid))["status"]
        except (CIError, OSError, ValueError, KeyError):
            status = "error"
        if status in FINAL:
            shutil.rmtree(runs_dir() / rid, ignore_errors=True)


def acquire_slot(stop):
    slots = state_dir() / "slots"
    slots.mkdir(parents=True, exist_ok=True)
    # ponytail: no strict FIFO; queued runs race for a free slot every 0.5 s.
    while not stop["why"]:
        for i in range(max_parallel()):
            f = open(slots / f"{i}.lock", "w")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return f                   # held until the worker exits
            except BlockingIOError:
                f.close()
        time.sleep(0.5)
    return None


def read_secrets(names) -> dict:
    """Values of the listed names only, parsed like /usr/local/lib/agentos/load-secrets.sh."""
    try:
        text = (home() / ".config/agentos/secrets.env").read_text()
    except OSError:
        return {}
    out = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep and k in names:
            out[k] = v
    return out


def step_env(run_id, names) -> dict:
    h = str(home())
    env = {"PATH": f"{h}/.local/bin:{h}/.cargo/bin:{h}/.bun/bin:{BASE_PATH}", "HOME": h, "LANG": "C.UTF-8",
           "CI": "true", "AGENTOS_CI_RUN": run_id}
    env.update(read_secrets(set(names)))
    return env


def command(p, step, work, run_id, n) -> tuple:
    if not p.image:
        return ["bash", "-eo", "pipefail", "-c", step.run], None
    name = f"agentos-ci-{run_id}-{n}"
    argv = ["docker", "run", "--rm", "--name", name, "-v", f"{work}:/w", "-w", "/w",
            "-e", "CI", "-e", "AGENTOS_CI_RUN"]
    for s in p.secrets:
        argv += ["-e", s]                  # value from the environment: never on a command line
    return argv + [p.image, "bash", "-eo", "pipefail", "-c", step.run], name


def killpg(pgid, sig) -> None:
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def run_step(argv, env, cwd, logf, deadline, stop, pgid_file) -> tuple:
    """Run one step in its own process group. Returns (exit code, None | "cancelled" | "timeout")."""
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT,
                         start_new_session=True)
    pgid_file.write_text(f"{p.pid}\n")
    reason, termed_at = None, None
    while True:
        try:
            code = p.wait(timeout=0.2)
            break
        except subprocess.TimeoutExpired:
            pass
        t = time.monotonic()
        if reason is None and (stop["why"] or t > deadline):
            reason = stop["why"] or "timeout"
            killpg(p.pid, signal.SIGTERM)
            termed_at = t
        elif termed_at is not None and t - termed_at > kill_grace():
            killpg(p.pid, signal.SIGKILL)
            termed_at = float("inf")
    killpg(p.pid, signal.SIGKILL)          # whatever the step left behind in its group
    pgid_file.unlink(missing_ok=True)
    return code, reason


def checkout(repo, commit, work) -> None:
    shutil.rmtree(work, ignore_errors=True)
    work.parent.mkdir(parents=True, exist_ok=True)
    # --shared works for bare repos and work trees alike, and never touches the source repo.
    git("clone", "--quiet", "--shared", "--no-checkout", "--", repo, str(work))
    git("checkout", "--quiet", "--detach", commit, cwd=work)


def finish(run, status) -> None:
    run.update(status=status, finished=now())
    save(run)


def worker(run_id) -> None:
    run = load(run_id)
    d = run_dir(run_id)
    stop = {"why": None}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(why="cancelled"))
    slot = acquire_slot(stop)
    if slot is None:
        return finish(run, "cancelled")
    run.update(status="running", started=now())
    save(run)
    work = work_root() / run_id
    image = None
    try:
        checkout(run["repo"], run["commit"], work)
        try:
            p = pipeline.select(work)
        except pipeline.ConfigError as e:
            run["error"] = str(e)
            return finish(run, "error")
        image = p.image
        found = read_secrets(set(p.secrets))
        run.update(pipeline=p.kind, image=p.image, secrets=p.secrets,
                   missing_secrets=[s for s in p.secrets if s not in found],
                   steps=[{"name": s.name, "status": "pending", "exit_code": None, "started": None, "finished": None}
                          for s in p.steps])
        save(run)
        env = step_env(run_id, p.secrets)
        deadline = time.monotonic() + p.timeout_s
        status = "passed"
        for n, (step, st) in enumerate(zip(p.steps, run["steps"])):
            if stop["why"] and status == "passed":
                status = "cancelled"
            if status != "passed":
                st["status"] = "skipped"
                continue
            st.update(status="running", started=now())
            save(run)
            argv, container = command(p, step, work, run_id, n)
            with open(d / f"{step.name}.log", "ab") as logf:
                code, reason = run_step(argv, env, work, logf, deadline, stop, d / "pgid")
                if reason == "timeout":
                    logf.write(f"\n[agentos-ci: run timed out after {p.timeout_s}s]\n".encode())
            if container and reason:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            st.update(exit_code=code, finished=now(),
                      status="passed" if code == 0 and not reason else "cancelled" if reason == "cancelled" else "failed")
            if st["status"] != "passed":
                status = "cancelled" if reason == "cancelled" else "failed"
            save(run)
        finish(run, status)
    except Exception as e:
        # Anything unexpected (docker missing for an image: step, a bug) ends the run as "error"
        # instead of leaving it stuck "running" with a dead worker.
        run["error"] = str(e)
        finish(run, "error")
    finally:
        if image and work.exists():
            # Container steps ran as root: their files in the checkout are root-owned. ponytail: clean
            # up with the run's own image instead of a --user mapping that breaks images expecting root.
            # --entrypoint overrides the image's own ENTRYPOINT, so "find ..." runs instead of it.
            subprocess.run(["docker", "run", "--rm", "--entrypoint", "find", "-v", f"{work}:/w", image,
                           "/w", "-mindepth", "1", "-delete"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


def status(run_id) -> dict:
    return refresh(load(run_id))


def list_runs(repo=None, limit=20) -> list:
    want = str(repo_root(repo)) if repo else None
    if not runs_dir().is_dir():
        return []
    out = []
    for rid in sorted((p.name for p in runs_dir().iterdir() if ID_RE.fullmatch(p.name)), reverse=True):
        try:
            run = refresh(load(rid))
        except (CIError, OSError, ValueError):
            continue
        if want is None or run["repo"] == want:
            out.append(run)
            if len(out) >= limit:
                break
    return out


def cancel(run_id) -> dict:
    run = load(run_id)
    if run["status"] in FINAL:
        return run
    d = run_dir(run_id)
    deadline = time.monotonic() + kill_grace() + 5
    while time.monotonic() < deadline:
        pid = read_int(d / "pid")
        if alive(pid):
            # Resent every poll: while queued, the worker ignores SIGTERM until it installs its
            # own handler (see spawn()), so a single early TERM can be dropped, not just delayed.
            os.kill(pid, signal.SIGTERM)   # the worker TERMs its step's group, KILLs it 10 s later
        run = refresh(load(run_id))        # a dead worker is detected immediately, not after the full wait
        if run["status"] in FINAL:
            return run
        time.sleep(0.2)
    # The worker is stuck or gone: kill what is left and record the cancel here.
    for f in ("pgid", "pid"):
        g = read_int(d / f)
        if g:
            killpg(g, signal.SIGKILL)
    run = load(run_id)
    if run["status"] not in FINAL:
        run["error"] = "the worker did not stop; killed"
        finish(run, "cancelled")
    return run


def default_step(run) -> str | None:
    steps = run["steps"]
    for st in steps:
        if st["status"] in ("failed", "cancelled"):
            return st["name"]
    started = [st["name"] for st in steps if st["status"] != "pending" and st["status"] != "skipped"]
    return started[-1] if started else None


def log_path(run, step) -> Path:
    names = [st["name"] for st in run["steps"]]
    if step not in names:
        raise CIError(f"run {run['id']} has no step {step!r}" + (f"; steps: {', '.join(names)}" if names else ""))
    return runs_dir() / run["id"] / f"{step}.log"


def tail(path: Path, n: int) -> str:
    try:
        with open(path, errors="replace") as f:
            return "".join(collections.deque(f, maxlen=max(0, n)))
    except FileNotFoundError:
        return ""


def logs(run_id, step=None, n=200) -> dict:
    run = status(run_id)
    step = step or default_step(run)
    if step is None:
        return {"step": None, "text": run["error"] or ""}
    return {"step": step, "text": tail(log_path(run, step), n)}


def follow(run_id, step, out) -> None:
    """Write the step's log to out as it grows; return once the run is final and the log drained."""
    run = status(run_id)
    step = step or default_step(run)
    while step is None and run["status"] not in FINAL:
        time.sleep(0.5)
        run = status(run_id)
        step = default_step(run)
    if step is None:
        out.write(run["error"] or "")
        out.flush()
        return
    path = log_path(run, step)
    pos = 0
    while True:
        final = status(run_id)["status"] in FINAL
        try:
            with open(path, "rb") as f:
                f.seek(pos)
                chunk = f.read()
        except FileNotFoundError:
            chunk = b""
        if chunk:
            pos += len(chunk)
            out.write(chunk.decode("utf-8", "replace"))
            out.flush()
        elif final:
            return
        else:
            time.sleep(0.3)


def wait(run_id, timeout_s=1800) -> dict:
    deadline = time.monotonic() + max(0, timeout_s)
    run = status(run_id)
    while run["status"] not in FINAL and time.monotonic() < deadline:
        time.sleep(1)
        run = status(run_id)
    return summary(run)


def summary(run) -> dict:
    failed = next((st["name"] for st in run["steps"] if st["status"] in ("failed", "cancelled")), None)
    text = tail(log_path(run, failed), 200) if failed else (run["error"] or "") if run["status"] == "error" else ""
    return {"run_id": run["id"], "status": run["status"], "failed_step": failed, "log_tail": text}
