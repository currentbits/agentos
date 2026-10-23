#!/usr/bin/env python3
"""End-to-end test for agentos-computer, run inside an AgentOS VM with the agentos venv python.

  mcp_client.py stdio                  spawn /usr/local/bin/agentos-computer
  mcp_client.py http <url> <token>     connect to the Streamable HTTP endpoint
"""
import asyncio
import base64
import io
import json
import os
import subprocess
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.streamable_http import streamablehttp_client
from PIL import Image

EXPECTED_TOOLS = {"create_desktop", "list_desktops", "destroy_desktop", "screenshot", "click",
                  "double_click", "move", "drag", "type", "key", "scroll", "cursor_position"}


def fail(msg):
    sys.exit(f"MCP CLIENT FAIL: {msg}")


async def call(s, name, **args):
    r = await s.call_tool(name, args)
    if r.isError:
        fail(f"{name}({args}) returned error: {r.content}")
    return r


def data(r):
    # mcp 1.30: tools returning list[...] get their content split one-TextContent-per-item, so
    # content[0].text is only the first element; structuredContent carries the whole list, wrapped
    # as {"result": [...]} (dict-returning tools aren't wrapped, and have no structuredContent).
    sc = r.structuredContent
    if isinstance(sc, dict) and list(sc) == ["result"]:
        return sc["result"]
    return json.loads(r.content[0].text)


async def scenario(s):
    await s.initialize()
    tools = {t.name for t in (await s.list_tools()).tools}
    if tools != EXPECTED_TOOLS:
        fail(f"tool set mismatch: {sorted(tools ^ EXPECTED_TOOLS)}")

    d = data(await call(s, "create_desktop"))
    n = d["id"]
    if "token%3D" not in d["view_url"]:
        fail(f"bad view_url {d['view_url']}")

    # screenshot: PNG at 1366x768 that eventually shows more than one colour (XFCE drew something)
    for _ in range(30):
        r = await call(s, "screenshot", desktop=n)
        img = r.content[0]
        if img.type != "image" or img.mimeType != "image/png":
            fail(f"screenshot content is {img.type} {getattr(img, 'mimeType', '')}")
        im = Image.open(io.BytesIO(base64.b64decode(img.data)))
        if im.size != (1366, 768):
            fail(f"screenshot size {im.size}")
        if len(im.convert("RGB").getcolors(maxcolors=4) or [None] * 5) > 1:
            break
        await asyncio.sleep(1)
    else:
        fail("screenshot stayed a single colour for 30 s")

    # move in scaled space -> real pointer at the 1920x1080 position, and back
    await call(s, "move", desktop=n, x=683, y=384)
    pos = data(await call(s, "cursor_position", desktop=n))
    if abs(pos["x"] - 683) > 1 or abs(pos["y"] - 384) > 1:
        fail(f"cursor_position {pos}")
    real = subprocess.run(["xdotool", "getmouselocation", "--shell"], env={**os.environ, "DISPLAY": f":{n}"},
                          capture_output=True, text=True, check=True).stdout
    rx = int(real.split("X=")[1].split()[0]); ry = int(real.split("Y=")[1].split()[0])
    if abs(rx - 960) > 2 or abs(ry - 540) > 2:
        fail(f"real pointer at {rx},{ry}, expected ~960,540")

    # input tools run without error
    await call(s, "click", desktop=n, x=683, y=384, button="left")
    await call(s, "double_click", desktop=n, x=683, y=384)
    await call(s, "drag", desktop=n, x1=100, y1=100, x2=200, y2=200)
    await call(s, "scroll", desktop=n, x=683, y=384, direction="down", amount=2)
    await call(s, "key", desktop=n, combo="Escape")
    await call(s, "type", desktop=n, text="hello agentos")
    await call(s, "type", desktop=n, text="x" * 2600)  # long type: run()'s timeout scales with length

    # invalid input is a tool error, not a crash
    for name, args in [("key", {"desktop": n, "combo": "a;rm -rf /"}),
                       ("click", {"desktop": n, "x": 1, "y": 1, "button": "nope"}),
                       ("screenshot", {"desktop": 99}),
                       ("type", {"desktop": n, "text": "x" * 10001})]:
        r = await s.call_tool(name, args)
        if not r.isError:
            fail(f"{name}({args}) should have been rejected")

    # second desktop gets a different id; both listed; destroy both
    n2 = data(await call(s, "create_desktop"))["id"]
    ids = {d["id"] for d in data(await call(s, "list_desktops"))}
    if n2 == n or not {n, n2} <= ids:
        fail(f"ids {n}, {n2}, listed {ids}")
    for i in (n, n2):
        await call(s, "destroy_desktop", id=i)
    if data(await call(s, "list_desktops")):
        fail("desktops left after destroy")
    print("MCP CLIENT OK")


async def main():
    if sys.argv[1:2] == ["stdio"]:
        async with stdio_client(StdioServerParameters(command="/usr/local/bin/agentos-computer")) as (r, w):
            async with ClientSession(r, w) as s:
                await scenario(s)
    elif sys.argv[1:2] == ["http"] and len(sys.argv) == 4:
        headers = {"Authorization": f"Bearer {sys.argv[3]}"}
        async with streamablehttp_client(sys.argv[2], headers=headers) as (r, w, _):
            async with ClientSession(r, w) as s:
                await scenario(s)
    else:
        sys.exit(__doc__)


asyncio.run(main())
