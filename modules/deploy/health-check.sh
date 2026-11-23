# After a deployment: check sshd, routing, DNS and the git remote, retrying
# for healthCheck.timeout seconds. If they still fail, switch back to the last
# system that passed and tell the admins.
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

timeout_s=$(setting .healthCheck.timeout)
start=$(date +%s)
until run_checks; do
  if [ $(($(date +%s) - start)) -ge "$timeout_s" ]; then
    break
  fi
  echo "checks failing:$failures; retrying"
  sleep 5
done

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
    # Activate first (`test` leaves the bootloader alone, so a bootloader
    # problem can't stop the recovery), then make it the boot default.
    "$last_good/bin/switch-to-configuration" test || echo "activating $last_good returned an error"
    boot_note=""
    if ! { nix-env --profile /nix/var/nix/profiles/system --set "$last_good" &&
      "$last_good/bin/switch-to-configuration" boot; }; then
      boot_note=" It could not be made the boot default, so a reboot may start the broken system."
    fi
    rollbacks=$((rollbacks + 1))
    echo "$rollbacks" >"$STATE_DIR/rollbacks_total"
    if run_checks; then
      ok=1
      notify_admins "rolled back to $last_good; checks pass again.$boot_note Fix the configuration before the next deploy."
    else
      notify_admins "rolled back to $last_good, but checks still fail:$failures.$boot_note"
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
