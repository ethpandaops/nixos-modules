# The named checks (ethpandaops.checks): run_checks runs them, write_status
# records their results. CHECKS (from the module) lists the enabled ones:
# name, kind, outside, timeout and command. Needs write_metrics
# (ethpandaops.lib.shell), and coreutils, gawk, jq and util-linux.
CHECKS_STATUS=/run/nixhost/checks/status.json
# The last result of each check run here, by name: {name, ok, message}.
declare -A check_result=()

# run_checks <kind>...: run every enabled check of these kinds at once, each
# cut off after 60 s, and fail if any fails. Sets failures to the names of
# those that failed, each after a space, and local_failures to those of them
# that don't depend on anything outside the box. A check's message is the
# first line of its output.
# shellcheck disable=SC2034 # failures and local_failures are for the caller
run_checks() {
  local dir i rc ok message name kind outside command
  local -a names=() outsides=() pids=()
  failures=""
  local_failures=""
  dir=$(mktemp -d)
  while IFS=$'\t' read -r name kind outside command; do
    if [[ " $* " != *" $kind "* ]]; then
      continue
    fi
    timeout --kill-after=5 60 "$command" </dev/null >"$dir/$name" 2>&1 &
    pids+=("$!")
    names+=("$name")
    outsides+=("$outside")
  done < <(jq -r '.checks[] | [.name, .kind, .outside, .command] | @tsv' "$CHECKS")
  for i in "${!names[@]}"; do
    name=${names[$i]}
    rc=0
    wait "${pids[$i]}" || rc=$?
    ok=false
    if [ "$rc" = 0 ]; then
      ok=true
    fi
    message=$(head -n1 "$dir/$name")
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      message="timed out after 60 s"
    elif [ -z "$message" ] && [ "$ok" = true ]; then
      message=passed
    elif [ -z "$message" ]; then
      message="failed (exit $rc)"
    fi
    check_result[$name]=$(jq -cn --arg name "$name" --argjson ok "$ok" --arg message "${message:0:500}" '{$name, $ok, $message}')
    if [ "$ok" = false ]; then
      failures+=" $name"
      if [ "${outsides[$i]}" != true ]; then
        local_failures+=" $name"
      fi
    fi
  done
  rm -rf "$dir"
  [ -z "$failures" ]
}

# write_status <deploy|boot|periodic>: CHECKS_STATUS from the results
# run_checks got, each check's since carried over from the last status while
# its result stays the same, and nixhost_checks.prom. Under a lock, as the
# deploy, boot and periodic runs may overlap.
write_status() {
  local phase=$1 now system revision since deployed_at prev deployment=/run/nixhost-deploy/deployment.json
  now=$(date +%s)
  system=$(readlink -f /run/current-system)
  revision=$("$system/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || revision=unknown
  # Since the boot, or since the running system was deployed.
  since=$(awk '$1 == "btime" { print $2 }' /proc/stat)
  if [ -r "$deployment" ] && [ "$(jq -r .system "$deployment" 2>/dev/null)" = "$system" ]; then
    deployed_at=$(jq -r '.at // 0' "$deployment")
    if [ "$deployed_at" -gt "$since" ]; then
      since=$deployed_at
    fi
  fi
  mkdir -p "${CHECKS_STATUS%/*}"
  {
    flock 9
    prev=$(jq -c . "$CHECKS_STATUS" 2>/dev/null) || prev='{}'
    printf '%s\n' "${check_result[@]}" | jq -s \
      --slurpfile config "$CHECKS" \
      --argjson prev "$prev" \
      --arg phase "$phase" \
      --argjson now "$now" \
      --arg system "$system" \
      --arg revision "${revision:-unknown}" \
      --argjson since "$since" '
      $config[0].checks as $configured
      | (map({key: .name, value: .}) | from_entries) as $results
      | ($prev.checks // {}) as $old
      | ([$configured[] | select($results[.name] != null)
          | . as $c | $results[$c.name] as $r | $old[$c.name] as $o
          | {key: $c.name, value: {
              kind: $c.kind,
              outside: $c.outside,
              ok: $r.ok,
              since: (if $o != null and $o.ok == $r.ok then ($o.since // $now) else $now end),
              message: $r.message,
              timeout: $c.timeout}}]
        | from_entries) as $checks
      | [$configured[] | select(.kind == "readiness")] as $readiness
      | {revision: $revision, system: $system, phase: $phase, updatedAt: $now, since: $since,
         checks: $checks,
         health: (if all($configured[] | select(.kind == "health"); $checks[.name].ok == true) then "ok" else "failed" end),
         readiness: (
           if all($readiness[]; $checks[.name].ok == true) then "ok"
           elif any($readiness[]; $checks[.name].ok == false and $now >= $since + .timeout) then "failed"
           else "pending" end)}
    ' >"$CHECKS_STATUS.tmp" || return 1
    mv -f "$CHECKS_STATUS.tmp" "$CHECKS_STATUS" || return 1
    jq -r '
      "# HELP nixhost_check_ok Whether each named check (ethpandaops.checks) passed when it last ran.",
      "# TYPE nixhost_check_ok gauge",
      (.checks | to_entries[] | "nixhost_check_ok{check=\"\(.key)\",kind=\"\(.value.kind)\"} \(if .value.ok then 1 else 0 end)"),
      "# HELP nixhost_checks_health_ok Whether every health check passed when they last ran.",
      "# TYPE nixhost_checks_health_ok gauge",
      "nixhost_checks_health_ok \(if .health == "ok" then 1 else 0 end)",
      "# HELP nixhost_checks_readiness The readiness verdict: ok, every readiness check passes; failed, one fails past its timeout after the boot or the deploy; pending, neither yet.",
      "# TYPE nixhost_checks_readiness gauge",
      (.readiness as $verdict | ("ok", "pending", "failed") | "nixhost_checks_readiness{verdict=\"\(.)\"} \(if . == $verdict then 1 else 0 end)")
    ' "$CHECKS_STATUS" | write_metrics nixhost_checks
  } 9>"${CHECKS_STATUS%/*}/status.lock"
}
