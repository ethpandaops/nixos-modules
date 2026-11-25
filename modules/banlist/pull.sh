# nixhost-banlist-pull: every $INTERVAL seconds, fetch the signed list from
# $URL and load it into the ban (or shadow) sets if every check passes;
# otherwise keep what's loaded. The header of default.nix lists the checks.
# Environment: URL USER_NAME PASSWORD_FILE SIGNERS MODE INTERVAL IPV6, and
# systemd's STATE_DIRECTORY and RUNTIME_DIRECTORY.

work=$RUNTIME_DIRECTORY
families=(4)
if [ -n "$IPV6" ]; then families+=(6); fi

loaded=""       # the generation this process loaded; "" until its first load
list_mode=""    # that list's mode
effective=""    # what's in force: enforce, shadow or empty
generated_at=0  # the newest signing time seen for the loaded generation
last_success=0  # when a fetched list last verified (loaded or unchanged)
reason=""       # why the last fetch wasn't loaded
detail=""
last_reason=""
declare -A rejected=()
for r in fetch signature invalid stale replay too_many too_wide coverage too_many_added load; do
  rejected[$r]=0
done

fail() {
  reason=$1
  detail=$2
}

curl_config() {
  local password
  password=$(cat "$PASSWORD_FILE")
  password=${password//\\/\\\\}
  printf 'user = "%s:%s"\n' "$USER_NAME" "${password//\"/\\\"}"
}

# load <effective> <list>: replace the contents of the sets it fills, and
# empty the others.
load() {
  local n family fill new e
  local -a empty
  for n in "${families[@]}"; do
    family=inet
    [ "$n" = 6 ] && family=inet6
    if ! { ipset list -n "nixhost-ban$n-v1" && ipset list -n "nixhost-shadow$n-v1"; } >/dev/null 2>&1; then
      fail load "the IPv$n sets don't exist (see nixhost-banlist-sets)"
      return 1
    fi
    case $1 in
    enforce) fill=ban empty=(shadow) ;;
    shadow) fill=shadow empty=(ban) ;;
    *) fill="" empty=(ban shadow) ;;
    esac
    if [ -n "$fill" ]; then
      new="nixhost-$fill$n-v1-new"
      ipset destroy "$new" 2>/dev/null || true
      if ! {
        echo "create $new hash:net family $family timeout 0 maxelem 65536"
        jq -r --argjson n "$n" --arg set "$new" '.entries[] | select(.family == $n) | "add \($set) \(.cidr) timeout \(.timeout)"' "$2"
      } | ipset -exist restore 2>"$work/ipset.err"; then
        ipset destroy "$new" 2>/dev/null || true
        fail load "ipset refused the IPv$n entries: $(head -c 200 "$work/ipset.err")"
        return 1
      fi
      if ! { ipset swap "$new" "nixhost-$fill$n-v1" && ipset destroy "$new"; }; then
        fail load "couldn't swap in the IPv$n entries"
        return 1
      fi
    fi
    for e in "${empty[@]}"; do
      if ! ipset flush "nixhost-$e$n-v1"; then
        fail load "couldn't empty nixhost-$e$n-v1"
        return 1
      fi
    done
  done
}

# pull: 0 if the fetched list is loaded or is the loaded one; otherwise 1
# with reason and detail set.
pull() {
  local now code gen prev at new_mode persisted want added
  now=$(date +%s)
  rm -f "$work/envelope" "$work/payload" "$work/payload.sig" "$work/list"
  if ! code=$(curl --silent --show-error --compressed --max-time 20 --max-filesize 16777216 \
    --config <(curl_config) --output "$work/envelope" --write-out '%{http_code}' "$URL" 2>"$work/curl.err"); then
    fail fetch "$(head -c 200 "$work/curl.err")"
    return 1
  fi
  if [ "$code" != 200 ]; then
    fail fetch "HTTP $code"
    return 1
  fi
  if ! { jq -er '.payload | strings' "$work/envelope" | base64 -d >"$work/payload"; } 2>/dev/null ||
    ! jq -er '.signature | strings' "$work/envelope" >"$work/payload.sig" 2>/dev/null; then
    fail invalid "not a payload and signature"
    return 1
  fi
  if ! ssh-keygen -Y verify -f "$SIGNERS" -I nixhost-banlist -n nixhost-banlist \
    -s "$work/payload.sig" <"$work/payload" >/dev/null 2>&1; then
    fail signature "not signed by any of publicKeys"
    return 1
  fi
  if ! jq -c --argjson now "$now" -f "$VALIDATE" "$work/payload" >"$work/list" 2>/dev/null; then
    fail invalid "not JSON"
    return 1
  fi
  if jq -e 'has("error")' "$work/list" >/dev/null; then
    fail "$(jq -r .error "$work/list")" "$(jq -r .detail "$work/list")"
    return 1
  fi
  read -r gen prev at new_mode < <(jq -r '[.generation, .previous, .generated_at, .mode] | @tsv' "$work/list")

  persisted=$(cat "$STATE_DIRECTORY/generation" 2>/dev/null || echo 0)
  if [ "$gen" -lt "$persisted" ]; then
    fail replay "generation $gen is older than $persisted, which this host loaded"
    return 1
  fi
  # The same generation, signed again: the same entries, so only fresher.
  if [ "$gen" = "$loaded" ]; then
    if [ "$at" -gt "$generated_at" ]; then generated_at=$at; fi
    last_success=$now
    return 0
  fi

  want=$new_mode
  if [ "$want" = enforce ] && [ "$MODE" = shadow ]; then want=shadow; fi
  # Following the generation loaded here: a sudden flood of new entries is
  # more likely a fault than an attack, so wait for it to be fixed.
  if [ "$want" = enforce ] && [ -n "$loaded" ] && [ "$prev" != 0 ] && [ "$prev" = "$loaded" ]; then
    added=$(jq -r '.entries[].cidr' "$work/list" | sort -u | comm -23 - "$work/loaded-cidrs" | wc -l)
    if [ "$added" -gt 500 ]; then
      fail too_many_added "generation $gen adds $added entries to $loaded, more than 500"
      return 1
    fi
  fi

  load "$want" "$work/list" || return 1
  jq -r '.entries[].cidr' "$work/list" | sort -u >"$work/loaded-cidrs"
  echo "$gen" >"$STATE_DIRECTORY/generation.new" && mv -f "$STATE_DIRECTORY/generation.new" "$STATE_DIRECTORY/generation"
  echo "loaded generation $gen ($new_mode list, $want here): $(jq '.entries | length' "$work/list") entries"
  loaded=$gen list_mode=$new_mode effective=$want generated_at=$at last_success=$now
}

metrics() {
  local n ready=1 s ipt
  for n in "${families[@]}"; do
    ipt=iptables
    [ "$n" = 6 ] && ipt=ip6tables
    "$ipt" -w -t mangle -C PREROUTING -j nixos-ban 2>/dev/null || ready=0
  done
  echo "# HELP nixhost_banlist_info The configured mode, the loaded list's mode, and what's in force."
  echo "# TYPE nixhost_banlist_info gauge"
  echo "nixhost_banlist_info{mode=\"$MODE\",list_mode=\"$list_mode\",effective=\"$effective\"} 1"
  echo "# HELP nixhost_banlist_ready Whether the nixos-ban chain is in place for every address family."
  echo "# TYPE nixhost_banlist_ready gauge"
  echo "nixhost_banlist_ready $ready"
  echo "# HELP nixhost_banlist_generation The loaded list's generation (0: none yet)."
  echo "# TYPE nixhost_banlist_generation gauge"
  echo "nixhost_banlist_generation ${loaded:-0}"
  echo "# HELP nixhost_banlist_generated_timestamp_seconds When the loaded generation was last signed."
  echo "# TYPE nixhost_banlist_generated_timestamp_seconds gauge"
  echo "nixhost_banlist_generated_timestamp_seconds $generated_at"
  echo "# HELP nixhost_banlist_last_success_timestamp_seconds When a fetched list last verified."
  echo "# TYPE nixhost_banlist_last_success_timestamp_seconds gauge"
  echo "nixhost_banlist_last_success_timestamp_seconds $last_success"
  echo "# HELP nixhost_banlist_rejected_total Fetched lists not loaded, by reason."
  echo "# TYPE nixhost_banlist_rejected_total counter"
  for r in "${!rejected[@]}"; do
    echo "nixhost_banlist_rejected_total{reason=\"$r\"} ${rejected[$r]}"
  done
  echo "# HELP nixhost_banlist_entries Entries in each set."
  echo "# TYPE nixhost_banlist_entries gauge"
  for n in "${families[@]}"; do
    for s in ban shadow; do
      echo "nixhost_banlist_entries{family=\"ipv$n\",set=\"$s\"} $(ipset list -t "nixhost-$s$n-v1" 2>/dev/null | awk -F': ' '/^Number of entries/ { n = $2 } END { print n + 0 }')"
    done
  done
  echo "# HELP nixhost_banlist_matched_packets_total New-connection packets each set matched (shadow: not dropped)."
  echo "# TYPE nixhost_banlist_matched_packets_total counter"
  for n in "${families[@]}"; do
    ipt=iptables
    [ "$n" = 6 ] && ipt=ip6tables
    for s in ban shadow; do
      echo "nixhost_banlist_matched_packets_total{family=\"ipv$n\",set=\"$s\"} $("$ipt" -w -t mangle -nvxL nixos-ban 2>/dev/null | awk -v set="nixhost-$s$n-v1" '$0 ~ "match-set " set " src" { n += $1 } END { print n + 0 }')"
    done
  done
}

touch "$work/loaded-cidrs"
while true; do
  if pull; then
    if [ -n "$last_reason" ]; then
      echo "the list verifies again (generation $loaded)"
      last_reason=""
    fi
  else
    rejected[$reason]=$((${rejected[$reason]:-0} + 1))
    # Once per reason in a row, not every $INTERVAL seconds.
    if [ "$reason" != "$last_reason" ]; then
      echo "kept generation ${loaded:-none}: $reason: $detail" >&2
      last_reason=$reason
    fi
  fi
  metrics | write_metrics nixhost_banlist
  sleep "$INTERVAL"
done
