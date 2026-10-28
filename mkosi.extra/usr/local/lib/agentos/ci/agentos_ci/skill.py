"""Install the agentos-ci skill text into each agent CLI's skill or global-instructions file.

Idempotent. Only the marked block is ever replaced; a skill file the user rewrote without the
markers is left alone, and other content in a shared AGENTS.md is never touched.
"""
import os
import re
import sys
from pathlib import Path

from .runs import home

SOURCE = Path(__file__).resolve().parent.parent / "skill.md"
BEGIN = "<!-- agentos-ci:begin (managed by AgentOS; this block is rewritten at boot, edit outside it) -->"
END = "<!-- agentos-ci:end -->"
BLOCK_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", re.S)
FRONT = ("---\nname: agentos-ci\ndescription: Run this box's built-in CI with the agentos-ci MCP tools before "
         "declaring work in a repo done; read failures, fix the root cause, re-run.\n---\n\n")
# (path under $HOME, is a whole skill file)
# Codex also reads ~/.codex/AGENTS.override.md first if present, which wins over AGENTS.md
# entirely for Codex (not just the managed block); and Codex truncates AGENTS.md at 32 KiB, so a
# file that grows past that silently loses our block. Neither case is detected here.
TARGETS = [
    (".claude/skills/agentos-ci/SKILL.md", True),     # Claude Code; opencode also reads ~/.claude/skills
    (".grok/skills/agentos-ci/SKILL.md", True),       # Grok Build user skills
    (".codex/AGENTS.md", False),                      # Codex global instructions
    (".config/opencode/AGENTS.md", False),            # opencode global rules
]


def block() -> str:
    return f"{BEGIN}\n{SOURCE.read_text().strip()}\n{END}\n"


def write_atomic(path: Path, text: str) -> None:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text)
    if path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o7777)
    os.replace(tmp, path)


def upsert(path: Path, is_skill: bool) -> str:
    b = block()
    if not path.exists():
        write_atomic(path, (FRONT if is_skill else "") + b)
        return "created"
    text = path.read_text()
    n_begin, n_end = text.count(BEGIN), text.count(END)
    well_formed = n_begin == 1 and n_end == 1 and text.index(BEGIN) < text.index(END)
    if well_formed:
        new = BLOCK_RE.sub(lambda _: b, text, count=1)
    elif n_begin == 0 and n_end == 0:
        if is_skill:
            return "kept"                      # the user replaced our skill file: theirs now
        new = text + ("" if text.endswith("\n\n") or not text else "\n" if text.endswith("\n") else "\n\n") + b
    else:
        # A marker is present but the block is missing its other half, out of order, or
        # duplicated: a lazy regex over this would span user text between two markers and delete
        # it. Leave the file alone rather than guess.
        print(f"agentos-ci: {path} has a malformed agentos-ci block; left it alone", file=sys.stderr)
        return "kept"
    if new == text:
        return "unchanged"
    write_atomic(path, new)
    return "updated"


def install() -> dict:
    return {rel: upsert(home() / rel, is_skill) for rel, is_skill in TARGETS}
