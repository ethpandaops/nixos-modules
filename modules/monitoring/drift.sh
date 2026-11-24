# Compare the box with its configuration (SETTINGS, written by drift.nix) and
# the running system's /etc. Every finding is a count (nixhost_drift_<check>)
# plus up to MAX_SERIES series naming what was found.
now=$(date +%s)
current=$(readlink -f /run/current-system)
out=$(mktemp)
trap 'rm -f "$out"' EXIT

# finding <check> <help> <label name> <values...>: the count and the named series.
finding() {
  local check=$1 help=$2 name=$3
  shift 3
  {
    echo "# HELP nixhost_drift_$check $help"
    echo "# TYPE nixhost_drift_$check gauge"
    echo "nixhost_drift_$check $#"
    echo "# HELP nixhost_drift_${check}_info One series per finding, at most $MAX_SERIES."
    echo "# TYPE nixhost_drift_${check}_info gauge"
    local value n=0
    for value in "$@"; do
      n=$((n + 1))
      [ "$n" -le "$MAX_SERIES" ] || break
      echo "nixhost_drift_${check}_info{$name=\"$(label "$value")\"} 1"
    done
  } >>"$out"
}

# Accounts the configuration doesn't declare, and uid 0 for anyone but root.
declare -A declared=()
while read -r name; do
  declared[$name]=1
done < <(jq -r '.users[]' "$SETTINGS")
unexpected_users=()
uid0=()
while IFS=: read -r name _ uid _; do
  [ -n "$name" ] || continue
  [ -n "${declared[$name]:-}" ] || unexpected_users+=("$name")
  if [ "$uid" = 0 ] && [ "$name" != root ]; then
    uid0+=("$name")
  fi
done </etc/passwd
finding unexpected_users "Accounts in /etc/passwd that the configuration doesn't declare." user "${unexpected_users[@]}"
finding uid0_users "Accounts other than root with uid 0." user "${uid0[@]}"

# Members of watched groups (such as wheel) the configuration doesn't add.
unexpected_members=()
while read -r group; do
  declare -A expected=()
  while read -r member; do
    expected[$member]=1
  done < <(jq -r --arg g "$group" '.groups[$g][]' "$SETTINGS")
  IFS=, read -r -a actual <<<"$(awk -F: -v g="$group" '$1 == g { print $4 }' /etc/group)"
  for member in "${actual[@]}"; do
    [ -z "$member" ] || [ -n "${expected[$member]:-}" ] || unexpected_members+=("$group:$member")
  done
  unset expected
done < <(jq -r '.groups | keys[]' "$SETTINGS")
finding unexpected_group_members "Members of watched groups that the configuration doesn't add, as group:user." member "${unexpected_members[@]}"

# /etc files that differ from the running system's /etc (missing, edited or
# replaced), and files in watched directories that it doesn't have.
mapfile -t ignore < <(jq -r '.etcIgnore[]' "$SETTINGS")
ignored() {
  local pattern
  for pattern in "${ignore[@]}"; do
    # shellcheck disable=SC2053 # the setting is a glob
    [[ $1 == $pattern ]] && return 0
  done
  return 1
}
modified=()
while IFS= read -r -d '' rel; do
  ignored "$rel" && continue
  # <file>.mode, .uid and .gid tell activation how to copy <file>; they aren't in /etc.
  case "$rel" in
    *.mode | *.uid | *.gid) [ ! -e "$current/etc/${rel%.*}" ] || continue ;;
  esac
  # Most of /etc links into the store: the same file needs no comparison.
  [ "/etc/$rel" -ef "$current/etc/$rel" ] || cmp -s -- "/etc/$rel" "$current/etc/$rel" || modified+=("$rel")
done < <(find -L "$current/etc/" -type f -printf '%P\0' | sort -z)
finding etc_modified_files "Files under /etc that differ from the running system's /etc." path "${modified[@]}"

unmanaged=()
while read -r dir; do
  [ -d "/etc/$dir" ] || continue
  while IFS= read -r -d '' entry; do
    rel="$dir/$entry"
    ignored "$rel" && continue
    [ -e "$current/etc/$rel" ] || [ -L "$current/etc/$rel" ] || unmanaged+=("$rel")
  done < <(find "/etc/$dir/" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z)
done < <(jq -r '.etcDirs[]' "$SETTINGS")
finding etc_unmanaged_files "Files in watched /etc directories that the running system's /etc doesn't have." path "${unmanaged[@]}"

# authorized_keys in home directories: sshd reads keys only from
# /etc/ssh/authorized_keys.d, so one appearing means someone tried.
home_keys=()
while IFS=: read -r name _ _ _ _ home _; do
  case "$home" in "" | / | /var/empty) continue ;; esac
  for file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
    [ ! -e "$file" ] || home_keys+=("$name:$file")
  done
done </etc/passwd
finding home_authorized_keys "authorized_keys files in home directories, as user:path. sshd ignores them." file "${home_keys[@]}"

# Sockets listening beyond loopback on a port the configuration doesn't open,
# as "proto:port process". Docker's published ports bypass the firewall and
# show up here as docker-proxy.
declare -A open_port=() ignore_process=()
open_ranges=()
while read -r entry; do
  if [[ $entry == *-* ]]; then
    open_ranges+=("$entry")
  else
    open_port[$entry]=1
  fi
done < <(jq -r '.listen.allowed[]' "$SETTINGS")
while read -r name; do
  ignore_process[$name]=1
done < <(jq -r '.listen.ignoreProcesses[]' "$SETTINGS")
is_open() {
  local proto=$1 port=$2 range from to
  [ -z "${open_port[$proto:$port]:-}" ] || return 0
  for range in "${open_ranges[@]}"; do
    [ "${range%%:*}" = "$proto" ] || continue
    from=${range#*:} to=${range##*-}
    from=${from%-*}
    [ "$port" -lt "$from" ] || [ "$port" -gt "$to" ] || return 0
  done
  return 1
}
declare -A listening=()
# tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
while read -r proto _ _ _ local _ process; do
  port=${local##*:}
  address=${local%:*}
  address=${address%%\%*} # 0.0.0.0%eth0: bound to one interface
  case "$address" in 127.* | "[::1]" | "[::ffff:127."*) continue ;; esac
  name=unknown
  [[ $process =~ users:\(\(\"([^\"]+)\" ]] && name=${BASH_REMATCH[1]}
  # ss gives the command name, cut to 15 characters, and NixOS's wrappers
  # make it .<program>-wrapped (.tailscaled-wra); the executable's file name
  # says which program it is.
  if [[ $process =~ pid=([0-9]+) ]] && exe=$(readlink "/proc/${BASH_REMATCH[1]}/exe"); then
    name=${exe% (deleted)}
    name=${name##*/}
    name=${name#.}
    name=${name%-wrapped}
  fi
  [ -z "${ignore_process[$name]:-}" ] || continue
  is_open "$proto" "$port" && continue
  listening["$proto:$port $name"]=1
done < <(ss -H -l -n -t -u -p)
mapfile -t unexpected_listeners < <(printf '%s\n' "${!listening[@]}" | awk NF | sort)
finding unexpected_listeners "Sockets listening beyond loopback on ports the configuration doesn't open, as proto:port process." listener "${unexpected_listeners[@]}"

# Changes to the NixOS firewall's rules since it was last set up. The rules
# as set up (after an activation or a firewall restart) are the baseline;
# a later change, such as an iptables -I by hand, is reported line by line
# ("+ added", "- removed"). Tailscale's ts-* chains change on their own and
# aren't compared, and neither are Docker's, which aren't in these chains.
firewall_rules() {
  local save table
  case "$1" in
  iptables)
    for save in iptables-save ip6tables-save; do
      for table in filter mangle; do
        { "$save" -t "$table" 2>/dev/null || true; } |
          awk -v t="${save%-save} $table" '/^-A (INPUT|PREROUTING|nixos-[^ ]+) / && !/ -j ts-/ { print t ": " $0 }'
      done
    done
    ;;
  nftables) nft -s list table inet nixos-fw ;;
  esac
}
firewall=$(jq -r '.firewall.kind // empty' "$SETTINGS")
if [ -n "$firewall" ]; then
  unit=$(jq -r '.firewall.unit' "$SETTINGS")
  set_up=$(($(systemctl show -p ActiveEnterTimestampMonotonic --value "$unit") / 1000000))
  uptime=$(cut -d. -f1 /proc/uptime)
  activated=$(stat -c %Y /run/current-system)
  # Leave a firewall or system that changed in the last 2 minutes alone:
  # this run may have started while it was being set up.
  if [ $((uptime - set_up)) -ge 120 ] && [ $((now - activated)) -ge 120 ]; then
    key="$current $(systemctl show -p InvocationID --value "$unit")"
    rules=$(firewall_rules "$firewall")
    if [ "$(cat "$STATE/firewall-key" 2>/dev/null)" != "$key" ]; then
      printf '%s\n' "$rules" >"$STATE/firewall-rules"
      printf '%s\n' "$key" >"$STATE/firewall-key"
    fi
    mapfile -t changed < <(printf '%s\n' "$rules" |
      diff --unchanged-line-format= --old-line-format='- %L' --new-line-format='+ %L' "$STATE/firewall-rules" - || true)
    finding firewall_rules "Firewall rules added (+) or removed (-) since the firewall was set up." rule "${changed[@]}"
  fi
fi

# comin keeps running with the configuration it started with: NixOS doesn't
# restart it on a switch (comin restarts itself only after its own
# deployments), so after a manual switch it runs older settings, including
# the old post-deployment command.
config_arg() {
  # Reads all its input, so the writer never gets SIGPIPE under pipefail.
  awk 'found { next } prev == "--config" { print; found = 1; next } { prev = $0 } sub(/^--config=/, "") { print; found = 1 }'
}
if [ "$(jq -r .comin "$SETTINGS")" = true ]; then
  pid=$(systemctl show -p MainPID --value comin.service)
  stale=0
  if [ "${pid:-0}" != 0 ] && [ -r "/proc/$pid/cmdline" ]; then
    running=$(tr '\0' '\n' <"/proc/$pid/cmdline" | config_arg)
    installed=$(systemctl show -p ExecStart --value comin.service | { grep -o 'argv\[\]=[^;]*' || true; } | tr ' ' '\n' | config_arg)
    [ "$running" = "$installed" ] || stale=1
  fi
  since_file=$STATE/comin-stale-since
  if [ "$stale" = 1 ]; then
    [ -s "$since_file" ] || echo "$now" >"$since_file"
  else
    rm -f "$since_file"
  fi
  {
    echo "# HELP nixhost_comin_config_stale Whether the running comin started with a different --config than the installed unit."
    echo "# TYPE nixhost_comin_config_stale gauge"
    echo "nixhost_comin_config_stale $stale"
    if [ -s "$since_file" ]; then
      echo "# HELP nixhost_comin_config_stale_since_timestamp_seconds Since when comin has run with an older --config."
      echo "# TYPE nixhost_comin_config_stale_since_timestamp_seconds gauge"
      echo "nixhost_comin_config_stale_since_timestamp_seconds $(cat "$since_file")"
    fi
  } >>"$out"
fi

# The system the last deployment recorded (deploy module's deployed.json)
# against the running system and the boot default. A health-check rollback,
# a manual switch or a manual boot change leaves them apart, while comin and
# deployed.json still report the deployment.
deployed_file=/var/lib/nixhost-deploy/deployed.json

want=""
[ ! -r "$deployed_file" ] || want=$(jq -r '.system // empty' "$deployed_file")
if [ -n "$want" ]; then
  want=$(readlink -f "$want" || echo "$want")
  boot=$(boot_default 2>/dev/null || true)
  ref=$(jq -r '.ref // empty' "$deployed_file")
  branch=$(jq -r '.deployBranch // empty' "$SETTINGS")
  # comin switches first and the deploy hook writes deployed.json after, so
  # an older deployed.json just after an activation is a deployment in
  # progress, not drift: leave the comparison to a later run.
  activated=$(stat -c %Y /run/current-system)
  settling=""
  if [ "$(stat -c %Y "$deployed_file")" -lt "$activated" ] && [ $((now - activated)) -lt 300 ]; then
    settling=1
  fi
  {
    if [ -z "$settling" ]; then
      echo "# HELP nixhost_deploy_running_matches_deployed Whether the running system is the one the last deployment recorded."
      echo "# TYPE nixhost_deploy_running_matches_deployed gauge"
      echo "nixhost_deploy_running_matches_deployed $([ "$current" = "$want" ] && echo 1 || echo 0)"
    fi
    # A testing-branch deployment is applied with test and leaves the boot default alone.
    if [ -z "$settling" ] && [ -n "$boot" ] && [ -n "$branch" ] && [[ $ref == */"$branch" ]]; then
      echo "# HELP nixhost_deploy_boot_matches_deployed Whether the boot default is the system the last deployment recorded."
      echo "# TYPE nixhost_deploy_boot_matches_deployed gauge"
      echo "nixhost_deploy_boot_matches_deployed $([ "$boot" = "$want" ] && echo 1 || echo 0)"
    fi
    echo "# HELP nixhost_deploy_system_info The deployed, running and boot systems (store path names) and the deployed commit."
    echo "# TYPE nixhost_deploy_system_info gauge"
    echo "nixhost_deploy_system_info{deployed=\"$(label "${want##*/}")\",running=\"$(label "${current##*/}")\",boot=\"$(label "${boot##*/}")\",sha=\"$(label "$(jq -r '.sha // empty' "$deployed_file")")\"} 1"
  } >>"$out"
fi

{
  echo "# HELP nixhost_drift_last_run_timestamp_seconds When the drift check last finished."
  echo "# TYPE nixhost_drift_last_run_timestamp_seconds gauge"
  echo "nixhost_drift_last_run_timestamp_seconds $now"
} >>"$out"
write_metrics nixhost_drift <"$out"
