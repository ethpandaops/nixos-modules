# nixhost-node-report: this host's NixOS state as annotations on its own
# Node, written as the kubelet (KUBECONFIG_FILE, NODE). See node-report.nix.
PREFIX=nixos.ethpandaops.io/
LAST=/run/nixhost/node-report.last
CHECKS_STATUS=/run/nixhost/checks/status.json
BOOT_STATUS=/run/nixhost/boot/status.json
REBOOT=/run/nixhost/reboot/required.json
BREAKER=/var/lib/nixhost-deploy/breaker.json

if [ ! -r "$KUBECONFIG_FILE" ]; then
  echo "no kubeconfig at $KUBECONFIG_FILE yet"
  exit 0
fi

# revision <system>: its configuration revision, or unknown.
revision() {
  "$1/sw/bin/nixos-version" --configuration-revision 2>/dev/null || echo unknown
}

# field <file> <jq filter> <default>: from a JSON file, or the default if it
# can't be read.
field() {
  jq -r "$2" "$1" 2>/dev/null || echo "$3"
}

# metric <name> <textfile>: a metric's value, or 0.
metric() {
  local value
  value=$(awk -v m="$1" '$1 == m { print $2; exit }' "$METRICS_DIR/$2.prom" 2>/dev/null || true)
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo 0
  fi
}

boot_id=$(</proc/sys/kernel/random/boot_id)
# comin switches with its own profile, so the bootloader's default entry is
# what boots, not /nix/var/nix/profiles/system.
boot=$(boot_default 2>/dev/null || true)
trial=none
check=none
if [ "$(field "$BOOT_STATUS" .bootId "")" = "$boot_id" ]; then
  trial=$(field "$BOOT_STATUS" '.trial // "none"' none)
  check=$(field "$BOOT_STATUS" '.check // "none"' none)
fi

annotations=(
  "${PREFIX}revision=$(revision /run/current-system)"
  "${PREFIX}boot-revision=$(revision "${boot:-/run/current-system}")"
  "${PREFIX}reboot-required=$(field "$REBOOT" 'if .required == true then "true" else "false" end' false)"
  "${PREFIX}reboot-held=$(field "$REBOOT" '.held // ""' "")"
  "${PREFIX}health=$(field "$CHECKS_STATUS" '.health // "unknown"' unknown)"
  "${PREFIX}readiness=$(field "$CHECKS_STATUS" '.readiness // "unknown"' unknown)"
  "${PREFIX}readiness-failing=$(field "$CHECKS_STATUS" '[.checks // {} | to_entries[] | select(.value.kind == "readiness" and .value.ok != true) | .key] | join(",")' "")"
  "${PREFIX}rollbacks=$(($(metric nixhost_healthcheck_rollbacks_total nixhost_healthcheck) + $(metric nixhost_boot_reverts_total nixhost_boot)))"
  "${PREFIX}rollback-breaker=$(field "$BREAKER" 'if .open == true then "open" else "closed" end' closed)"
  "${PREFIX}boot-id=$boot_id"
  "${PREFIX}kernel=$(uname -r)"
  "${PREFIX}trial=$trial"
  "${PREFIX}boot-check=$check"
)

# Write when something changed, and every 10 minutes so reported-at shows
# the host is alive.
now=$(date +%s)
values=$(printf '%s\n' "${annotations[@]}")
if [ -r "$LAST" ] && [ "$(tail -n +2 "$LAST")" = "$values" ] &&
  [ $((now - $(head -n1 "$LAST"))) -lt 600 ]; then
  exit 0
fi

kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=10s --cache-dir=/run/nixhost/kubectl-cache \
  annotate node "$NODE" --overwrite "${annotations[@]}" \
  "${PREFIX}reported-at=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
mkdir -p "${LAST%/*}"
printf '%s\n%s\n' "$now" "$values" >"$LAST"
echo "reported: ${annotations[*]#"$PREFIX"}"
