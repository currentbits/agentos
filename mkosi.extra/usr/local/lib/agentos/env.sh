# shellcheck shell=bash
# AgentOS KEY=VALUE env-file helpers. Sourced by agentos-firstboot and agentos-config.
# shellcheck disable=SC2034 # used by scripts that source this file, not by env.sh itself
AGENTOS_ENV=/etc/agentos/agentos.env
# shellcheck disable=SC2034 # used by scripts that source this file, not by env.sh itself
AGENTOS_SECRETS=/home/agent/.config/agentos/secrets.env

env_get() {
  [[ $2 =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 2
  [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n1 || true
}

env_unset() {
  [[ $2 =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 2
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

# validate_setting KEY VALUE: 0 if VALUE is acceptable for KEY, else print why to stderr and
# return 2. Empty means "use the default" and is always accepted; unknown keys are not checked.
# Shared by agentos-config (rejects on set) and agentos-firstboot (falls back to the default).
validate_setting() {
  local re want
  [ -z "$2" ] && return 0
  case $1 in
    AGENTOS_LAN_SSH|AGENTOS_AUTO_REBOOT|AGENTOS_WEB|AGENTOS_SOLENTA) re='^[01]$'; want='0 or 1' ;;
    AGENTOS_CONSOLE)              re='^(headless|terminal)$'; want='headless or terminal' ;;
    AGENTOS_MAX_DESKTOPS)         re='^([1-9]|1[0-6])$'; want='a number from 1 to 16' ;;
    AGENTOS_SCREENSHOT_WIDTH)     re='^(6[4-9][0-9]|[7-9][0-9]{2}|1[0-8][0-9]{2}|19[01][0-9]|1920)$'; want='a number from 640 to 1920' ;;
    AGENTOS_DESKTOP_IDLE_MINUTES) re='^(0|[1-9][0-9]{0,5})$'; want='a number of minutes from 0 to 999999' ;;
    AGENTOS_WEB_USERS)            re='^[^,[:space:]]+@[^,[:space:]]+(,[^,[:space:]]+@[^,[:space:]]+)*$'; want='a comma-separated list of tailnet logins (you@example.com)' ;;
    *) return 0 ;;
  esac
  [[ $2 =~ $re ]] || { echo "$1 must be $want" >&2; return 2; }
}
