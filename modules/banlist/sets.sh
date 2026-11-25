# nixhost-banlist-sets start|stop: the ipsets and the mangle chain nixos-ban,
# per address family. Every step is checked: a family whose sets or rules
# can't be set up gets no chain at all, so it drops nothing.

# teardown <iptables>: take the chain out.
teardown() {
  while "$1" -w -t mangle -D PREROUTING -j nixos-ban 2>/dev/null; do :; done
  "$1" -w -t mangle -F nixos-ban 2>/dev/null || true
  "$1" -w -t mangle -X nixos-ban 2>/dev/null || true
}

# sets <4|6> <inet|inet6> <allow file>: create the sets if they're missing,
# and replace the allow set's contents in one swap.
sets() {
  local new="nixhost-allow$1-v1-new"
  ipset -exist create "nixhost-allow$1-v1" hash:net family "$2" maxelem 65536 &&
    ipset -exist create "nixhost-shadow$1-v1" hash:net family "$2" timeout 0 maxelem 65536 &&
    ipset -exist create "nixhost-ban$1-v1" hash:net family "$2" timeout 0 maxelem 65536 || return 1
  ipset destroy "$new" 2>/dev/null || true
  if ! { echo "create $new hash:net family $2 maxelem 65536" && sed "s/^/add $new /" "$3"; } | ipset restore; then
    ipset destroy "$new" 2>/dev/null || true
    return 1
  fi
  ipset swap "$new" "nixhost-allow$1-v1" && ipset destroy "$new"
}

# rules <4|6> <iptables>
rules() {
  "$2" -w -t mangle -N nixos-ban &&
    "$2" -w -t mangle -A nixos-ban -i lo -j RETURN &&
    "$2" -w -t mangle -A nixos-ban -m set --match-set "nixhost-allow$1-v1" src -j RETURN &&
    "$2" -w -t mangle -A nixos-ban -m conntrack --ctstate NEW -m set --match-set "nixhost-shadow$1-v1" src &&
    "$2" -w -t mangle -A nixos-ban -m conntrack --ctstate NEW -m set --match-set "nixhost-ban$1-v1" src -j DROP &&
    "$2" -w -t mangle -I PREROUTING 1 -j nixos-ban
}

families=("4 inet iptables $ALLOW4")
if [ -n "$IPV6" ]; then families+=("6 inet6 ip6tables $ALLOW6"); fi

for f in "${families[@]}"; do
  read -r n family ipt allow <<<"$f"
  teardown "$ipt"
  [ "$1" = start ] || continue
  if ! sets "$n" "$family" "$allow"; then
    echo "IPv$n: no ban list: the kernel couldn't create its ipsets (ip_set_hash_net not loaded? Under security.lockKernelModules it loads at the next boot)." >&2
  elif ! rules "$n" "$ipt"; then
    teardown "$ipt"
    echo "IPv$n: no ban list: the nixos-ban rules couldn't be added (xt_set not loaded?)." >&2
  fi
done
exit 0
