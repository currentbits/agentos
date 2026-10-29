"""Push remotes: bare repos in ~/git/<name>.git whose post-receive hook starts a run per pushed branch."""
import json
import re
import shutil
import socket
import subprocess
from pathlib import Path

from .runs import CIError, git, home

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
HOOK = Path(__file__).resolve().parent.parent / "post-receive"


def git_root() -> Path:
    return home() / "git"


def box_host() -> str:
    """The tailnet DNS name when Tailscale is up, else the hostname."""
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5).stdout
        name = (json.loads(out).get("Self") or {}).get("DNSName") or ""
    except (OSError, ValueError, subprocess.TimeoutExpired):
        name = ""
    return name.rstrip(".") or socket.gethostname()


def remote_add(name, host) -> str:
    return f"git remote add agentos agent@{host}:git/{name}.git"


def create(name) -> dict:
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise CIError("name must match [a-z0-9][a-z0-9-]{0,62}")
    path = git_root() / f"{name}.git"
    if path.exists():
        raise CIError(f"{path} already exists")
    git_root().mkdir(parents=True, exist_ok=True)
    git("init", "--quiet", "--bare", str(path))
    try:
        hook = path / "hooks" / "post-receive"
        hook.unlink(missing_ok=True)
        hook.symlink_to(HOOK)               # shared hook: image updates reach every remote
    except OSError:
        shutil.rmtree(path, ignore_errors=True)   # don't leave a half-made repo behind
        raise
    return {"name": name, "path": str(path), "remote_add": remote_add(name, box_host())}


def list_remotes() -> list:
    if not git_root().is_dir():
        return []
    host = box_host()
    return [{"name": p.name[:-4], "path": str(p), "remote_add": remote_add(p.name[:-4], host)}
            for p in sorted(git_root().glob("*.git")) if p.is_dir() and NAME_RE.fullmatch(p.name[:-4])]
