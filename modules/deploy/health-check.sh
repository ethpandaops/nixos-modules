# After a deployment: check sshd, routing, the firewall, DNS and the git
# remote, retrying for healthCheck.timeout seconds. If they still fail, try
# the last system that passed. Keep it only if the checks pass there and the
# deploy is the cause; if they fail there too, the deploy isn't the cause, so
# go back to the deployed system. Either way, tell the admins.
#
# DNS and the git remote also depend on things outside the box. When only
# they failed, a pass on the older system may just mean an outage ended, so
# the deployed system gets a second try before the rollback is kept.
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
local_failures=""

# firewall_on: whether the NixOS firewall's rules are in force. A reload that
# fails (say, a rule needs a kernel module that can't load any more) takes
# them out and leaves the box without a firewall.
firewall_on() {
  case "$(setting .healthCheck.firewall.kind)" in
  iptables)
    iptables -w -C INPUT -j nixos-fw 2>/dev/null &&
      { [ -z "$(setting .healthCheck.firewall.ipv6)" ] || ip6tables -w -C INPUT -j nixos-fw 2>/dev/null; }
    ;;
  nftables) nft list table inet nixos-fw >/dev/null 2>&1 ;;
  *) true ;;
  esac
}

run_checks() {
  failures=""
  local_failures=""
  local port dns extra
  port=$(setting .healthCheck.sshPort)
  if [ -z "$(ss -Hltn "sport = :$port")" ]; then
    local_failures+=" sshd-not-listening-on-$port"
  fi
  if [ -n "$(setting .healthCheck.checkDefaultRoute)" ] &&
    [ -z "$(ip -4 route show default)$(ip -6 route show default)" ]; then
    local_failures+=" no-default-route"
  fi
  if ! firewall_on; then
    local_failures+=" firewall-off"
  fi
  extra=$(setting .healthCheck.extraScript)
  if ! "$extra"; then
    local_failures+=" extra-script"
  fi
  failures=$local_failures
  dns=$(setting .healthCheck.dnsName)
  if [ -n "$dns" ] && ! timeout 10 getent ahosts "$dns" >/dev/null; then
    failures+=" dns-$dns"
  fi
  if [ -n "$(setting .healthCheck.checkRemote)" ] &&
    ! git_remote --exit-code "refs/heads/$(setting .branch)" >/dev/null; then
    failures+=" git-remote"
  fi
  [ -z "$failures" ]
}

# wait_healthy: retry the checks until they pass or the timeout runs out.
# Cached answers from before an activation (resolved's DNS cache, and its
# copy of /etc/hosts, reread at most every 2 s) could pass a system whose
# DNS is broken, so flush them and let it settle first.
wait_healthy() {
  local start
  resolvectl flush-caches 2>/dev/null || true
  sleep 3
  start=$(date +%s)
  until run_checks; do
    if [ $(($(date +%s) - start)) -ge "$(setting .healthCheck.timeout)" ]; then
      return 1
    fi
    echo "checks failing:$failures; retrying"
    sleep 5
  done
}

# activate <system>: switch to it without touching the bootloader, so a
# bootloader problem can't stop a recovery.
activate() {
  "$1/bin/switch-to-configuration" test || echo "activating $1 returned an error"
}

# record_good <system>: the system to roll back to next time.
record_good() {
  echo "healthy; recording $1 as the last good system"
  ln -sfn "$1" "$STATE_DIR/last-good"
  ln -sfn "$1" /nix/var/nix/gcroots/nixhost-last-good
}

# keep_rollback: the last good system is active and passed; keep it, as the
# boot default too.
keep_rollback() {
  local boot_note=""
  rollbacks=$((rollbacks + 1))
  echo "$rollbacks" >"$STATE_DIR/rollbacks_total"
  if ! { nix-env --profile /nix/var/nix/profiles/system --set "$last_good" &&
    "$last_good/bin/switch-to-configuration" boot; }; then
    boot_note=" It could not be made the boot default, so a reboot may start the broken system."
  fi
  notify_admins warning "Deploy rolled back" "Rolled back to $last_good; the checks pass again.$boot_note Fix the configuration before the next deploy."
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
    record_good "$current"
  fi
else
  echo "checks failed:$failures"
  last_good=$(readlink "$STATE_DIR/last-good" || readlink -f /run/booted-system)
  if [ "$last_good" = "$current" ] || [ ! -x "$last_good/bin/switch-to-configuration" ]; then
    notify_admins critical "Health check failing" "Health check failing (${failures# }) after deploying ${sha:0:12}, and there is no earlier good system to roll back to."
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
        record_good "$current"
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
