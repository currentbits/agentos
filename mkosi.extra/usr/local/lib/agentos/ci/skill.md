# AgentOS CI

This machine runs CI for any git repository under /home/agent. Use the `agentos-ci` MCP tools
(`ci_run`, `ci_wait`, `ci_logs`, `ci_status`, `ci_list`, `ci_cancel`), or the `agentos-ci` command.

Before you declare a task in a repository done, and the repository has CI (`.agentos/ci.yml`,
`.github/workflows/`, or a test entry point such as an npm `test` script, pytest, `cargo test`,
`go test` or a Makefile `test` target):

1. Commit your work. CI runs the committed tree, never uncommitted edits.
2. Call `ci_run(path=<repository>, ref="HEAD")`, then `ci_wait(run_id)`. If `ci_wait` comes back
   while the run is still `queued` or `running` (your client cut the call short), call it again.
3. On `failed`: read `log_tail`, or `ci_logs(run_id, step)` for more, fix the root cause, commit,
   and run CI again.
4. On `error`: the message says why (for example, no CI configuration found). Fix it, or tell the user.

Never weaken, skip or delete tests or CI configuration to get a pass.

Steps run with everything `agent` can do: they can read `~/.config/agentos/secrets.env` and
anything else in /home/agent, and use `sudo` and `docker` (root on this box). Only the step
environment is free of API keys unless a step lists one under `secrets:`. `image:` steps run
inside a container that sees only the checkout. Never run untrusted code through CI.

When you report back, give the run id and its result.
