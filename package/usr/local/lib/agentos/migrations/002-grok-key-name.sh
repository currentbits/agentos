#!/bin/bash
# Grok reads its API key from XAI_API_KEY; AgentOS 1.0.0 stored it as GROK_CODE_XAI_API_KEY, which
# Grok never sees. Rename it in the agent's secrets.env (unless XAI_API_KEY is already set there),
# keeping the file's owner and 0600 mode. load-secrets.sh still maps the old name, for keys added
# by hand later. Safe to run again. AGENTOS_SECRETS points the unit test at a scratch file.
set -euo pipefail
S=${AGENTOS_SECRETS:-/home/agent/.config/agentos/secrets.env}
[ -f "$S" ] && grep -q '^GROK_CODE_XAI_API_KEY=' "$S" || exit 0
if grep -q '^XAI_API_KEY=' "$S"; then
  sed -i '/^GROK_CODE_XAI_API_KEY=/d' "$S"
else
  sed -i 's/^GROK_CODE_XAI_API_KEY=/XAI_API_KEY=/' "$S"
fi
