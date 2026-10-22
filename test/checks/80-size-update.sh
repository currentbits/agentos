# shellcheck shell=bash
check_root_size_budget() {
  local used; used=$(vm 'df --output=used -BM / | tail -1 | tr -dc 0-9')
  echo "root used: ${used} MiB (budget 4608)"; [ "$used" -le 4608 ]
}
check_no_foreign_locales() { vm 'test -z "$(ls /usr/share/locale | grep -vE "^(en|en_US|en_GB|locale.alias)$")"'; }
check_no_man_pages()       { vm 'test -z "$(find /usr/share/man -type f -name "*.gz" 2>/dev/null | head -1)"'; }
check_agentos_update()     { vm 'agentos-update' ; }
