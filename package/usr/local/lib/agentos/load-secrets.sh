# shellcheck shell=sh
# AgentOS: the agent's tool directories and API keys. Sourced (never executed) by
# /etc/profile.d/agentos.sh and by the CLI wrappers in /usr/local/bin (cli-wrapper). POSIX sh:
# profile.d also runs under dash. Sets AGENTOS_USER_DIRS and exports the keys in secrets.env.
# shellcheck disable=SC2034 # read by the scripts that source this file
AGENTOS_USER_DIRS="$HOME/.local/bin $HOME/.cargo/bin $HOME/.bun/bin $HOME/.opencode/bin $HOME/.grok/bin"

# Keys are parsed, never sourced: values are data, not shell. A CI step (agentos-ci sets
# AGENTOS_CI_RUN) gets only the keys its repo lists under secrets:, so none from here.
if [ -z "${AGENTOS_CI_RUN:-}" ] && [ -r "$HOME/.config/agentos/secrets.env" ]; then
  # Split on the first "=" by hand: IFS='=' read would drop a trailing "=" (base64 padding).
  while IFS= read -r _ag_l || [ -n "$_ag_l" ]; do
    _ag_k=${_ag_l%%=*}; _ag_v=${_ag_l#*=}
    case $_ag_l in *=*) ;; *) continue ;; esac
    case $_ag_k in ''|[!A-Z_]*|*[!A-Z0-9_]*) continue ;; esac
    export "$_ag_k=$_ag_v"
  done < "$HOME/.config/agentos/secrets.env"
  unset _ag_l _ag_k _ag_v
  # AgentOS 1.0.0 named Grok's key GROK_CODE_XAI_API_KEY; Grok only reads XAI_API_KEY.
  if [ -n "${GROK_CODE_XAI_API_KEY:-}" ] && [ -z "${XAI_API_KEY:-}" ]; then export XAI_API_KEY="$GROK_CODE_XAI_API_KEY"; fi
fi
