"""Pure logic for agentos-computer: coordinate scaling, desktop bookkeeping, validation. No I/O."""
import json
import re

SCREEN_W, SCREEN_H = 1920, 1080
BUTTONS = {"left": "1", "middle": "2", "right": "3"}
SCROLL = {"up": "4", "down": "5", "left": "6", "right": "7"}

_UNIT_RE = re.compile(r"^agentos-desktop@(\d+)\.service\b", re.M)
_KEY_RE = re.compile(r"^[A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*$")


def scaled_size(target_w):
    return target_w, round(SCREEN_H * target_w / SCREEN_W)


def to_screen(x, y, target_w):
    f = SCREEN_W / target_w
    return (min(max(round(x * f), 0), SCREEN_W - 1),
            min(max(round(y * f), 0), SCREEN_H - 1))


def to_scaled(sx, sy, target_w):
    f = target_w / SCREEN_W
    return round(sx * f), round(sy * f)


def active_desktops(systemctl_output):
    return sorted({int(n) for n in _UNIT_RE.findall(systemctl_output)})


def lowest_free(active, max_n):
    return next((n for n in range(1, max_n + 1) if n not in active), None)


def view_url(host, token):
    return f"http://{host}:6080/vnc.html?path=websockify%3Ftoken%3D{token}&autoconnect=1&resize=scale"


def parse_token_file(text):
    return text.split(":", 1)[0].strip()


def parse_conf(text, defaults):
    conf = dict(defaults)
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key in defaults:
            conf[key] = value.strip()
    return conf


def valid_key_combo(combo):
    return bool(_KEY_RE.match(combo)) and "\n" not in combo


def tailnet_host(status_json):
    """Self.DNSName from `tailscale status --json`, trailing dot stripped. None if unavailable."""
    try:
        data = json.loads(status_json)
    except ValueError:
        return None
    name = (data.get("Self") or {}).get("DNSName") or ""
    return name.rstrip(".") or None
