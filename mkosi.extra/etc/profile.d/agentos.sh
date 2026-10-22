# shellcheck shell=sh
# AgentOS: user toolchain paths for the agent user.
for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin" "$HOME/.opencode/bin" "$HOME/.grok/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
export PATH

# AgentOS: API keys / tokens for agent CLIs (written by agentos-firstboot / agentos-config).
# Parsed, never sourced: values are data, not shell.
if [ -r "$HOME/.config/agentos/secrets.env" ]; then
  # Split on the first "=" by hand: IFS='=' read would drop a trailing "=" (base64 padding).
  while IFS= read -r _ag_l || [ -n "$_ag_l" ]; do
    _ag_k=${_ag_l%%=*}; _ag_v=${_ag_l#*=}
    case $_ag_l in *=*) ;; *) continue ;; esac
    case $_ag_k in ''|[!A-Z_]*|*[!A-Z0-9_]*) continue ;; esac
    export "$_ag_k=$_ag_v"
  done < "$HOME/.config/agentos/secrets.env"
  unset _ag_l _ag_k _ag_v
fi

# AgentOS: terminal console mode — full-screen terminal on tty1 after login.
if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ "$(id -un)" = agent ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
   grep -qx 'AGENTOS_CONSOLE=terminal' /etc/agentos/console.mode 2>/dev/null && [ -e /dev/dri/card0 ]; then
  # No exec: if cage cannot start (no GPU/seat), fall back to this shell instead of a login loop.
  cage -- foot -e tmux new -A -s main
fi
