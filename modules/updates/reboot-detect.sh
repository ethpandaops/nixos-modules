# Compare /run/booted-system with /run/current-system. COMPONENTS is set by
# the module.
RUN=/run/nixhost/reboot
mkdir -p "$RUN"
now=$(date +%s)

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
for component in "${COMPONENTS[@]}"; do
  booted=$(readlink -f "/run/booted-system/$component" || true)
  current=$(readlink -f "/run/current-system/$component" || true)
  # A file in the system itself, such as kernel-params, is in each system's
  # own store path, so compare what it says.
  if [ "$booted" != "$current" ] &&
    ! { [ -f "$booted" ] && [ -f "$current" ] && cmp -s "$booted" "$current"; }; then
    changed+=("$component")
  fi
done

if [ "${#changed[@]}" -gt 0 ]; then
  since=$now
  if [ -r "$RUN/required.json" ] && [ "$(jq -r .required "$RUN/required.json")" = true ]; then
    since=$(jq -r .since "$RUN/required.json")
  fi
  jq -n \
    --argjson since "$since" \
    --arg booted_kernel "$(kernel_version /run/booted-system)" \
    --arg new_kernel "$(kernel_version /run/current-system)" \
    --arg booted_systemd "$(store_name /run/booted-system/systemd)" \
    --arg new_systemd "$(store_name /run/current-system/systemd)" \
    '{required: true, $since, components: $ARGS.positional,
      kernel: {booted: $booted_kernel, new: $new_kernel},
      systemd: {booted: $booted_systemd, new: $new_systemd}}' \
    --args "${changed[@]}" >"$RUN/required.json.tmp"
  mv -f "$RUN/required.json.tmp" "$RUN/required.json"
  printf '%s\n' "${changed[@]}" >/run/reboot-required.components
  touch /run/reboot-required
  echo "reboot needed for: ${changed[*]} (since $(date -u -d "@$since"))"
else
  echo '{"required": false}' >"$RUN/required.json"
  rm -f /run/reboot-required /run/reboot-required.components
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
} | write_metrics nixhost_reboot_detect
