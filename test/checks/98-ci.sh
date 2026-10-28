# shellcheck shell=bash
# shellcheck disable=SC2016 # vm bodies are single-quoted on purpose: $vars expand on the guest.

# ci_repo NAME FILE CONTENT...: a committed repo at ~/ci-smoke/NAME (pairs of path and content).
CI_REPO='ci_repo() {
  local d=~/ci-smoke/$1; shift; rm -rf "$d"; mkdir -p "$d"
  while [ $# -gt 0 ]; do mkdir -p "$d/$(dirname "$1")"; printf "%s\n" "$2" > "$d/$1"; shift 2; done
  git -C "$d" init -q -b main && git -C "$d" add -A && git -C "$d" -c user.name=s -c user.email=s@x commit -qm init && echo "$d"
}
ci_final() {  # ci_final ID: wait for a final status and print it
  for _ in $(seq 1 600); do s=$(agentos-ci status "$1" --json | jq -r .status)
    case $s in passed|failed|cancelled|error) echo "$s"; return 0 ;; esac; sleep 1; done; return 1
}
'
check_ci_installed() {
  vm 'test "$(act --version)" = "act version 0.2.89" && /usr/local/lib/agentos/venv/bin/python -c "import yaml, mcp" &&
      grep -qE "^act 0\.2\.89 [0-9a-f]{64}$" /var/lib/agentos-manifest.txt && grep -qi "^pyyaml==6\." /var/lib/agentos-manifest.txt &&
      test "$(cat /etc/agentos/ci.conf)" = MAX_PARALLEL=2 && agentos-ci --help >/dev/null'
}
check_ci_registered_with_every_cli() {
  vml 'claude mcp get agentos-ci 2>&1 | grep -q /usr/local/bin/agentos-ci-mcp && codex mcp list 2>&1 | grep -q agentos-ci &&
       grok mcp list 2>&1 | grep -q agentos-ci' &&
  vm 'grep -A2 "^\[mcp_servers\.agentos-ci\]$" ~/.codex/config.toml | grep -qx "tool_timeout_sec = 1800" &&
      jq -e ".mcp[\"agentos-ci\"].command == [\"/usr/local/bin/agentos-ci-mcp\"]" ~/.config/opencode/opencode.json >/dev/null'
}
check_ci_skill_files_present() {
  vm 'for f in ~/.claude/skills/agentos-ci/SKILL.md ~/.grok/skills/agentos-ci/SKILL.md ~/.codex/AGENTS.md ~/.config/opencode/AGENTS.md; do
        test "$(grep -c "agentos-ci:begin" "$f")" = 1 && grep -q "ci_wait" "$f" || { echo "bad $f"; exit 1; }
      done && head -2 ~/.claude/skills/agentos-ci/SKILL.md | grep -qx "name: agentos-ci" &&
      sudo agentos-config apply && test "$(grep -c "agentos-ci:begin" ~/.codex/AGENTS.md)" = 1'
}
check_ci_push_pass_then_fail() {
  # remote create -> push a passing repo from the host -> passed; push a failing step -> failed,
  # with that step's log tail. The pusher sees the run id.
  local src=$WORK/ci-push id1 id2 rc=0
  local -a gitssh=(env "GIT_SSH_COMMAND=ssh -i $WORK/key -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR")
  vm 'rm -rf ~/git/smoke.git && agentos-ci remote create smoke' | grep -qx 'On your machine: git remote add agentos agent@agentos-test:git/smoke.git' || return 1
  rm -rf "$src" && mkdir -p "$src/.agentos" && printf 'steps:\n  - name: test\n    run: echo smoke-pass-marker\n' > "$src/.agentos/ci.yml" &&
  git -C "$src" init -q -b main && git -C "$src" add -A && git -C "$src" -c user.name=s -c user.email=s@x commit -qm pass &&
  git -C "$src" remote add agentos agent@127.0.0.1:git/smoke.git || return 1
  id1=$("${gitssh[@]}" git -C "$src" push agentos main 2>&1 | sed -n 's/^remote: agentos-ci: run \([0-9a-f-]*\) for main.*/\1/p')
  [ -n "$id1" ] || return 1
  vm "$CI_REPO"'test "$(ci_final '"$id1"')" = passed && agentos-ci logs '"$id1"' | grep -qx smoke-pass-marker' || rc=1
  printf 'steps:\n  - name: test\n    run: echo smoke-failure-marker; exit 3\n  - name: after\n    run: "true"\n' > "$src/.agentos/ci.yml"
  git -C "$src" -c user.name=s -c user.email=s@x commit -qam fail || rc=1
  id2=$("${gitssh[@]}" git -C "$src" push agentos main 2>&1 | sed -n 's/^remote: agentos-ci: run \([0-9a-f-]*\) for main.*/\1/p')
  [ -n "$id2" ] && vm "$CI_REPO"'test "$(ci_final '"$id2"')" = failed &&
    agentos-ci status '"$id2"' --json | jq -e "[.steps[] | .status] == [\"failed\", \"skipped\"] and .steps[0].exit_code == 3 and .source == \"push\"" >/dev/null &&
    agentos-ci logs '"$id2"' | grep -qx smoke-failure-marker' || rc=1
  return "$rc"
}
check_ci_clean_env_and_secrets() {
  # secrets.env holds ANTHROPIC_API_KEY (smoke user-data): only a repo that lists it sees it.
  vm 'grep -q "^ANTHROPIC_API_KEY=" ~/.config/agentos/secrets.env' &&
  vm "$CI_REPO"'
    a=$(ci_repo env-plain .agentos/ci.yml "steps: [{name: env, run: env}]") &&
    b=$(ci_repo env-secret .agentos/ci.yml "secrets: [ANTHROPIC_API_KEY]
steps: [{name: env, run: test \"\$ANTHROPIC_API_KEY\" = sk-test-dummy}]") &&
    i=$(agentos-ci run "$a") && test "$(ci_final "$i")" = passed &&
    agentos-ci logs "$i" | grep -qx CI=true && agentos-ci logs "$i" | grep -qx "AGENTOS_CI_RUN=$i" &&
    ! agentos-ci logs "$i" | grep -q ANTHROPIC_API_KEY &&
    j=$(agentos-ci run "$b") && test "$(ci_final "$j")" = passed &&
    agentos-ci status "$j" --json | jq -e ".secrets == [\"ANTHROPIC_API_KEY\"]" >/dev/null &&
    ! grep -rq sk-test-dummy ~/.local/share/agentos-ci/runs/"$j"/run.json'
}
check_ci_cancel_kills_steps() {
  # pgrep -x, not -f: this whole check is itself a `bash -c` command whose own argv contains the
  # literal text "sleep 31337 & sleep 31338" (it's right there in the ci.yml content below), so a
  # `-f` cmdline match would always find that process too, even after cancel kills the real ones.
  # `-x` matches process *names* only ("sleep" vs "bash"), which this invocation can't self-match.
  vm "$CI_REPO"'
    d=$(ci_repo cancel .agentos/ci.yml "steps: [{name: s, run: sleep 31337 & sleep 31338}]") &&
    i=$(agentos-ci run "$d") &&
    for _ in $(seq 1 30); do pgrep -x sleep >/dev/null && break; sleep 0.5; done && pgrep -x sleep >/dev/null &&
    test "$(agentos-ci cancel "$i" --json | jq -r .status)" = cancelled && sleep 1 &&
    ! pgrep -x sleep >/dev/null'
}
check_ci_autodetect_npm() {
  vm "$CI_REPO"'
    d=$(ci_repo npm package.json "{\"name\":\"s\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"node -e \\\"console.log(42*2)\\\"\"}}" \
                    package-lock.json "{\"name\":\"s\",\"version\":\"1.0.0\",\"lockfileVersion\":3,\"requires\":true,\"packages\":{\"\":{\"name\":\"s\",\"version\":\"1.0.0\"}}}") &&
    i=$(agentos-ci run "$d") && test "$(ci_final "$i")" = passed &&
    agentos-ci status "$i" --json | jq -e ".pipeline == \"auto\" and .steps[0].name == \"npm-test\"" >/dev/null &&
    agentos-ci logs "$i" | grep -qx 84'
}
check_ci_act_runs_a_workflow() {
  # act pulls catthehacker/ubuntu:act-24.04 (~570 MB compressed, more like 2 GiB unpacked) on first
  # use: needs the network.
  vm 'curl -s -o /dev/null -m 10 https://registry-1.docker.io/v2/' || { echo "SKIP: no network to Docker Hub"; return 0; }
  local rc=0
  vm "$CI_REPO"'
    d=$(ci_repo act .github/workflows/t.yml "on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: echo act-smoke-\$((6*7))") &&
    i=$(agentos-ci run "$d") && test "$(ci_final "$i")" = passed &&
    agentos-ci status "$i" --json | jq -e ".pipeline == \"act\"" >/dev/null && agentos-ci logs "$i" | grep -q act-smoke-42' || rc=1
  # A real box keeps this image cached across runs on purpose (that's the point of the cache), but
  # check_root_size_budget runs later in this same boot (sort order is alphabetical by check name,
  # "check_ci_..." before "check_root_..."), and would otherwise count this ~2 GiB one-time pull
  # against a budget meant for a freshly installed box. Drop it so this smoke boot's root size
  # reflects a fresh install.
  vm 'docker rmi -f catthehacker/ubuntu:act-24.04 catthehacker/ubuntu:act-22.04 >/dev/null 2>&1 || true'
  return "$rc"
}
check_ci_mcp_run_and_wait() {
  vm 'cat > /tmp/ci_mcp_client.py' < "$HERE/ci_mcp_client.py" &&
  vm "$CI_REPO"'
    g=$(ci_repo mcp-good .agentos/ci.yml "steps: [{name: test, run: \"true\"}]") &&
    b=$(ci_repo mcp-bad .agentos/ci.yml "steps: [{name: test, run: echo smoke-failure-marker; exit 1}]") &&
    /usr/local/lib/agentos/venv/bin/python /tmp/ci_mcp_client.py "$g" "$b"'
}
check_ci_web_api_lists_and_streams() {
  web_users && vm 'cat > /tmp/web_ws.mjs' < "$HERE/web_ws.mjs" && vm "$WEB$CI_REPO"'
    d=$(ci_repo web .agentos/ci.yml "steps: [{name: hello, run: echo web-ci-\$((40+2))}]") &&
    i=$(wm -X POST -d "{\"path\":\"$d\"}" $U/api/ci/runs | jq -r .run_id) && test -n "$i" &&
    node /tmp/web_ws.mjs cilog "$i" hello web-ci-42 &&
    test "$(ci_final "$i")" = passed &&
    w "$U/api/ci/runs?limit=5" | jq -e --arg i "$i" "any(.[]; .id == \$i and .status == \"passed\")" >/dev/null &&
    w "$U/api/ci/remotes" | jq -e "type == \"array\"" >/dev/null &&
    test "$(code -X POST -H "Tailscale-User-Login: smoke@example.com" "$U/api/ci/runs/$i/cancel")" = 403 &&
    for _ in 1 2 3 4 5; do
      sudo journalctl -b -t agentos-web -p notice --no-pager -o cat | grep -qx "smoke@example.com ci-run $d" && exit 0; sleep 1
    done; exit 1'
}
