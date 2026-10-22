# shellcheck shell=bash
check_host_keys_present() { vm 'test -s /etc/ssh/ssh_host_ed25519_key.pub'; }
check_machine_id_set()    { vm 'test "$(wc -c < /etc/machine-id)" -eq 33'; }
check_identity_unique_across_boots() {
  vm 'cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub' > "$WORK/ident-$MODE"
  local other
  for other in "$WORK"/ident-*; do
    [ "$other" = "$WORK/ident-$MODE" ] && continue
    ! cmp -s "$other" "$WORK/ident-$MODE" || { echo "identity identical to $other"; return 1; }
  done
}
