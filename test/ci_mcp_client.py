#!/usr/bin/env python3
"""In-VM end-to-end test of the agentos-ci MCP server over stdio, as an agent CLI would use it.

  ci_mcp_client.py <passing-repo> <failing-repo>
Run with the AgentOS venv's python (it has the mcp package).
"""
import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

TOOLS = {"ci_run", "ci_wait", "ci_status", "ci_logs", "ci_list", "ci_cancel"}


def fail(msg):
    sys.exit(f"CI MCP FAIL: {msg}")


async def call(s, name, **args):
    r = await s.call_tool(name, args)
    if r.isError:
        fail(f"{name}({args}): {r.content}")
    return json.loads(r.content[0].text)


async def main(good, bad):
    async with stdio_client(StdioServerParameters(command="/usr/local/bin/agentos-ci-mcp")) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = {t.name for t in (await s.list_tools()).tools}
            if tools != TOOLS:
                fail(f"tools {sorted(tools)}")
            ok = await call(s, "ci_wait", run_id=(await call(s, "ci_run", path=good))["run_id"], timeout_s=300)
            if ok["status"] != "passed":
                fail(f"good repo: {ok}")
            res = await call(s, "ci_wait", run_id=(await call(s, "ci_run", path=bad))["run_id"], timeout_s=300)
            if res["status"] != "failed" or res["failed_step"] != "test" or "smoke-failure-marker" not in res["log_tail"]:
                fail(f"bad repo: {res}")
            if not (await s.call_tool("ci_run", {"path": "/etc"})).isError:
                fail("ci_run accepted a path outside /home/agent")
    print("CI MCP OK")


asyncio.run(main(sys.argv[1], sys.argv[2]))
