"""agentos-computer: MCP server driving AgentOS virtual desktops.

stdio by default (spawned by agent CLIs inside the box); --http HOST:PORT for the tailnet service.
Screenshots are scaled to SCREENSHOT_WIDTH; every coordinate a tool takes or returns is in that space.
"""
import fcntl
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

mcp = FastMCP("agentos-computer", host="0.0.0.0")


def conf():
    try:
        text = open(CONF).read()
    except FileNotFoundError:
        text = ""
    c = core.parse_conf(text, {"MAX_DESKTOPS": "8", "SCREENSHOT_WIDTH": "1366"})
    # ponytail: a hand-edited desktop.conf shouldn't be able to cause a ZeroDivisionError or
    # nonsense scaling; clamp to sane ranges and fall back to the defaults otherwise.
    try:
        max_n, width = int(c["MAX_DESKTOPS"]), int(c["SCREENSHOT_WIDTH"])
    except ValueError:
        return 8, 1366
    if not 1 <= max_n <= 16 or not 640 <= width <= 1920:
        return 8, 1366
    return max_n, width


def run(*args, display=None):
    env = dict(os.environ)
    if display is not None:
        env["DISPLAY"] = f":{display}"
    r = subprocess.run(args, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{args[0]} failed: {r.stderr.strip() or r.returncode}")
    return r.stdout


def active():
    return core.active_desktops(run("systemctl", "list-units", "agentos-desktop@*", "--state=active",
                                    "--plain", "--no-legend"))


def need(desktop):
    if desktop not in active():
        raise ValueError(f"desktop {desktop} is not running; call create_desktop first")


def info(n):
    for _ in range(50):
        try:
            token = core.parse_token_file(open(f"{TOKENS}/{n}").read())
            return {"id": n, "view_url": core.view_url(socket.gethostname(), token)}
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
    """Start a new 1920x1080 XFCE desktop. Returns its id and a live view URL for humans."""
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
    return info(n)


@mcp.tool()
def list_desktops() -> list[dict]:
    """List running desktops with their live view URLs."""
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
    run("xdotool", "mousemove", "--sync", *pt(x1, y1), "mousedown", "1",
        "mousemove", "--sync", *pt(x2, y2), "mouseup", "1", display=desktop)
    return "ok"


@mcp.tool(name="type")
def type_text(desktop: int, text: str) -> str:
    """Type text into the focused window."""
    need(desktop)
    run("xdotool", "type", "--delay", "12", "--", text, display=desktop)
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


def main():
    if sys.argv[1:2] == ["--http"]:
        print("--http not implemented yet", file=sys.stderr)
        sys.exit(2)
    mcp.run()


if __name__ == "__main__":
    main()
