"""agentos-computer: MCP server driving AgentOS virtual desktops.

stdio by default (spawned by agent CLIs inside the box); --http HOST:PORT for the tailnet service.
Screenshots are scaled to SCREENSHOT_WIDTH; every coordinate a tool takes or returns is in that space.
"""
import fcntl
import hmac
import io
import os
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402

from mcp.server.fastmcp import FastMCP, Image  # noqa: E402
from PIL import Image as PILImage  # noqa: E402

CONF = "/etc/agentos/desktop.conf"
TOKENS = "/run/agentos/vnc"
LOCK = "/tmp/agentos-desktop.lock"
LAST_DIR = "/run/agentos/desktops"

mcp = FastMCP("agentos-computer", host="0.0.0.0", log_level="WARNING", stateless_http=True)


def conf():
    try:
        text = open(CONF).read()
    except FileNotFoundError:
        text = ""
    c = core.parse_conf(text, {"MAX_DESKTOPS": "8", "SCREENSHOT_WIDTH": "1366"})

    # ponytail: a hand-edited desktop.conf shouldn't be able to cause a ZeroDivisionError or
    # nonsense scaling; clamp to sane ranges and fall back to the default, per field independently
    # (a bad width must not also discard a good MAX_DESKTOPS, and vice versa).
    def field(key, default, lo, hi):
        try:
            v = int(c[key])
        except ValueError:
            return default
        return v if lo <= v <= hi else default

    return field("MAX_DESKTOPS", 8, 1, 16), field("SCREENSHOT_WIDTH", 1366, 640, 1920)


def run(*args, display=None, timeout=30):
    env = dict(os.environ)
    if display is not None:
        env["DISPLAY"] = f":{display}"
    try:
        r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{args[0]} timed out")
    if r.returncode != 0:
        raise RuntimeError(f"{args[0]} failed: {r.stderr.strip() or r.returncode}")
    return r.stdout


def active():
    return core.active_desktops(run("systemctl", "list-units", "agentos-desktop@*", "--state=active",
                                    "--plain", "--no-legend"))


def touch_last(n):
    """Mark desktop n as just used, for the idle reaper (reap-desktops)."""
    path = f"{LAST_DIR}/{n}.last"
    open(path, "a").close()
    os.utime(path, None)


def need(desktop):
    if desktop not in active():
        raise ValueError(f"desktop {desktop} is not running; call create_desktop first")
    touch_last(desktop)


_host_cache = {"host": None, "ts": 0.0}


def host():
    """Tailnet DNS name when Tailscale is up, else the plain hostname. Cached 60 s (view URLs
    are built often; `tailscale status` is a subprocess call we don't need to repeat per-call)."""
    now = time.time()
    if now - _host_cache["ts"] > 60:
        try:
            h = core.tailnet_host(run("tailscale", "status", "--json"))
        except RuntimeError:
            h = None
        _host_cache["host"], _host_cache["ts"] = h or socket.gethostname(), now
    return _host_cache["host"]


def info(n):
    for _ in range(50):
        try:
            token = core.parse_token_file(open(f"{TOKENS}/{n}").read())
            return {"id": n, "view_url": core.view_url(host(), token)}
        except FileNotFoundError:
            time.sleep(0.1)
    raise RuntimeError(f"no viewer token for desktop {n}")


def pt(x, y):
    return [str(v) for v in core.to_screen(x, y, conf()[1])]


def _button(name):  # underscore: click() has a parameter called `button`
    if name not in core.BUTTONS:
        raise ValueError(f"button must be one of {sorted(core.BUTTONS)}")
    return core.BUTTONS[name]


@mcp.tool()
def create_desktop() -> dict:
    """Start a new 1920x1080 XFCE desktop. Returns its id and a live view URL for humans.
    Each agent should create its own desktop; desktops are not shared."""
    max_n, _ = conf()
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # ponytail: one host-wide lock; two agents can't grab the same N
        n = core.lowest_free(active(), max_n)
        if n is None:
            raise ValueError(f"all {max_n} desktops are in use; destroy one first")
        run("systemctl", "--no-ask-password", "start", f"agentos-desktop@{n}.service")
    for _ in range(150):
        try:
            run("xdotool", "getdisplaygeometry", display=n)
            break
        except RuntimeError:
            time.sleep(0.2)
    else:
        raise RuntimeError(f"desktop {n} did not come up")
    touch_last(n)
    return info(n)


@mcp.tool()
def list_desktops() -> list[dict]:
    """List running desktops with their live view URLs. For visibility only: each agent should
    create its own desktop via create_desktop, not attach to one already in use by another agent."""
    return [info(n) for n in active()]


@mcp.tool()
def destroy_desktop(id: int) -> str:
    """Stop a desktop and everything running on it."""
    need(id)
    run("systemctl", "--no-ask-password", "stop", f"agentos-desktop@{id}.service")
    return "ok"


@mcp.tool()
def screenshot(desktop: int) -> Image:
    """PNG of the desktop scaled to the screenshot width (default 1366x768). Use its pixel coordinates for all input tools."""
    need(desktop)
    _, w = conf()
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "s.png")
        run("scrot", "--overwrite", path, display=desktop)
        im = PILImage.open(path).convert("RGB").resize(core.scaled_size(w), PILImage.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return Image(data=buf.getvalue(), format="png")


@mcp.tool()
def click(desktop: int, x: int, y: int, button: str = "left") -> str:
    """Click at (x, y). button: left, middle or right."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x, y), "click", _button(button), display=desktop)
    return "ok"


@mcp.tool()
def double_click(desktop: int, x: int, y: int) -> str:
    """Double-click the left button at (x, y)."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x, y), "click", "--repeat", "2", "--delay", "80", "1", display=desktop)
    return "ok"


@mcp.tool()
def move(desktop: int, x: int, y: int) -> str:
    """Move the pointer to (x, y)."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x, y), display=desktop)
    return "ok"


@mcp.tool()
def drag(desktop: int, x1: int, y1: int, x2: int, y2: int) -> str:
    """Press the left button at (x1, y1), move to (x2, y2), release."""
    need(desktop)
    run("xdotool", "mousemove", "--sync", *pt(x1, y1), "mousedown", "1", "sleep", "0.1",
        "mousemove", "--sync", *pt(x2, y2), "mouseup", "1", display=desktop)
    return "ok"


@mcp.tool(name="type")
def type_text(desktop: int, text: str) -> str:
    """Type text into the focused window. Max 10000 characters."""
    need(desktop)
    if len(text) > 10000:
        raise ValueError("text too long: max 10000 characters")
    run("xdotool", "type", "--delay", "12", "--", text, display=desktop, timeout=30 + len(text) * 0.03)
    return "ok"


@mcp.tool()
def key(desktop: int, combo: str) -> str:
    """Press a key or combination, xdotool syntax: Return, ctrl+c, ctrl+alt+t, super."""
    need(desktop)
    if not core.valid_key_combo(combo):
        raise ValueError(f"invalid key combo {combo!r}")
    run("xdotool", "key", "--", combo, display=desktop)
    return "ok"


@mcp.tool()
def scroll(desktop: int, x: int, y: int, direction: str = "down", amount: int = 3) -> str:
    """Scroll at (x, y). direction: up, down, left, right. amount: 1-50 notches."""
    need(desktop)
    if direction not in core.SCROLL:
        raise ValueError(f"direction must be one of {sorted(core.SCROLL)}")
    amount = min(max(int(amount), 1), 50)
    run("xdotool", "mousemove", "--sync", *pt(x, y), "click", "--repeat", str(amount), "--delay", "30",
        core.SCROLL[direction], display=desktop)
    return "ok"


@mcp.tool()
def cursor_position(desktop: int) -> dict:
    """Current pointer position in screenshot coordinates."""
    need(desktop)
    out = run("xdotool", "getmouselocation", "--shell", display=desktop)
    vals = dict(line.split("=", 1) for line in out.split() if "=" in line)
    x, y = core.to_scaled(int(vals["X"]), int(vals["Y"]), conf()[1])
    return {"x": x, "y": y}


class BearerAuth:
    """ASGI wrapper: every HTTP request must carry Authorization: Bearer <token>. Lifespan passes through."""

    def __init__(self, app, token):
        self.app, self.expected = app, b"Bearer " + token

    async def __call__(self, scope, receive, send):
        if scope["type"] != "lifespan":
            got = dict(scope.get("headers", {})).get(b"authorization", b"")
            if not hmac.compare_digest(got, self.expected):
                if scope["type"] == "websocket":
                    await send({"type": "websocket.close", "code": 1008})
                else:
                    await send({"type": "http.response.start", "status": 401,
                                "headers": [(b"content-type", b"text/plain"), (b"www-authenticate", b"Bearer")]})
                    await send({"type": "http.response.body", "body": b"unauthorized\n"})
                return
        await self.app(scope, receive, send)


def serve_http(hostport):
    import uvicorn
    host, _, port = hostport.rpartition(":")
    path = os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/etc/agentos"), "mcp-token")
    try:
        token = open(path, "rb").read().strip()
    except FileNotFoundError:
        sys.exit(f"MCP token file {path} not found")
    if len(token) < 32:
        sys.exit(f"MCP token in {path} missing or too short")
    uvicorn.run(BearerAuth(mcp.streamable_http_app(), token), host=host, port=int(port), log_level="warning")


def main():
    if sys.argv[1:2] == ["--http"] and len(sys.argv) == 3:
        serve_http(sys.argv[2])
    else:
        mcp.run()


if __name__ == "__main__":
    main()
