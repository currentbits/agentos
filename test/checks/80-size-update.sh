# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_root_size_budget() {
  local used; used=$(vm 'df --output=used -BM / | tail -1 | tr -dc 0-9')
  echo "root used: ${used} MiB (budget 7168)"; [ "$used" -le 7168 ]
}
check_no_foreign_locales() { vm 'test -z "$(ls /usr/share/locale | grep -vE "^(en|en_US|en_GB|locale.alias)$")"'; }
check_no_man_pages()       { vm 'test -z "$(find /usr/share/man -type f -name "*.gz" 2>/dev/null | head -1)"'; }
check_agentos_update() {  # also: playwright's install GCs browser builds no install uses any more
  # The AgentOS repo itself is exercised by check_update_end_to_end (a local signed repo); a
  # release build's real repo may not exist yet (a first release is built before it is
  # published), so this run sets the AgentOS source aside and updates everything else.
  vm 'S=/etc/apt/sources.list.d/agentos.sources; sudo cp "$S" /var/tmp/agentos.sources.keep &&
      { grep -qx "Enabled: no" "$S" || sudo sed -i "s/^Types: deb$/Enabled: no\nTypes: deb/" "$S"; } &&
      agentos-update; rc=$?; sudo cp /var/tmp/agentos.sources.keep "$S"
      [ $rc = 0 ] && test "$(ls ~/.cache/ms-playwright | grep -c "^chromium-")" = 1'
}
