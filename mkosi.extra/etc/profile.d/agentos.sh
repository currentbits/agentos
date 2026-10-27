# shellcheck shell=sh
# AgentOS: user toolchain paths and API keys for the agent user (shared with the CLI wrappers).
# shellcheck source=../../usr/local/lib/agentos/load-secrets.sh
. "${AGENTOS_LIB:-/usr/local/lib/agentos}/load-secrets.sh"
for d in $AGENTOS_USER_DIRS; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
unset d
export PATH

# AgentOS: terminal console mode — full-screen terminal on tty1 after login.
if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ "$(id -un)" = agent ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
   grep -qx 'AGENTOS_CONSOLE=terminal' /etc/agentos/console.mode 2>/dev/null && [ -e /dev/dri/card0 ]; then
  # No exec: if cage cannot start (no GPU/seat), fall back to this shell instead of a login loop.
  cage -- foot -e tmux new -A -s main
fi
