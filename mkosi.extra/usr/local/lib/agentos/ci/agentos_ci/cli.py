"""agentos-ci command line. Every command takes --json; errors exit 2 with the reason on stderr."""
import argparse
import json
import sys

from . import pipeline, remotes, runs


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    p = argparse.ArgumentParser(prog="agentos-ci", description="Built-in CI for AgentOS.")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", parents=[common], help="start a run")
    r.add_argument("path", nargs="?", default=".")
    r.add_argument("--ref", default="HEAD")
    r.add_argument("--wait", action="store_true", help="wait; exit 0 only if the run passed")
    r.add_argument("--source", default="cli", choices=["cli", "push", "web", "mcp"], help=argparse.SUPPRESS)
    s = sub.add_parser("status", parents=[common], help="show a run")
    s.add_argument("id")
    lg = sub.add_parser("logs", parents=[common], help="print a step's log")
    lg.add_argument("id")
    lg.add_argument("--step")
    lg.add_argument("--tail", type=int, default=200)
    lg.add_argument("--follow", action="store_true")
    ls = sub.add_parser("list", parents=[common], help="list runs, newest first")
    ls.add_argument("--repo")
    ls.add_argument("--limit", type=int, default=20)
    c = sub.add_parser("cancel", parents=[common], help="cancel a run")
    c.add_argument("id")
    rm = sub.add_parser("remote", help="push remotes in ~/git")
    rsub = rm.add_subparsers(dest="rcmd", required=True)
    rc = rsub.add_parser("create", parents=[common])
    rc.add_argument("name")
    rsub.add_parser("list", parents=[common])
    for hidden in ("_spawn", "_worker"):
        sub.add_parser(hidden).add_argument("id")
    return p


def out(args, data, text) -> None:
    print(json.dumps(data, indent=2) if args.json else text)


def fmt_run(run) -> str:
    lines = [f"{run['id']}  {run['status']}  {run['repo']}  {run['ref']}  {run['commit'][:12]}"]
    lines += [f"  {st['status']:<9} {st['name']}" + (f" (exit {st['exit_code']})" if st["exit_code"] not in (None, 0) else "")
              for st in run["steps"]]
    if run.get("error"):
        lines.append(f"  error: {run['error']}")
    return "\n".join(lines)


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.cmd == "run":
            run_id = runs.start(args.path, args.ref, args.source)
            if not args.wait:
                out(args, {"run_id": run_id}, run_id)
                return 0
            s = runs.wait(run_id, 10 ** 9)
            out(args, s, f"{run_id} {s['status']}" + (f"\n--- {s['failed_step']} ---\n{s['log_tail']}" if s["log_tail"] else ""))
            return 0 if s["status"] == "passed" else 1
        if args.cmd == "status":
            run = runs.status(args.id)
            out(args, run, fmt_run(run))
        elif args.cmd == "logs":
            if args.follow:
                runs.follow(args.id, args.step, sys.stdout)
            else:
                lg = runs.logs(args.id, args.step, args.tail)
                if args.json:
                    out(args, lg, "")
                else:
                    sys.stdout.write(lg["text"])
        elif args.cmd == "list":
            rs = runs.list_runs(args.repo, max(1, min(args.limit, 1000)))
            out(args, rs, "\n".join(f"{r['id']}  {r['status']:<9}  {r['repo']}  {r['ref']}" for r in rs))
        elif args.cmd == "cancel":
            run = runs.cancel(args.id)
            out(args, run, f"{run['id']} {run['status']}")
        elif args.cmd == "remote" and args.rcmd == "create":
            r = remotes.create(args.name)
            out(args, r, f"created {r['path']}\nOn your machine: {r['remote_add']}")
        elif args.cmd == "remote":
            rs = remotes.list_remotes()
            out(args, rs, "\n".join(f"{r['name']}  {r['remote_add']}" for r in rs))
        elif args.cmd == "_spawn":
            runs.spawn(args.id)
        elif args.cmd == "_worker":
            runs.worker(args.id)
    except (runs.CIError, pipeline.ConfigError) as e:
        print(f"agentos-ci: {e}", file=sys.stderr)
        return 2
    return 0
