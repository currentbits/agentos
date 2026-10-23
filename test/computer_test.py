#!/usr/bin/env python3
"""Unit tests for agentos-computer core logic. Stdlib only: python3 test/computer_test.py"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mkosi.extra", "usr", "local", "lib", "agentos", "computer"))
import core  # noqa: E402

# scaling: 1366 wide keeps 16:9
assert core.scaled_size(1366) == (1366, 768)
assert core.scaled_size(1920) == (1920, 1080)
assert core.to_screen(683, 384, 1366) == (960, 540)
assert core.to_screen(0, 0, 1366) == (0, 0)
assert core.to_screen(1366, 768, 1366) == (1919, 1079)          # clamped to last pixel
assert core.to_screen(-5, 99999, 1366) == (0, 1079)
assert core.to_screen(960, 540, 1920) == (960, 540)             # identity at full width
assert core.to_scaled(960, 540, 1366) == (683, 384)
for x, y in [(0, 0), (100, 50), (683, 384), (1365, 767)]:        # round trip within 1 px
    sx, sy = core.to_screen(x, y, 1366)
    bx, by = core.to_scaled(sx, sy, 1366)
    assert abs(bx - x) <= 1 and abs(by - y) <= 1, (x, y, bx, by)

# systemd bookkeeping
out = ("agentos-desktop@3.service loaded active running AgentOS desktop 3\n"
       "agentos-desktop@1.service loaded active running AgentOS desktop 1\n")
assert core.active_desktops(out) == [1, 3]
assert core.active_desktops("") == []
assert core.lowest_free([1, 3], 8) == 2
assert core.lowest_free([], 8) == 1
assert core.lowest_free([1, 2], 2) is None

# viewer + config
url = core.view_url("agentos-01", "abc123")
assert url == "http://agentos-01:6080/vnc.html?path=websockify%3Ftoken%3Dabc123&autoconnect=1&resize=scale", url
assert core.parse_token_file("abc123: localhost:5901\n") == "abc123"
defaults = {"MAX_DESKTOPS": "8", "SCREENSHOT_WIDTH": "1366"}
assert core.parse_conf("MAX_DESKTOPS=4\n# comment\ngarbage\nOTHER=1\n", defaults) == {"MAX_DESKTOPS": "4", "SCREENSHOT_WIDTH": "1366"}
assert core.parse_conf("", defaults) == defaults

# key combos passed to xdotool key
for ok in ["Return", "ctrl+alt+t", "ctrl+shift+Tab", "F5", "super", "KP_Enter"]:
    assert core.valid_key_combo(ok), ok
for bad in ["", "ctrl++", "+a", "a;rm -rf", "ctrl alt", "--help", "a\nb"]:
    assert not core.valid_key_combo(bad), bad

assert core.BUTTONS == {"left": "1", "middle": "2", "right": "3"}
assert core.SCROLL == {"up": "4", "down": "5", "left": "6", "right": "7"}

# tailnet host, for Plan 3 view URLs
assert core.tailnet_host('{"Self": {"DNSName": "agentos-01.tailxyz.ts.net."}}') == "agentos-01.tailxyz.ts.net"
assert core.tailnet_host('{"Self": {"DNSName": ""}}') is None
assert core.tailnet_host('not json') is None
assert core.tailnet_host('{"Peer": {}}') is None
print("core OK")
