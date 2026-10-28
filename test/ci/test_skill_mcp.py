import asyncio

from conftest import ci_yml, make_repo
from agentos_ci import skill
from agentos_ci.skill import BEGIN, END


def test_skill_install_is_idempotent_and_keeps_user_content(home):
    assert set(skill.install().values()) == {"created"}
    claude = home / ".claude/skills/agentos-ci/SKILL.md"
    text = claude.read_text()
    assert text.startswith("---\nname: agentos-ci\ndescription: ") and BEGIN in text and "ci_wait" in text
    assert (home / ".grok/skills/agentos-ci/SKILL.md").read_text() == text
    assert set(skill.install().values()) == {"unchanged"}

    codex = home / ".codex/AGENTS.md"
    codex.write_text("# mine\nkeep me\n\n" + codex.read_text().replace("ci_wait", "OLD") + "\n# after\n")
    claude.write_text("my own skill\n")                                  # user replaced it: hands off
    oc = home / ".config/opencode/AGENTS.md"
    oc.write_text("user rules\n")
    res = skill.install()
    assert res[".codex/AGENTS.md"] == "updated" and res[".claude/skills/agentos-ci/SKILL.md"] == "kept"
    assert res[".config/opencode/AGENTS.md"] == "updated"
    c = codex.read_text()
    assert c.startswith("# mine\nkeep me\n\n") and c.rstrip().endswith("# after") and "OLD" not in c
    assert c.count(BEGIN) == 1 and c.count(END) == 1
    assert claude.read_text() == "my own skill\n"
    o = oc.read_text()
    assert o.startswith("user rules\n\n" + BEGIN) and o.count(BEGIN) == 1
    assert set(skill.install().values()) <= {"unchanged", "kept"}


def test_mcp_tools(home):
    from agentos_ci import mcp_server
    tools = {t.name for t in asyncio.run(mcp_server.mcp.list_tools())}
    assert tools == {"ci_run", "ci_wait", "ci_status", "ci_logs", "ci_list", "ci_cancel"}
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("t", "echo out; exit 1"))})
    rid = mcp_server.ci_run(str(repo))["run_id"]
    res = asyncio.run(mcp_server.ci_wait(rid, 60))
    assert res == {"run_id": rid, "status": "failed", "failed_step": "t", "log_tail": "out\n"}
