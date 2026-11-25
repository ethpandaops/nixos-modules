# Compare /run/booted-system with the deployed system: /run/current-system,
# or the bootloader's default when it is a system that is neither running
# nor booted (deployed with `boot`). COMPONENTS is set by the module.
RUN=/run/nixhost/reboot
mkdir -p "$RUN"
now=$(date +%s)

target=/run/current-system
boot_pending=""
boot=$(boot_default 2>/dev/null || true)
if [ -n "$boot" ] && [ -d "$boot" ] &&
  [ "$boot" != "$(readlink -f /run/current-system)" ] && [ "$boot" != "$(readlink -f /run/booted-system)" ]; then
  target=$boot
  boot_pending=1
fi

# kernel_version <system>: from kernel-modules/lib/modules/<version>.
kernel_version() {
  local dir
  for dir in "$1"/kernel-modules/lib/modules/*; do
    basename "$dir"
    return
  done
  echo unknown
}

# store_name <path>: /nix/store/<hash>-systemd-260.5 -> systemd-260.5
store_name() {
  local name
  name=$(basename "$(readlink -f "$1")")
  echo "${name#*-}"
}

changed=()
[ -z "$boot_pending" ] || changed+=(boot-default)
for component in "${COMPONENTS[@]}"; do
  booted=$(readlink -f "/run/booted-system/$component" || true)
  current=$(readlink -f "$target/$component" || true)
  # A file in the system itself, such as kernel-params, is in each system's
  # own store path, so compare what it says.
  if [ "$booted" != "$current" ] &&
    ! { [ -f "$booted" ] && [ -f "$current" ] && cmp -s "$booted" "$current"; }; then
    changed+=("$component")
  fi
done

# A system whose trial boot failed isn't tried again (reboot-trial.nix):
# keep the reboot pending, but hold it.
held=""
if [ "${#changed[@]}" -gt 0 ] && [ -n "$TRIAL_FILE" ] && [ -r "$TRIAL_FILE" ] &&
  [ "$(jq -r .system "$TRIAL_FILE")" = "$(readlink -f "$target")" ] &&
  ! jq -e '.outcome == "pending" or .outcome == "confirmed"' "$TRIAL_FILE" >/dev/null; then
  held=trial-reverted
fi

if [ "${#changed[@]}" -gt 0 ]; then
  since=$now
  if [ -r "$RUN/required.json" ] && [ "$(jq -r .required "$RUN/required.json")" = true ]; then
    since=$(jq -r .since "$RUN/required.json")
  fi
  jq -n \
    --argjson since "$since" \
    --arg booted_kernel "$(kernel_version /run/booted-system)" \
    --arg new_kernel "$(kernel_version "$target")" \
    --arg booted_systemd "$(store_name /run/booted-system/systemd)" \
    --arg new_systemd "$(store_name "$target/systemd")" \
    --arg held "$held" \
    '{required: true, $since, components: $ARGS.positional,
      kernel: {booted: $booted_kernel, new: $new_kernel},
      systemd: {booted: $booted_systemd, new: $new_systemd},
      held: (if $held == "" then null else $held end)}' \
    --args "${changed[@]}" >"$RUN/required.json.tmp"
  mv -f "$RUN/required.json.tmp" "$RUN/required.json"
  if [ -z "$held" ]; then
    printf '%s\n' "${changed[@]}" >/run/reboot-required.components
    touch /run/reboot-required "$RUN/reboot-required"
    echo "reboot needed for: ${changed[*]} (since $(date -u -d "@$since"))"
  else
    rm -f /run/reboot-required /run/reboot-required.components "$RUN/reboot-required"
    echo "reboot needed for: ${changed[*]} (since $(date -u -d "@$since")), held: $held"
  fi
else
  echo '{"required": false}' >"$RUN/required.json"
  rm -f /run/reboot-required /run/reboot-required.components "$RUN/reboot-required"
  echo "no reboot needed"
fi

{
  echo "# HELP nixhost_reboot_pending Whether a reboot is needed to run the deployed system."
  echo "# TYPE nixhost_reboot_pending gauge"
  echo "nixhost_reboot_pending $([ "${#changed[@]}" -gt 0 ] && echo 1 || echo 0)"
  if [ "${#changed[@]}" -gt 0 ]; then
    echo "# HELP nixhost_reboot_pending_since_timestamp_seconds Since when a reboot has been needed."
    echo "# TYPE nixhost_reboot_pending_since_timestamp_seconds gauge"
    echo "nixhost_reboot_pending_since_timestamp_seconds $since"
    echo "# HELP nixhost_reboot_pending_component A changed component that needs the reboot."
    echo "# TYPE nixhost_reboot_pending_component gauge"
    for component in "${changed[@]}"; do
      echo "nixhost_reboot_pending_component{component=\"$component\"} 1"
    done
  fi
  if [ -n "$held" ]; then
    echo "# HELP nixhost_reboot_pending_held Why the pending reboot is held: trial-reverted, the deployed system's trial boot failed."
    echo "# TYPE nixhost_reboot_pending_held gauge"
    echo "nixhost_reboot_pending_held{reason=\"$held\"} 1"
  fi
} | write_metrics nixhost_reboot_detect
