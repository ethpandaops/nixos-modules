# nixhost-boot <start|stop|confirm|revert|deadline|retry|status>, for
# ethpandaops.reboot.trial. SETTINGS comes from the module.
#
# GRUB boots the last confirmed system by default, from nixhost/boot.cfg next
# to grub.cfg. Shutting down arms a trial of the deployed system (the
# bootloader's NixOS default) when it isn't the confirmed one and hasn't had
# a trial yet: boot.cfg gets an entry for it, and nixhost/env the flag GRUB
# clears on disk before it boots the trial, so the trial boots once. Its
# kernel command line carries nixhost.trial=<system>.
#
#   start     at boot: settle how the last trial ended, and keep GRUB's
#             default the confirmed system
#   stop      at shutdown (ExecStop): arm a trial of the deployed system
#   confirm   nixhost-boot-check passed: the booted system is confirmed
#   revert    nixhost-boot-check failed: a trial reboots into the confirmed one
#   deadline  a trial that hasn't passed by the deadline reboots the same way
#   retry     (admins) try a system whose trial failed once more
#   status
#
# A trial that hangs is reset by the hardware watchdog or the initrd's
# deadline, and the next boot (start) finds it never confirmed. Either way,
# the system isn't tried again until the deployed system changes or an
# admin runs retry; until then reboot-detect holds the reboot.
STATE=/var/lib/nixhost-boot
TRIAL=$STATE/trial.json
mapfile -t GRUB_DIRS < <(jq -r '.grubDirs[]' "$SETTINGS")

booted=$(readlink -f /run/booted-system)
now=$(date +%s)

setting() {
  jq -r "$1 // empty" "$SETTINGS"
}

readnum() {
  local value
  value=$(cat "$1" 2>/dev/null || true)
  [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo 0
}

# reboot_now: reboot through logind, so delay inhibitors, such as the
# kubelet's graceful node shutdown, get PrepareForShutdown and their time. A
# block inhibitor makes logind ask polkit even for root, and without polkit
# it refuses; a revert can't wait, so then start reboot.target directly,
# which nothing stops.
reboot_now() {
  echo "rebooting into the confirmed system"
  if ! systemctl reboot --check-inhibitors=no; then
    echo "logind refused the reboot; starting reboot.target directly"
    systemctl start --no-block --job-mode=replace-irreversibly reboot.target
  fi
}

notify_admins() {
  local severity=$1 title=$2
  shift 2
  "$NOTIFY" --severity "$severity" --title "$title" admins "$*" || true
}

# trial <jq path>: a field of the last trial's record, or nothing.
trial() {
  if [ -r "$TRIAL" ]; then
    jq -r "$1 // empty" "$TRIAL"
  fi
}

confirmed() {
  readlink -f "$STATE/confirmed" 2>/dev/null || true
}

set_confirmed() {
  mkdir -p /nix/var/nix/gcroots
  ln -sfn "$1" "$STATE/confirmed"
  ln -sfn "$1" /nix/var/nix/gcroots/nixhost-confirmed
  echo "$now" >"$STATE/confirmed_at"
}

# trial_boot: whether GRUB booted this system as a trial, from the flag its
# entry puts on the kernel command line.
trial_boot() {
  [[ " $(</proc/cmdline) " == *" nixhost.trial=${booted##*/} "* ]]
}

# pending_trial: this boot is a trial that hasn't been confirmed or failed.
pending_trial() {
  trial_boot && [ "$(trial .system)" = "$booted" ] && [ "$(trial .outcome)" = pending ]
}

# resolve <outcome> <detail>: how the last trial ended. Every outcome but
# confirmed is a revert.
resolve() {
  jq --arg outcome "$1" --arg detail "$2" --argjson at "$now" \
    '.outcome = $outcome | .detail = $detail | .resolvedAt = $at' "$TRIAL" >"$TRIAL.tmp"
  mv -f "$TRIAL.tmp" "$TRIAL"
  if [ "$1" != confirmed ]; then
    echo $(($(readnum "$STATE/reverts_total") + 1)) >"$STATE/reverts_total"
  fi
  echo "trial of $(trial .system): $1 ($2)"
}

# file_name <store path>: its name in nixhost/kernels, the way install-grub
# names files in /boot/kernels.
file_name() {
  local path=${1#/nix/store/}
  echo "${path//\//-}"
}

# load <system> <grub dir> [kernel parameters]: copy the system's kernel,
# initrd and initrd secrets into <grub dir>/nixhost/kernels, and print the
# two GRUB commands that load them.
load() {
  local system=$1 kernels=$2/nixhost/kernels extra=${3:-} file target secrets initrds
  for file in "$(readlink -f "$system/kernel")" "$(readlink -f "$system/initrd")"; do
    target=$kernels/$(file_name "$file")
    if [ ! -e "$target" ]; then
      cp "$file" "$target.tmp"
      mv -f "$target.tmp" "$target"
    fi
  done
  initrds="\"\$nixhost_dir/kernels/$(file_name "$(readlink -f "$system/initrd")")\""
  # Secrets for the initrd (boot.initrd.secrets), built the way install-grub
  # builds them.
  if [ -x "$system/append-initrd-secrets" ]; then
    secrets=${system##*/}-secrets
    rm -f "$kernels/$secrets.tmp"
    "$system/append-initrd-secrets" "$kernels/$secrets.tmp"
    if [ -s "$kernels/$secrets.tmp" ]; then
      mv -f "$kernels/$secrets.tmp" "$kernels/$secrets"
      initrds+=" \"\$nixhost_dir/kernels/$secrets\""
    else
      rm -f "$kernels/$secrets.tmp"
    fi
  fi
  echo "linux \"\$nixhost_dir/kernels/$(file_name "$(readlink -f "$system/kernel")")\" init=$system/init $(<"$system/kernel-params")${extra:+ $extra}"
  echo "initrd $initrds"
}

# write_boot_cfg [trial system]: boot.cfg in each GRUB directory, with the
# confirmed system as the default and, if given, an entry for the trial.
write_boot_cfg() {
  local trial_system=${1:-} confirmed dir cfg out file
  local -a c t
  confirmed=$(confirmed)
  for dir in "${GRUB_DIRS[@]}"; do
    mkdir -p "$dir/nixhost/kernels"
    cfg=$dir/nixhost/boot.cfg
    out=$(load "$confirmed" "$dir")
    mapfile -t c <<<"$out"
    {
      echo "# Written by nixhost-boot (ethpandaops.reboot.trial); grub.cfg sources it."
      echo "menuentry \"NixOS - confirmed: ${confirmed##*/}\" --id nixhost-confirmed {"
      echo "  ${c[0]}"
      echo "  ${c[1]}"
      echo "}"
      echo "set default=nixhost-confirmed"
      # Should the confirmed system not load: the bootloader's own default.
      echo "set fallback=0"
      if [ -n "$trial_system" ]; then
        out=$(load "$trial_system" "$dir" "nixhost.trial=${trial_system##*/} $(setting .trialParams)")
        mapfile -t t <<<"$out"
        cat <<EOF
set nixhost_trial_system=${trial_system##*/}
menuentry "NixOS - trial: ${trial_system##*/}" --id nixhost-trial {
  set nixhost_loaded=
  if ${t[0]}; then
    if ${t[1]}; then
      set nixhost_loaded=1
    fi
  fi
  if [ -z "\$nixhost_loaded" ]; then
    echo "nixhost: the trial system doesn't load; booting the last confirmed one"
    ${c[0]}
    ${c[1]}
  fi
}
EOF
      fi
    } >"$cfg.tmp"
    mv -f "$cfg.tmp" "$cfg"
    # Drop kernels and initrds no entry loads any more.
    for file in "$dir"/nixhost/kernels/*; do
      if [ -e "$file" ] && ! grep -qF "/kernels/${file##*/}\"" "$cfg"; then
        rm -f "$file"
      fi
    done
  done
}

# env_get: the trial flag as GRUB finds it.
env_get() {
  local env=${GRUB_DIRS[0]}/nixhost/env
  if [ -r "$env" ]; then
    grub-editenv "$env" list | sed -n 's/^nixhost_trial=//p'
  fi
}

# env_set [system name]: set the trial flag, or clear it.
env_set() {
  local dir env
  for dir in "${GRUB_DIRS[@]}"; do
    env=$dir/nixhost/env
    mkdir -p "$dir/nixhost"
    [ -s "$env" ] || grub-editenv "$env" create
    if [ -n "${1:-}" ]; then
      grub-editenv "$env" set "nixhost_trial=$1"
    else
      grub-editenv "$env" unset nixhost_trial
    fi
  done
}

metrics() {
  local in_trial=0 ready=0
  if pending_trial; then
    in_trial=1
  fi
  if [ -d "$(confirmed)" ] && grep -q -- '--id nixhost-confirmed' "${GRUB_DIRS[0]}/nixhost/boot.cfg" 2>/dev/null; then
    ready=1
  fi
  write_metrics nixhost_boot <<METRICS
# HELP nixhost_boot_trial Whether this boot is a trial of a new system that hasn't passed its boot check yet.
# TYPE nixhost_boot_trial gauge
nixhost_boot_trial $in_trial
# HELP nixhost_boot_reverts_total Trial boots that went back to the last confirmed system: hung, failed the boot check, missed the deadline or never booted.
# TYPE nixhost_boot_reverts_total counter
nixhost_boot_reverts_total $(readnum "$STATE/reverts_total")
# HELP nixhost_boot_confirmed_timestamp_seconds When the system GRUB boots by default last passed its boot check.
# TYPE nixhost_boot_confirmed_timestamp_seconds gauge
nixhost_boot_confirmed_timestamp_seconds $(readnum "$STATE/confirmed_at")
# HELP nixhost_boot_fallback_ready Whether GRUB has a confirmed system to fall back to.
# TYPE nixhost_boot_fallback_ready gauge
nixhost_boot_fallback_ready $ready
METRICS
}

# report: tell the admins once how a failed trial ended. It runs after the
# boot check, when the network is up.
report() {
  case "$(trial .outcome)" in
  "" | pending | confirmed) return ;;
  esac
  [ "$(trial .reported)" != true ] || return 0
  local system confirmed
  system=$(trial .system)
  confirmed=$(confirmed)
  notify_admins warning "Trial boot reverted" "The trial boot of ${system##*/} ended $(trial .outcome): $(trial .detail). The box is back on ${confirmed##*/}. Reboots for that system are held: deploy a fix, or run \`sudo nixhost-boot retry\` to try it once more at the next reboot."
  jq '.reported = true' "$TRIAL" >"$TRIAL.tmp"
  mv -f "$TRIAL.tmp" "$TRIAL"
}

start() {
  local confirmed system
  mkdir -p "$STATE"
  confirmed=$(confirmed)
  if [ ! -d "$confirmed" ]; then
    echo "no confirmed system yet: the booted one, $booted, is the fallback"
    set_confirmed "$booted"
  fi
  system=$(trial .system)
  if [ "$(trial .outcome)" = pending ] && ! pending_trial; then
    if [ "$(env_get)" = "${system##*/}" ]; then
      resolve not-tried "GRUB couldn't clear its trial flag, so it booted the confirmed system instead"
    else
      resolve hung "it never passed its boot check: the watchdog or the boot deadline reset it, or it lost power"
    fi
  fi
  write_boot_cfg
  # On a trial boot GRUB has cleared the flag itself.
  if ! trial_boot; then
    env_set ""
  fi
  metrics
  systemctl start --no-block nixhost-reboot-detect.service || true
}

stop() {
  local target confirmed
  # Only a shutdown arms a trial, not a stop by hand or by a switch.
  if [ "$(systemctl is-system-running 2>/dev/null || true)" != stopping ]; then
    echo "not shutting down: no trial to arm"
    return
  fi
  if pending_trial; then
    resolve unconfirmed "it was shut down before it passed its boot check"
    return
  fi
  target=$(boot_default 2>/dev/null || true)
  confirmed=$(confirmed)
  if [ -z "$target" ] || [ ! -d "$target" ]; then
    echo "can't read the bootloader's default: the next boot is the confirmed system"
    return
  fi
  if [ "$target" = "$confirmed" ] || [ ! -d "$confirmed" ]; then
    return
  fi
  if [ "$(trial .system)" = "$target" ]; then
    echo "$target has had its trial ($(trial .outcome)): the next boot is the confirmed system"
    return
  fi
  # The entry first: if it can't be written (a full ESP), nothing is armed.
  write_boot_cfg "$target"
  jq -n --arg system "$target" --arg confirmed "$confirmed" --argjson at "$now" \
    '{$system, $confirmed, outcome: "pending", armedAt: $at}' >"$TRIAL.tmp"
  mv -f "$TRIAL.tmp" "$TRIAL"
  sync
  env_set "${target##*/}"
  sync
  echo "armed a trial boot of $target; it falls back to $confirmed"
}

confirm() {
  if pending_trial; then
    resolve confirmed "it passed its boot check"
    set_confirmed "$booted"
    write_boot_cfg
    notify_admins ok "Trial boot confirmed" "${booted##*/} booted and passed its boot check, on kernel $(uname -r), so GRUB boots it by default now."
  elif [ "$booted" != "$(confirmed)" ]; then
    echo "$booted passed its boot check outside a trial: it's the confirmed system now"
    set_confirmed "$booted"
    write_boot_cfg
  else
    echo "$now" >"$STATE/confirmed_at"
  fi
  report
  metrics
  systemctl start --no-block nixhost-reboot-detect.service || true
}

revert() {
  local failed
  if pending_trial; then
    failed=$(journalctl -b -u nixhost-boot-check.service -o cat | sed -n 's/^checks failed after boot: *//p' | tail -n1 || true)
    resolve failed-check "its boot check failed${failed:+ ($failed)}"
    metrics
    reboot_now
  else
    report
    notify_admins warning "Health check failing after boot" "nixhost-boot-check fails on ${booted##*/}. It isn't a trial boot, so the box stays up: see journalctl -u nixhost-boot-check."
  fi
}

deadline() {
  if pending_trial; then
    resolve deadline "its boot check hadn't passed $(setting .deadline) s after boot"
    metrics
    reboot_now
  fi
}

retry() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run it as root: sudo nixhost-boot retry" >&2
    exit 1
  fi
  case "$(trial .outcome)" in
  "" | pending | confirmed)
    echo "No failed trial to retry."
    return
    ;;
  esac
  echo "The next reboot tries $(trial .system) again."
  rm -f "$TRIAL"
  systemctl start nixhost-reboot-detect.service || true
}

status() {
  echo "Booted:    $booted$(trial_boot && echo " (trial boot)")"
  echo "Confirmed: $(confirmed)"
  echo "Deployed:  $(boot_default 2>/dev/null || echo unknown)"
  if [ -r "$TRIAL" ]; then
    echo "Last trial: $(trial .system): $(trial .outcome) ($(trial .detail))"
  fi
}

case "${1:-}" in
status) status ;;
start | stop | confirm | revert | deadline | retry)
  exec 9>/run/nixhost-boot.lock
  flock 9
  "$1"
  ;;
*)
  echo "usage: nixhost-boot <start|stop|confirm|revert|deadline|retry|status>" >&2
  exit 2
  ;;
esac
