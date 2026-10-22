# shellcheck shell=bash
# AgentOS KEY=VALUE env-file helpers. Sourced by agentos-firstboot and agentos-config.
AGENTOS_ENV=/etc/agentos/agentos.env
AGENTOS_SECRETS=/home/agent/.config/agentos/secrets.env

env_get() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n1 || true; }

env_unset() {
  [ -f "$1" ] || return 0
  local tmp; tmp=$(mktemp "$1.XXXXXX")
  grep -v "^$2=" "$1" > "$tmp" || true
  chmod --reference="$1" "$tmp"; chown --reference="$1" "$tmp" 2>/dev/null || true
  mv "$tmp" "$1"
}

env_set() {
  [[ $2 =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "invalid key: $2" >&2; return 2; }
  [[ $3 != *$'\n'* ]] || { echo "value for $2 contains a newline" >&2; return 2; }
  [ -f "$1" ] || install -m 600 /dev/null "$1"
  env_unset "$1" "$2"
  printf '%s=%s\n' "$2" "$3" >> "$1"
}

is_secret_key() { [[ $1 =~ ^[A-Z0-9_]*(API_KEY|TOKEN)$ ]]; }
