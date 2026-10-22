# shellcheck shell=sh
# AgentOS: user toolchain paths for the agent user.
for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin" "$HOME/.opencode/bin" "$HOME/.grok/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
export PATH

# AgentOS: API keys / tokens for agent CLIs (written by agentos-firstboot / agentos-config).
# Parsed, never sourced: values are data, not shell.
if [ -r "$HOME/.config/agentos/secrets.env" ]; then
  while IFS='=' read -r _ag_k _ag_v; do
    case $_ag_k in ''|[!A-Z_]*|*[!A-Z0-9_]*) continue ;; esac
    export "$_ag_k=$_ag_v"
  done < "$HOME/.config/agentos/secrets.env"
  unset _ag_k _ag_v
fi
