import json
import subprocess
import sys

from conftest import CI_DIR, ci_yml, make_repo


def cli(*args, home):
    return subprocess.run([sys.executable, str(CI_DIR / "main.py"), *args], capture_output=True, text=True,
                          env={"HOME": str(home), "PATH": "/usr/local/bin:/usr/bin:/bin", "AGENTOS_CI_MAX_PARALLEL": "2"})


def test_cli_json_and_exit_codes(home):
    repo = make_repo(home / "r", {".agentos/ci.yml": ci_yml(("t", "echo hi"))})
    r = cli("run", str(repo), "--wait", "--json", home=home)
    assert r.returncode == 0, r.stderr
    s = json.loads(r.stdout)
    assert s["status"] == "passed"
    st = json.loads(cli("status", s["run_id"], "--json", home=home).stdout)
    assert st["steps"][0]["name"] == "t"
    assert cli("logs", s["run_id"], "--follow", home=home).stdout == "hi\n"
    assert json.loads(cli("list", "--json", "--limit", "5", home=home).stdout)[0]["id"] == s["run_id"]
    bad = make_repo(home / "b", {".agentos/ci.yml": ci_yml(("t", "exit 3"))})
    assert cli("run", str(bad), "--wait", home=home).returncode == 1
    err = cli("status", "nope", "--json", home=home)
    assert err.returncode == 2 and "invalid run id" in err.stderr
