# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_node_24()     { vml 'node --version | grep -q "^v24\."'; }
check_python()      { vml 'python3 --version && python3 -m venv --help >/dev/null && pipx --version'; }
check_go()          { vml 'go version'; }
check_rust()        { vml 'cargo --version && rustc --version && cargo clippy --version && rustfmt --version'; }
check_rust_user()   { vml 'test "$(command -v cargo)" = "$HOME/.cargo/bin/cargo"'; }
check_bun()         { vml 'bun --version'; }
check_java()        { vml 'java -version 2>&1 | grep -q "\"21\."'; }
check_build_tools() { vml 'gcc --version && make --version && pkg-config --version'; }
check_cli_utils()   { vml 'git --version && rg --version && fdfind --version && jq --version && tmux -V'; }
check_docker()      { vm 'id -nG | grep -qw docker && docker run --rm hello-world | grep -q "Hello from Docker"'; }
check_tailscale()   { vm 'tailscale version && systemctl is-active tailscaled'; }
check_playwright()  { vml 'test -d "$HOME/.cache/ms-playwright" && ls "$HOME/.cache/ms-playwright" | grep -q chromium'; }
