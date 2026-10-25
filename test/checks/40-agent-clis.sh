# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_claude()   { vml 'claude --version'; }
check_codex()    { vml 'codex --version'; }
check_opencode() { vml 'opencode --version'; }
check_grok()     { vml 'grok --version'; }
check_clis_user_owned() {
  vml 'for c in claude codex opencode grok; do p=$(readlink -f "$(command -v $c)"); case "$p" in /home/agent/*) ;; *) echo "$c at $p"; exit 1;; esac; done'
}
check_manifest_lists_clis() { vm 'grep -A4 "^# agent CLIs" /var/lib/agentos-manifest.txt | grep -c . | grep -qx 5'; }
