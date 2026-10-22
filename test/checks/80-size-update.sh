# shellcheck shell=bash
check_root_size_budget() {
  local used; used=$(vm 'df --output=used -BM / | tail -1 | tr -dc 0-9')
  echo "root used: ${used} MiB (budget 7168)"; [ "$used" -le 7168 ]
}
check_no_foreign_locales() { vm 'test -z "$(ls /usr/share/locale | grep -vE "^(en|en_US|en_GB|locale.alias)$")"'; }
check_no_man_pages()       { vm 'test -z "$(find /usr/share/man -type f -name "*.gz" 2>/dev/null | head -1)"'; }
check_agentos_update() {  # also: playwright's install GCs browser builds no install uses any more
  vm 'agentos-update && test "$(ls ~/.cache/ms-playwright | grep -c "^chromium-")" = 1'
}
