# nixhost-health-check [deploy|boot]
#
# deploy (comin's hook): run the health checks (ethpandaops.checks of kind
# health: sshd, the default route, the firewall, DNS, the git remote and the
# fleet's own) at once, retrying each until it passes or its timeout runs
# out. If one still fails, try the last system that passed. Keep it only if
# the checks pass there and the deploy is the cause; if they fail there too,
# the deploy isn't the cause, so go back to the deployed system. Either way,
# tell the admins.
#
# Some checks (outside: DNS and the git remote) depend on things outside
# the box. When only they failed, a pass on the older system may just mean
# an outage ended, so the deployed system gets a second try before the
# rollback is kept.
#
# The rollback breaker (breaker.sh) limits that: a kept rollback trips it,
# and while it's open, or when the last good system's rollback guard differs
# from the deployed one's (which trips it too), the deployed system stays,
# the admins hear (critical) and a person decides. A deployed system that
# passes its checks closes it.
#
# boot (nixhost-boot-check, after a boot): the same checks, but it never
# switches systems. It exits 0 once they pass and 1 when one still fails at
# its timeout; what follows is up to the unit's OnSuccess= and OnFailure=.
# On a trial boot (nixhost.trial= on the kernel command line), the outside
# checks keep being retried until NIXHOST_OUTSIDE_CHECKS_UNTIL seconds of
# uptime, if that's later, so a short outage doesn't revert a good trial.
#
# Either way it then runs the readiness checks once and records every
# check's result in /run/nixhost/checks/status.json (write_status).
#
# Timeouts count uptime, so a clock step during the checks doesn't end them.
mode=${1:-deploy}
status=manual
sha=""
error=""
if [ "$mode" = deploy ] && [ -r "$RUN_DIR/deployment.json" ]; then
  status=$(jq -r .status "$RUN_DIR/deployment.json")
  sha=$(jq -r .sha "$RUN_DIR/deployment.json")
  error=$(jq -r .error "$RUN_DIR/deployment.json")
fi
current=$(readlink -f /run/current-system)
# What was deployed, for the rollback breaker: the commit, or the system.
deployed=${sha:0:12}
deployed=${deployed:-${current##*/}}
failures=""
local_failures=""

uptime_seconds() {
  cut -d. -f1 /proc/uptime
}

# wait_healthy: run the health checks (run_checks) until they pass, or until
# one that fails is past its deadline, in uptime: the start plus its
# timeout. On a trial boot, an outside check's deadline is
# NIXHOST_OUTSIDE_CHECKS_UNTIL if that's later.
wait_healthy() {
  local start now name timeout outside outside_until=0
  local -A deadline=()
  start=$(uptime_seconds)
  if [ "$mode" = boot ] && [[ " $(</proc/cmdline) " == *" nixhost.trial="* ]]; then
    outside_until=${NIXHOST_OUTSIDE_CHECKS_UNTIL:-0}
  fi
  while IFS=$'\t' read -r name timeout outside; do
    deadline[$name]=$((start + timeout))
    if [ "$outside" = true ] && [ "$outside_until" -gt "${deadline[$name]}" ]; then
      deadline[$name]=$outside_until
    fi
  done < <(jq -r '.checks[] | select(.kind == "health") | [.name, .timeout, .outside] | @tsv' "$CHECKS")
  until run_checks health; do
    now=$(uptime_seconds)
    for name in $failures; do
      if [ "$now" -ge "${deadline[$name]}" ]; then
        return 1
      fi
    done
    echo "checks failing:$failures; retrying"
    sleep 5
  done
}

# activate <system>: switch to it without touching the bootloader, so a
# bootloader problem can't stop a recovery.
activate() {
  "$1/bin/switch-to-configuration" test || echo "activating $1 returned an error"
}

# record_good: the running system passed; it's the one to roll back to next
# time. After a deploy, that closes the rollback breaker.
record_good() {
  echo "healthy; recording $current as the last good system"
  ln -sfn "$current" "$STATE_DIR/last-good"
  ln -sfn "$current" /nix/var/nix/gcroots/nixhost-last-good
  if [ "$mode" = deploy ] && breaker_open; then
    breaker_close "$deployed passed its health checks" "$current"
    notify_admins info "Rollback breaker closed" "The rollback breaker closed: $deployed passed its health checks, so automatic rollbacks are back on."
  fi
}

# keep_rollback: the last good system is active and passed; keep it, as the
# boot default too, and trip the rollback breaker.
keep_rollback() {
  local boot_note=""
  rollbacks=$((rollbacks + 1))
  echo "$rollbacks" >"$STATE_DIR/rollbacks_total"
  if ! { nix-env --profile /nix/var/nix/profiles/system --set "$last_good" &&
    "$last_good/bin/switch-to-configuration" boot; }; then
    boot_note=" It could not be made the boot default, so a reboot may start the broken system."
  fi
  breaker_trip "rolled back $deployed" "$current"
  notify_admins warning "Deploy rolled back" "Rolled back to $last_good; the checks pass again.$boot_note Fix the configuration before the next deploy. Until a deploy passes its health checks, or \`sudo nixhost-breaker reset\`, nothing rolls back by itself."
}

wait_healthy || true

now=$(date +%s)
rollbacks=$(cat "$STATE_DIR/rollbacks_total" 2>/dev/null || echo 0)
last_success=$(cat "$STATE_DIR/last_success" 2>/dev/null || echo 0)
ok=0
if [ -z "$failures" ]; then
  ok=1
  last_success=$now
  if [ "$status" = failed ]; then
    notify_admins warning "Deploy failed" "comin could not deploy ${sha:0:12}: $error. The box is healthy on $current."
  else
    record_good
  fi
elif [ "$mode" = boot ]; then
  echo "checks failed after boot:$failures"
else
  echo "checks failed:$failures"
  last_good=$(readlink "$STATE_DIR/last-good" || readlink -f /run/booted-system)
  if [ "$last_good" = "$current" ] || [ ! -x "$last_good/bin/switch-to-configuration" ]; then
    notify_admins critical "Health check failing" "Health check failing (${failures# }) after deploying ${sha:0:12}, and there is no earlier good system to roll back to."
  elif guarded=$(guard_differs "$current" "$last_good"); then
    echo "not rolling back: the rollback guard differs ($guarded)"
    breaker_trip "guard: $guarded" "$current"
    breaker_blocked
    notify_admins critical "Health check failed: not rolling back" "Health check failed (${failures# }) after deploying ${sha:0:12}; not rolling back, the deploy changed $guarded, which an automatic rollback can't cross. A person decides."
  elif breaker_open; then
    echo "not rolling back: the rollback breaker is open"
    breaker_blocked
    notify_admins critical "Health check failed: not rolling back" "Health check failed (${failures# }) after deploying ${sha:0:12}; not rolling back: the rollback breaker has been open since $(date -u -d "@$(breaker_get .since)" '+%F %T UTC') ($(breaker_get .reason)). Reset it with \`sudo nixhost-breaker reset\` once the host is looked at."
  else
    notify_admins warning "Health check failed: rolling back" "Health check failed (${failures# }) after deploying ${sha:0:12}; rolling back to $last_good."
    deployed_failures=$failures
    deployed_local=$local_failures
    activate "$last_good"
    if ! wait_healthy; then
      echo "checks fail on $last_good too:$failures; going back to $current"
      activate "$current"
      notify_admins critical "Health check failing, not the deploy" "Health check fails on ${sha:0:12} (${deployed_failures# }) and on the previous system (${failures# }), so the deploy isn't the cause; went back to ${sha:0:12}. Check the box and the health check."
    elif [ -n "$deployed_local" ]; then
      ok=1
      keep_rollback
    else
      echo "only checks that depend on the outside failed on $current; trying it again"
      activate "$current"
      if wait_healthy; then
        ok=1
        last_success=$now
        record_good
        notify_admins info "Health check recovered" "Health check failed (${deployed_failures# }) after deploying ${sha:0:12}, but passes on it again: something outside the box, not the deploy. Kept ${sha:0:12}."
      else
        echo "checks fail on $current again:$failures; back to $last_good"
        activate "$last_good"
        if wait_healthy; then
          ok=1
        fi
        keep_rollback
      fi
    fi
  fi
fi
echo "$last_success" >"$STATE_DIR/last_success"

# The health checks' last results, and the readiness checks once, for the
# status file.
if ! run_checks readiness; then
  echo "readiness checks failing:$failures"
fi
write_status "$mode" || echo "couldn't write $CHECKS_STATUS"
breaker_metrics

write_metrics nixhost_healthcheck <<METRICS
# HELP nixhost_healthcheck_ok Whether the box passed its last health check, after a deploy or a boot.
# TYPE nixhost_healthcheck_ok gauge
nixhost_healthcheck_ok $ok
# HELP nixhost_healthcheck_last_run_timestamp_seconds When the health check last ran.
# TYPE nixhost_healthcheck_last_run_timestamp_seconds gauge
nixhost_healthcheck_last_run_timestamp_seconds $now
# HELP nixhost_healthcheck_last_success_timestamp_seconds When the health check last passed.
# TYPE nixhost_healthcheck_last_success_timestamp_seconds gauge
nixhost_healthcheck_last_success_timestamp_seconds $last_success
# HELP nixhost_healthcheck_rollbacks_total Rollbacks done by the health check.
# TYPE nixhost_healthcheck_rollbacks_total counter
nixhost_healthcheck_rollbacks_total $rollbacks
METRICS

[ "$ok" = 1 ]
