# After a deployment: check sshd, routing, DNS and the git remote, retrying
# for healthCheck.timeout seconds. If they still fail, try the last system
# that passed. Keep it only if the checks pass there; if they fail there too,
# the deploy isn't the cause, so go back to the deployed system. Either way,
# tell the admins.
status=manual
sha=""
error=""
if [ -r "$RUN_DIR/deployment.json" ]; then
  status=$(jq -r .status "$RUN_DIR/deployment.json")
  sha=$(jq -r .sha "$RUN_DIR/deployment.json")
  error=$(jq -r .error "$RUN_DIR/deployment.json")
fi
current=$(readlink -f /run/current-system)
failures=""

run_checks() {
  failures=""
  local port dns extra
  port=$(setting .healthCheck.sshPort)
  if [ -z "$(ss -Hltn "sport = :$port")" ]; then
    failures+=" sshd-not-listening-on-$port"
  fi
  if [ -n "$(setting .healthCheck.checkDefaultRoute)" ] &&
    [ -z "$(ip -4 route show default)$(ip -6 route show default)" ]; then
    failures+=" no-default-route"
  fi
  dns=$(setting .healthCheck.dnsName)
  if [ -n "$dns" ] && ! timeout 10 getent ahosts "$dns" >/dev/null; then
    failures+=" dns-$dns"
  fi
  if [ -n "$(setting .healthCheck.checkRemote)" ] &&
    ! git_remote --exit-code "refs/heads/$(setting .branch)" >/dev/null; then
    failures+=" git-remote"
  fi
  extra=$(setting .healthCheck.extraScript)
  if ! "$extra"; then
    failures+=" extra-script"
  fi
  [ -z "$failures" ]
}

# wait_healthy: retry the checks until they pass or the timeout runs out.
wait_healthy() {
  local start
  start=$(date +%s)
  until run_checks; do
    if [ $(($(date +%s) - start)) -ge "$(setting .healthCheck.timeout)" ]; then
      return 1
    fi
    echo "checks failing:$failures; retrying"
    sleep 5
  done
}

wait_healthy || true

now=$(date +%s)
rollbacks=$(cat "$STATE_DIR/rollbacks_total" 2>/dev/null || echo 0)
last_success=$(cat "$STATE_DIR/last_success" 2>/dev/null || echo 0)
ok=0
if [ -z "$failures" ]; then
  ok=1
  last_success=$now
  echo "$now" >"$STATE_DIR/last_success"
  if [ "$status" = failed ]; then
    notify_admins "comin could not deploy ${sha:0:12}: $error. The box is healthy on $current."
  else
    echo "healthy; recording $current as the last good system"
    ln -sfn "$current" "$STATE_DIR/last-good"
    ln -sfn "$current" /nix/var/nix/gcroots/nixhost-last-good
  fi
else
  echo "checks failed:$failures"
  last_good=$(readlink "$STATE_DIR/last-good" || readlink -f /run/booted-system)
  if [ "$last_good" = "$current" ] || [ ! -x "$last_good/bin/switch-to-configuration" ]; then
    notify_admins "health check failing ($failures) after deploying ${sha:0:12}, and there is no earlier good system to roll back to."
  else
    notify_admins "health check failed ($failures) after deploying ${sha:0:12}; rolling back to $last_good."
    deployed_failures=$failures
    # `test` activates without touching the bootloader, so a bootloader
    # problem can't stop the recovery; the boot default changes only once the
    # older system has passed.
    "$last_good/bin/switch-to-configuration" test || echo "activating $last_good returned an error"
    if wait_healthy; then
      ok=1
      rollbacks=$((rollbacks + 1))
      echo "$rollbacks" >"$STATE_DIR/rollbacks_total"
      boot_note=""
      if ! { nix-env --profile /nix/var/nix/profiles/system --set "$last_good" &&
        "$last_good/bin/switch-to-configuration" boot; }; then
        boot_note=" It could not be made the boot default, so a reboot may start the broken system."
      fi
      notify_admins "rolled back to $last_good; checks pass again.$boot_note Fix the configuration before the next deploy."
    else
      echo "checks fail on $last_good too:$failures; going back to $current"
      "$current/bin/switch-to-configuration" test || echo "activating $current returned an error"
      notify_admins "health check fails on ${sha:0:12} ($deployed_failures) and on the previous system ($failures), so the deploy isn't the cause; went back to ${sha:0:12}. Check the box and the health check."
    fi
  fi
fi

write_metrics nixhost_healthcheck <<METRICS
# HELP nixhost_healthcheck_ok Whether the box passed its last post-deploy health check.
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
