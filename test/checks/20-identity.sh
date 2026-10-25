# shellcheck shell=bash
# shellcheck disable=SC2016 # vm/vml bodies are single-quoted on purpose: $vars expand on the
# remote guest, not here.
check_host_keys_present() { vm 'test -s /etc/ssh/ssh_host_ed25519_key.pub'; }
check_machine_id_set()    { vm 'test "$(wc -c < /etc/machine-id)" -eq 33'; }
check_identity_unique_across_boots() {
  vm 'cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub' > "$WORK/ident-$MODE"
  local other others=0
  for other in "$WORK"/ident-*; do
    [ "$other" = "$WORK/ident-$MODE" ] && continue
    others=$((others + 1))
    if cmp -s "$other" "$WORK/ident-$MODE"; then echo "identity identical to $other"; return 1; fi
  done
  [ "$others" -gt 0 ] || { echo "SKIP: only one mode ran, nothing to compare"; return 0; }
}
