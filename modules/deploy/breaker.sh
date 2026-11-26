# The rollback breaker (ethpandaops.lib.breaker, breaker.nix). It opens when
# a rollback is kept, a trial reverts, or a rollback would cross the rollback
# guard; while it's open nothing rolls back or reverts by itself. It closes
# when a deployed system passes its health checks, a trial is confirmed, or
# an admin runs `nixhost-breaker reset`. BREAKER is {open, since, reason,
# system}. Needs write_metrics (ethpandaops.lib.shell), coreutils and jq.
BREAKER=/var/lib/nixhost-deploy/breaker.json
BREAKER_BLOCKED=/var/lib/nixhost-deploy/breaker_blocked_total

# breaker_get <jq path>: a field of the breaker's state, or nothing.
breaker_get() {
  jq -r "$1 // empty" "$BREAKER" 2>/dev/null || true
}

# breaker_open: succeeds while the breaker is open.
breaker_open() {
  [ "$(breaker_get .open)" = true ]
}

# breaker_set <true|false> <reason> [system]: the breaker's state; system
# defaults to the running one. Open stays open since it first opened.
breaker_set() {
  local since
  since=$(date +%s)
  if [ "$1" = true ] && breaker_open; then
    since=$(breaker_get .since)
  fi
  mkdir -p "${BREAKER%/*}"
  jq -n --argjson open "$1" --argjson since "$since" --arg reason "$2" \
    --arg system "${3:-$(readlink -f /run/current-system)}" \
    '{$open, $since, $reason, $system}' >"$BREAKER.tmp"
  mv -f "$BREAKER.tmp" "$BREAKER"
  sync -f "$BREAKER" || true
  breaker_metrics
}

# breaker_trip <reason> [system]: open the breaker.
breaker_trip() {
  echo "rollback breaker open: $1"
  breaker_set true "$@"
}

# breaker_close <reason> [system]: close the breaker.
breaker_close() {
  echo "rollback breaker closed: $1"
  breaker_set false "$@"
}

breaker_blocked_total() {
  local n
  n=$(cat "$BREAKER_BLOCKED" 2>/dev/null || true)
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "$n"
  else
    echo 0
  fi
}

# breaker_blocked: count a rollback or a revert the breaker refused.
breaker_blocked() {
  mkdir -p "${BREAKER_BLOCKED%/*}"
  echo $(($(breaker_blocked_total) + 1)) >"$BREAKER_BLOCKED"
  breaker_metrics
}

breaker_metrics() {
  local open=0
  if breaker_open; then
    open=1
  fi
  write_metrics nixhost_breaker <<METRICS
# HELP nixhost_rollback_breaker_open Whether the rollback breaker is open: no automatic rollback or trial revert until a deployed system passes, a trial is confirmed or an admin resets it.
# TYPE nixhost_rollback_breaker_open gauge
nixhost_rollback_breaker_open $open
# HELP nixhost_rollback_breaker_blocked_total Rollbacks and trial reverts the rollback breaker refused.
# TYPE nixhost_rollback_breaker_blocked_total counter
nixhost_rollback_breaker_blocked_total $(breaker_blocked_total)
METRICS
}

# guard_of <system>: its rollback guard (ethpandaops.rollback.guard), or {}.
guard_of() {
  jq -c . "$1/etc/nixhost/rollback-guard.json" 2>/dev/null || echo '{}'
}

# guard_differs <system> <system>: prints the guard keys whose values
# differ, comma-separated, and succeeds if there are any.
guard_differs() {
  local keys
  keys=$(jq -rn --argjson a "$(guard_of "$1")" --argjson b "$(guard_of "$2")" \
    '[$a + $b | keys[] | select($a[.] != $b[.])] | join(", ")')
  [ -n "$keys" ] || return 1
  echo "$keys"
}
