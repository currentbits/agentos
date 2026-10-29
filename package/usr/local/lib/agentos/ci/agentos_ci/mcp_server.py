"""agentos-ci MCP server (stdio): lets agents start CI, wait for it and read failures."""
import asyncio

from mcp.server.fastmcp import FastMCP

from . import runs

mcp = FastMCP("agentos-ci", log_level="WARNING")


@mcp.tool()
def ci_run(path: str, ref: str = "HEAD") -> dict:
    """Start a CI run of the committed tree at `ref` in the git repository at `path` (inside
    /home/agent). Returns {run_id}. Commit first: uncommitted edits are not part of the run."""
    return {"run_id": runs.start(path, ref, source="mcp")}


@mcp.tool()
async def ci_wait(run_id: str, timeout_s: int = 1800) -> dict:
    """Wait until the run finishes (or timeout_s passes). Returns {run_id, status, failed_step,
    log_tail}: log_tail is the last 200 lines of the failing step. Still queued or running when it
    returns: call ci_wait again."""
    deadline = asyncio.get_running_loop().time() + max(0, timeout_s)
    run = runs.status(run_id)
    while run["status"] not in runs.FINAL and asyncio.get_running_loop().time() < deadline:
        await asyncio.sleep(1)
        run = runs.status(run_id)
    return runs.summary(run)


@mcp.tool()
def ci_status(run_id: str) -> dict:
    """The run's state: status, repo, ref, commit, pipeline, and per-step status and exit codes."""
    return runs.status(run_id)


@mcp.tool()
def ci_logs(run_id: str, step: str | None = None, tail: int = 200) -> dict:
    """The last `tail` lines of a step's log (default: the failing step, else the latest one)."""
    return runs.logs(run_id, step, min(max(int(tail), 1), 5000))


@mcp.tool()
def ci_list(path: str | None = None, limit: int = 20) -> list[dict]:
    """Recent runs, newest first; only the repository at `path` when given."""
    return runs.list_runs(path, min(max(int(limit), 1), 200))


@mcp.tool()
def ci_cancel(run_id: str) -> dict:
    """Cancel a queued or running run (SIGTERM to its step, SIGKILL after 10 s)."""
    return runs.cancel(run_id)


def main() -> None:
    mcp.run()
