# shellcheck shell=sh
# AgentOS: user toolchain paths for the agent user.
for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin" "$HOME/.opencode/bin" "$HOME/.grok/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
export PATH

# AgentOS: API keys / tokens for agent CLIs (written by agentos-firstboot / agentos-config).
if [ -r "$HOME/.config/agentos/secrets.env" ]; then
  set -a; . "$HOME/.config/agentos/secrets.env"; set +a
fi
