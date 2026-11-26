# nixhost-boot <start|stop|confirm|revert|deadline|switched|retry|status>,
# for ethpandaops.reboot.trial. SETTINGS comes from the module.
#
# GRUB boots the last confirmed system by default, from nixhost/boot.cfg next
# to grub.cfg. Shutting down arms a trial of the deployed system (the
# bootloader's NixOS default) when it isn't the confirmed one and hasn't had
# a trial yet: boot.cfg gets an entry for it, and nixhost/env the flag GRUB
# clears on disk before it boots the trial, so the trial boots once. The
# trial's kernel command line carries nixhost.trial=<system>, the confirmed
# entry's nixhost.confirmed=<system>.
#
#   start     at boot: settle how the last trial ended, and keep GRUB's
#             default the confirmed system
#   stop      at shutdown (ExecStop): arm a trial of the deployed system
#   confirm   nixhost-boot-check passed: a trial becomes the confirmed system
#   revert    nixhost-boot-check failed: a trial reboots into the confirmed one
#   deadline  a trial that hasn't passed by the deadline reboots the same way
#   switched  the deploy health check passed: a live switch that a reboot
#             wouldn't change becomes the confirmed system
#   retry     (admins) try the deployed system at the next reboot
#   status
#
# How a trial ended (trial.json's outcome): confirmed; failed-check,
# deadline or hung, the reverts nixhost_boot_reverts_total counts;
# unconfirmed, shut down before its check passed; not-armed, the shutdown
# couldn't set it up, or the preArm hook refused it; skipped, the preArm
# hook, or a rollback guard that differs, had the system boot without a
# trial, as the confirmed one; held, it would have reverted but the
# rollback breaker is open, so it stays up; unsupported, GRUB couldn't clear
# its flag, so trials stop on this box; bypassed, GRUB booted it from its
# own menu entry. After unconfirmed, not-armed, held or a revert, the system
# isn't tried again until another is deployed or an admin runs retry, and
# reboot-detect holds its reboot.
STATE=/var/lib/nixhost-boot
TRIAL=$STATE/trial.json
RUN=/run/nixhost/boot
mapfile -t GRUB_DIRS < <(jq -r '.grubDirs[]' "$SETTINGS")
mapfile -t COMPONENTS < <(jq -r '.components[]' "$SETTINGS")

booted=$(readlink -f /run/booted-system)
cmdline=" $(</proc/cmdline) "
boot_id=$(</proc/sys/kernel/random/boot_id)
now=$(date +%s)
unsupported_reason=""

setting() {
  jq -r "$1 // empty" "$SETTINGS"
}

readnum() {
  local value
  value=$(cat "$1" 2>/dev/null || true)
  [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo 0
}

notify_admins() {
  local severity=$1 title=$2
  shift 2
  "$NOTIFY" --severity "$severity" --title "$title" admins "$*" || true
}

# remember <name> <value>: true the first time a value is seen, so each
# notice goes out once.
remember() {
  if [ "$(cat "$STATE/notified-$1" 2>/dev/null || true)" = "$2" ]; then
    return 1
  fi
  echo "$2" >"$STATE/notified-$1"
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
  mkdir -p "$STATE" /nix/var/nix/gcroots
  ln -sfn "$1" "$STATE/confirmed.tmp"
  mv -Tf "$STATE/confirmed.tmp" "$STATE/confirmed"
  ln -sfn "$1" /nix/var/nix/gcroots/nixhost-confirmed
  echo "$now" >"$STATE/confirmed_at"
  sync -f "$STATE"
}

# record <system> <outcome> <detail>: a new trial.
record() {
  jq -n --arg system "$1" --arg confirmed "$(confirmed)" --arg outcome "$2" --arg detail "$3" --argjson at "$now" \
    '{$system, $confirmed, $outcome, $detail, armedAt: $at}' >"$TRIAL.tmp"
  mv -f "$TRIAL.tmp" "$TRIAL"
  sync -f "$STATE"
}

# resolve <outcome> <detail>: how the last trial ended. Only failed-check,
# deadline and hung count as reverts, and trip the rollback breaker; a
# confirmed trial closes it.
resolve() {
  local system
  jq --arg outcome "$1" --arg detail "$2" --argjson at "$now" \
    '.outcome = $outcome | .detail = $detail | .resolvedAt = $at | del(.reported)' "$TRIAL" >"$TRIAL.tmp"
  mv -f "$TRIAL.tmp" "$TRIAL"
  system=$(trial .system)
  case "$1" in
  failed-check | deadline | hung)
    echo $(($(readnum "$STATE/reverts_total") + 1)) >"$STATE/reverts_total"
    breaker_trip "trial of ${system##*/} reverted" "$system"
    ;;
  confirmed)
    if breaker_open; then
      breaker_close "trial of ${system##*/} confirmed" "$system"
      notify_admins info "Rollback breaker closed" "The rollback breaker closed: the trial boot of ${system##*/} passed its boot check, so automatic rollbacks and trial reverts are back on."
    fi
    ;;
  esac
  sync -f "$STATE"
  echo "trial of $system: $1 ($2)"
}

# hold <what happened>: a pending trial that would revert while the rollback
# breaker is open stays up on the trial system instead, for a person.
hold() {
  local since reason
  since=$(date -u -d "@$(breaker_get .since)" '+%F %T UTC')
  reason=$(breaker_get .reason)
  resolve held "$1, but the rollback breaker is open ($reason)"
  status_set trial '"held"'
  breaker_blocked
  metrics
  notify_admins critical "Trial boot held" "The trial boot of ${booted##*/} would revert ($1), but the rollback breaker has been open since $since ($reason), so the box stays up on it. A person decides: deploy a fix, or reboot to go back to $(basename "$(confirmed)"), after which ${booted##*/} isn't tried again until \`sudo nixhost-boot retry\`. \`sudo nixhost-breaker reset\` turns automatic reverts back on."
}

# trial_boot: whether GRUB booted this system as a trial, from the flag its
# entry puts on the kernel command line.
trial_boot() {
  [[ $cmdline == *" nixhost.trial=${booted##*/} "* ]]
}

# confirmed_entry_boot: whether GRUB booted this system from boot.cfg's
# confirmed entry.
confirmed_entry_boot() {
  [[ $cmdline == *" nixhost.confirmed=${booted##*/} "* ]]
}

# pending_trial: this boot is a trial that hasn't been confirmed or failed.
pending_trial() {
  trial_boot && [ "$(trial .system)" = "$booted" ] && [ "$(trial .outcome)" = pending ]
}

# held_outcome <outcome>: whether a trial that ended so holds its system's
# reboot until another system is deployed or an admin runs retry.
held_outcome() {
  case "$1" in
  failed-check | deadline | hung | unconfirmed | not-armed | held) return 0 ;;
  *) return 1 ;;
  esac
}

# check_supported: whether GRUB can clear the trial flag on disk in every
# GRUB directory: on a plain partition, or on md RAID1 with the superblock at
# the end (metadata 0.90 or 1.0), whose members each hold the filesystem at
# their start. With the superblock at the start (1.1 or 1.2, which Hetzner's
# installimage uses for /boot) or on device-mapper it can't, and every trial
# would end not booted. Sets unsupported_reason.
check_supported() {
  local dir source fstype name level meta
  if [ -s "$STATE/unsupported" ]; then
    unsupported_reason=$(<"$STATE/unsupported")
    return 1
  fi
  for dir in "${GRUB_DIRS[@]}"; do
    if ! read -r source fstype < <(findmnt -n -o SOURCE,FSTYPE --target "$dir"); then
      unsupported_reason="can't find the filesystem $dir is on"
      return 1
    fi
    case "$fstype" in
    vfat | ext2 | ext3 | ext4) ;;
    *)
      unsupported_reason="$dir is on $fstype, where GRUB can't write its environment block"
      return 1
      ;;
    esac
    name=$(basename "$(readlink -f "$source")")
    if [ -d "/sys/class/block/$name/md" ]; then
      level=$(<"/sys/class/block/$name/md/level")
      meta=$(<"/sys/class/block/$name/md/metadata_version")
      if [ "$level" != raid1 ] || { [ "$meta" != 1.0 ] && [ "$meta" != 0.90 ]; }; then
        unsupported_reason="$dir is on md $level with metadata $meta: GRUB can't write through md, and the members don't hold the filesystem at their start"
        return 1
      fi
    elif [ -d "/sys/class/block/$name/dm" ]; then
      unsupported_reason="$dir is on device-mapper ($name), which GRUB can't write"
      return 1
    fi
  done
}

# file_name <store path>: its name in nixhost/kernels, the way install-grub
# names files in /boot/kernels.
file_name() {
  local path=${1#/nix/store/}
  echo "${path//\//-}"
}

# copy <file> <dir>: put a kernel or initrd into <dir> whole, or fail. A copy
# already there is reused only at the source's size.
copy() {
  local source=$1 target size
  target=$2/$(file_name "$1")
  size=$(stat -c %s "$source") || return 1
  if [ -f "$target" ] && [ "$(stat -c %s "$target")" = "$size" ]; then
    return 0
  fi
  rm -f "$target.tmp"
  if cp "$source" "$target.tmp" && [ "$(stat -c %s "$target.tmp")" = "$size" ] &&
    sync "$target.tmp" && mv -f "$target.tmp" "$target"; then
    return 0
  fi
  rm -f "$target.tmp"
  echo "couldn't copy ${source##*/} to $2" >&2
  return 1
}

# load <system> <grub dir> <kernel parameters>: copy the system's kernel,
# initrd and initrd secrets next to boot.cfg, and set LINUX and INITRD to
# the GRUB commands that load them.
load() {
  local system=$1 kernels=$2/nixhost/kernels kernel initrd secrets
  kernel=$(readlink -f "$system/kernel") && initrd=$(readlink -f "$system/initrd") || return 1
  copy "$kernel" "$kernels" && copy "$initrd" "$kernels" || return 1
  INITRD="initrd \"\$nixhost_dir/kernels/$(file_name "$initrd")\""
  # Secrets for the initrd (boot.initrd.secrets), built the way install-grub
  # builds them.
  if [ -x "$system/append-initrd-secrets" ]; then
    secrets=${system##*/}-secrets
    rm -f "$kernels/$secrets.tmp"
    if ! "$system/append-initrd-secrets" "$kernels/$secrets.tmp" ||
      { [ -e "$kernels/$secrets.tmp" ] && ! sync "$kernels/$secrets.tmp"; }; then
      rm -f "$kernels/$secrets.tmp"
      echo "couldn't write the initrd secrets of ${system##*/}" >&2
      return 1
    fi
    if [ -s "$kernels/$secrets.tmp" ]; then
      mv -f "$kernels/$secrets.tmp" "$kernels/$secrets" || return 1
      INITRD+=" \"\$nixhost_dir/kernels/$secrets\""
    else
      rm -f "$kernels/$secrets.tmp"
    fi
  fi
  LINUX="linux \"\$nixhost_dir/kernels/$(file_name "$kernel")\" init=$system/init $(<"$system/kernel-params") $3"
}

# write_boot_cfg <confirmed system> [trial system]: boot.cfg in each GRUB
# directory, written whole and synced, with the confirmed system as GRUB's
# default and, if given, an entry for the trial. Fails, leaving the old
# boot.cfg, if anything it loads couldn't be written whole.
write_boot_cfg() {
  local confirmed=$1 trial_system=${2:-} dir cfg content c_linux c_initrd file
  for dir in "${GRUB_DIRS[@]}"; do
    mkdir -p "$dir/nixhost/kernels" || return 1
    load "$confirmed" "$dir" "panic=60 nixhost.confirmed=${confirmed##*/}" || return 1
    c_linux=$LINUX c_initrd=$INITRD
    content="# Written by nixhost-boot (ethpandaops.reboot.trial); grub.cfg sources it.
menuentry \"NixOS - confirmed: ${confirmed##*/}\" --id nixhost-confirmed {
  $c_linux
  $c_initrd
}
set default=nixhost-confirmed
# Should the confirmed system not load: the bootloader's own default.
set fallback=0
"
    if [ -n "$trial_system" ]; then
      load "$trial_system" "$dir" "nixhost.trial=${trial_system##*/} $(setting .trialParams)" || return 1
      content+="set nixhost_trial_system=${trial_system##*/}
menuentry \"NixOS - trial: ${trial_system##*/}\" --id nixhost-trial {
  set nixhost_loaded=
  if $LINUX; then
    if $INITRD; then
      set nixhost_loaded=1
    fi
  fi
  if [ -z \"\$nixhost_loaded\" ]; then
    echo \"nixhost: the trial system doesn't load; booting the last confirmed one\"
    $c_linux
    $c_initrd
  fi
}
"
    fi
    cfg=$dir/nixhost/boot.cfg
    if ! { printf '%s' "$content" >"$cfg.tmp" && cmp -s "$cfg.tmp" <(printf '%s' "$content") &&
      sync "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg" && sync -f "$cfg"; }; then
      rm -f "$cfg.tmp"
      echo "couldn't write $cfg" >&2
      return 1
    fi
  done
  # Drop kernels and initrds no entry loads any more.
  for dir in "${GRUB_DIRS[@]}"; do
    for file in "$dir"/nixhost/kernels/*; do
      if [ -e "$file" ] && ! grep -qF "/kernels/${file##*/}\"" "$dir/nixhost/boot.cfg"; then
        rm -f "$file"
      fi
    done
  done
}

# remove_boot_cfg: leave GRUB to boot its own default, as without trials.
remove_boot_cfg() {
  local dir
  for dir in "${GRUB_DIRS[@]}"; do
    rm -rf "$dir/nixhost/boot.cfg" "$dir/nixhost/kernels"
    sync -f "$dir" || true
  done
}

# env_repair: a valid GRUB environment block in each GRUB directory, made
# afresh when it's missing or grub-editenv can't read it.
env_repair() {
  local dir env
  for dir in "${GRUB_DIRS[@]}"; do
    env=$dir/nixhost/env
    if ! grub-editenv "$env" list >/dev/null 2>&1; then
      echo "creating the GRUB environment block $env"
      mkdir -p "$dir/nixhost" && rm -f "$env" && grub-editenv "$env" create || return 1
    fi
  done
}

# env_get: the trial flag as GRUB finds it.
env_get() {
  grub-editenv "${GRUB_DIRS[0]}/nixhost/env" list 2>/dev/null | sed -n 's/^nixhost_trial=//p' || true
}

# env_set [system name]: set the trial flag, or clear it. Through md this
# writes every member, so the copies GRUB wrote one by one agree again.
env_set() {
  local dir env
  env_repair || return 1
  for dir in "${GRUB_DIRS[@]}"; do
    env=$dir/nixhost/env
    if [ -n "${1:-}" ]; then
      grub-editenv "$env" set "nixhost_trial=$1" || return 1
    else
      grub-editenv "$env" unset nixhost_trial || return 1
    fi
    sync -f "$env" || return 1
  done
}

# boot_differences <system> <system>: what a reboot from one to the other
# would change (reboot-detect's components, and fstab).
boot_differences() {
  local component a b
  for component in "${COMPONENTS[@]}" etc/fstab; do
    if [ ! -e "$1/$component" ] && [ ! -e "$2/$component" ]; then
      continue
    fi
    a=$(readlink -f "$1/$component" || true)
    b=$(readlink -f "$2/$component" || true)
    if [ "$a" != "$b" ] && ! { [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"; }; then
      printf '%s ' "$component"
    fi
  done
}

watchdog_present() {
  [ -r /sys/class/watchdog/watchdog0/identity ]
}

# check_passed: whether this boot's nixhost-boot-check has finished and
# passed (it runs once per boot).
check_passed() {
  [ "$(systemctl show -p ExecMainExitTimestampMonotonic --value nixhost-boot-check.service)" != 0 ] &&
    [ "$(systemctl show -p ExecMainStatus --value nixhost-boot-check.service)" = 0 ] &&
    [ "$(systemctl show -p Result --value nixhost-boot-check.service)" = success ]
}

# restore_panic_sysctls: the trial's softlockup_panic and hardlockup_panic
# stay on for this boot's uptime; a confirmed system gets its own values.
restore_panic_sysctls() {
  local key value
  while read -r key value; do
    if [ -w "/proc/sys/kernel/$key" ]; then
      echo "${value:-0}" >"/proc/sys/kernel/$key"
    fi
  done < <(jq -r '.panicSysctls | to_entries[] | "\(.key) \(.value)"' "$SETTINGS")
}

# status_set <key> <value>: this boot's status in RUN/status.json: bootId,
# system, confirmed, supported, trial (none, pending, confirmed, reverted
# or held) and check (pending, ok or failed).
status_set() {
  local file=$RUN/status.json
  mkdir -p "$RUN"
  if [ ! -r "$file" ] || [ "$(jq -r .bootId "$file")" != "$boot_id" ]; then
    jq -n --arg bootId "$boot_id" --arg system "$booted" \
      '{$bootId, $system, confirmed: null, supported: null, trial: "none", check: "pending"}' >"$file.tmp"
    mv -f "$file.tmp" "$file"
  fi
  jq --arg key "$1" --argjson value "$2" --arg confirmed "$(confirmed)" --argjson at "$now" \
    '.[$key] = $value | .confirmed = $confirmed | .updatedAt = $at' "$file" >"$file.tmp"
  mv -f "$file.tmp" "$file"
}

metrics() {
  local in_trial=0 ready=0 supported=0 watchdog=0 status=$RUN/status.json trial_state=none check=pending
  if pending_trial; then
    in_trial=1
  fi
  if check_supported; then
    supported=1
    if [ -d "$(confirmed)" ] && grep -q -- '--id nixhost-confirmed' "${GRUB_DIRS[0]}/nixhost/boot.cfg" 2>/dev/null; then
      ready=1
    fi
  fi
  if watchdog_present; then
    watchdog=1
  fi
  if [ -r "$status" ]; then
    trial_state=$(jq -r .trial "$status")
    check=$(jq -r .check "$status")
  fi
  write_metrics nixhost_boot <<METRICS
# HELP nixhost_boot_status This boot: its ID, its trial (none, pending, confirmed, reverted or held) and its boot check (pending, ok or failed).
# TYPE nixhost_boot_status gauge
nixhost_boot_status{boot_id="$boot_id",trial="$trial_state",check="$check"} 1
# HELP nixhost_boot_trial Whether this boot is a trial of a new system that hasn't passed its boot check yet.
# TYPE nixhost_boot_trial gauge
nixhost_boot_trial $in_trial
# HELP nixhost_boot_reverts_total Trial boots that went back to the last confirmed system: failed the boot check, missed the deadline or hung.
# TYPE nixhost_boot_reverts_total counter
nixhost_boot_reverts_total $(readnum "$STATE/reverts_total")
# HELP nixhost_boot_confirmed_timestamp_seconds When the system GRUB boots by default last passed a boot or deploy check.
# TYPE nixhost_boot_confirmed_timestamp_seconds gauge
nixhost_boot_confirmed_timestamp_seconds $(readnum "$STATE/confirmed_at")
# HELP nixhost_boot_trial_supported Whether GRUB can clear the trial flag on this box's /boot, so trials run.
# TYPE nixhost_boot_trial_supported gauge
nixhost_boot_trial_supported $supported
# HELP nixhost_boot_fallback_ready Whether GRUB boots a confirmed system by default.
# TYPE nixhost_boot_fallback_ready gauge
nixhost_boot_fallback_ready $ready
# HELP nixhost_boot_watchdog_present Whether the box has a hardware watchdog for a hung trial.
# TYPE nixhost_boot_watchdog_present gauge
nixhost_boot_watchdog_present $watchdog
METRICS
}

# report: tell the admins, once each, what needs them. It runs after the
# boot check, when the network is up.
report() {
  local system outcome confirmed stale
  system=$(trial .system)
  outcome=$(trial .outcome)
  confirmed=$(confirmed)
  if [ -n "$outcome" ] && [ "$(trial .reported)" != true ]; then
    case "$outcome" in
    failed-check | deadline | hung | unconfirmed)
      notify_admins warning "Trial boot reverted" "The trial boot of ${system##*/} ended $outcome: $(trial .detail). The box is back on ${confirmed##*/}. Reboots for that system are held: deploy a fix, or run \`sudo nixhost-boot retry\` to try it once more at the next reboot."
      ;;
    not-armed)
      notify_admins warning "Trial boot not armed" "A shutdown couldn't set up the trial boot of ${system##*/}: $(trial .detail). The box stayed on ${confirmed##*/}, and its reboot is held: fix the cause (journalctl -u nixhost-boot), then run \`sudo nixhost-boot retry\`."
      ;;
    skipped)
      notify_admins info "Booted without a trial" "${system##*/} booted without a trial ($(trial .detail)), as the confirmed system: a reboot doesn't go back to $(basename "$(trial .confirmed)")."
      ;;
    bypassed)
      notify_admins info "Booted outside a trial" "GRUB booted ${system##*/} from its own menu entry, not as a trial: $(trial .detail). Its boot check decides whether it becomes the confirmed system."
      ;;
    esac
    if [ "$outcome" != pending ] && [ "$outcome" != confirmed ]; then
      jq '.reported = true' "$TRIAL" >"$TRIAL.tmp"
      mv -f "$TRIAL.tmp" "$TRIAL"
    fi
  fi
  if ! check_supported && remember unsupported "$unsupported_reason"; then
    notify_admins warning "Trial boots are off" "Trial boots can't work on this box: $unsupported_reason. GRUB boots the deployed system directly, as without ethpandaops.reboot.trial."
  fi
  if ! watchdog_present && remember no-watchdog 1; then
    notify_admins warning "No hardware watchdog" "There's no hardware watchdog (/sys/class/watchdog/watchdog0), so a trial whose kernel hangs without panicking isn't reset. Trials still run; panics and the boot deadlines still revert them."
  fi
  stale=$(cat "$RUN/stale" 2>/dev/null || true)
  if [ -n "$stale" ] && remember stale "$stale"; then
    notify_admins warning "Booted the confirmed system" "The box booted ${confirmed##*/}, the last confirmed system, though ${stale##*/} is deployed and no trial of it was armed: an unclean shutdown, a reset or a power loss? The pending reboot tries it."
  fi
}

start() {
  local system deployed trial_state=none
  mkdir -p "$STATE" "$RUN"
  rm -f "$RUN/stale"
  if [ ! -d "$(confirmed)" ]; then
    echo "no confirmed system yet: the booted one, $booted, is the fallback"
    set_confirmed "$booted"
  fi
  system=$(trial .system)
  # A confirm interrupted between its record and the confirmed link: the
  # trial passed.
  if [ "$(trial .outcome)" = confirmed ] && [ -d "$system" ] && [ "$system" != "$(confirmed)" ]; then
    echo "finishing the interrupted confirm of $system"
    set_confirmed "$system"
  fi
  # A skipped trial interrupted between its record and the confirmed link
  # (stop makes it GRUB's default first).
  if [ "$(trial .outcome)" = skipped ] && [ -d "$system" ] && [ "$system" != "$(confirmed)" ] &&
    [ "$(readnum "$STATE/confirmed_at")" -lt "$(trial .armedAt)" ]; then
    echo "finishing the interrupted skip of $system's trial"
    set_confirmed "$system"
  fi
  # GRUB booted a trial whose arming the shutdown didn't finish recording.
  if trial_boot && [ "$system" = "$booted" ] && [ "$(trial .outcome)" = not-armed ]; then
    jq '.outcome = "pending" | .detail = ""' "$TRIAL" >"$TRIAL.tmp"
    mv -f "$TRIAL.tmp" "$TRIAL"
  fi
  if [ "$(trial .outcome)" = pending ] && ! pending_trial; then
    if [ "$booted" = "$system" ] && confirmed_entry_boot; then
      # Its confirm moved GRUB's default and was cut off before the record.
      resolve confirmed "it passed its boot check"
      set_confirmed "$booted"
    elif [ "$booted" = "$system" ]; then
      resolve bypassed "boot.cfg was missing or unreadable, or someone chose the entry"
    elif [ "$(env_get)" = "${system##*/}" ]; then
      resolve unsupported "GRUB couldn't clear the trial flag on disk, so it booted the confirmed system"
      echo "GRUB couldn't clear the trial flag on disk at the trial of ${system##*/}" >"$STATE/unsupported"
    else
      resolve hung "it never passed its boot check: the watchdog or a boot deadline reset it, or it lost power"
    fi
  fi
  # This boot's status starts here; a restart later in the boot keeps it.
  if [ "$(jq -r .bootId "$RUN/status.json" 2>/dev/null || true)" != "$boot_id" ]; then
    if pending_trial; then
      trial_state=pending
    fi
    status_set trial "\"$trial_state\""
  fi

  if check_supported; then
    status_set supported true
    write_boot_cfg "$(confirmed)"
    env_set ""
    # Booted the confirmed system while another is deployed that no trial
    # was armed for: the shutdown before wasn't an orderly one.
    deployed=$(boot_default 2>/dev/null || true)
    if [ "$(systemctl is-system-running 2>/dev/null || true)" = starting ] && ! trial_boot &&
      [ "$booted" = "$(confirmed)" ] && [ -d "$deployed" ] && [ "$deployed" != "$booted" ] &&
      [ "$(trial .system)" != "$deployed" ]; then
      echo "$deployed" >"$RUN/stale"
    fi
  else
    status_set supported false
    echo "trial boots are off: $unsupported_reason"
    remove_boot_cfg
    env_set "" || true
  fi
  metrics
  systemctl start --no-block nixhost-reboot-detect.service || true
}

# arm <system>: boot.cfg with its trial entry, then the flag GRUB clears.
arm() {
  write_boot_cfg "$(confirmed)" "$1" && env_set "${1##*/}"
}

# pre_arm <system> <confirmed>: the preArm hook, if any, for at most 120 s.
# Its exit status: 0 arms the trial, 10 boots the system without one, and
# anything else arms nothing.
pre_arm() {
  local hook
  hook=$(setting .preArm)
  if [ -z "$hook" ]; then
    return 0
  fi
  echo "running the pre-arm hook for $1"
  timeout --kill-after=10 120 "$hook" "$1" "$2"
}

stop() {
  local target confirmed err hook skip guarded
  # Only a shutdown arms a trial, not a stop by hand or by a switch.
  if [ "$(systemctl is-system-running 2>/dev/null || true)" != stopping ]; then
    echo "not shutting down: no trial to arm"
    return
  fi
  if pending_trial; then
    resolve unconfirmed "it was shut down before it passed its boot check"
    return
  fi
  if ! check_supported; then
    echo "trial boots are off ($unsupported_reason): GRUB boots the deployed system"
    return
  fi
  target=$(boot_default 2>/dev/null || true)
  confirmed=$(confirmed)
  if [ -z "$target" ] || [ ! -d "$target" ]; then
    echo "can't read the bootloader's default: the next boot is the confirmed system"
    return
  fi
  if [ "$target" = "$confirmed" ]; then
    return
  fi
  if [ "$(trial .system)" = "$target" ] && held_outcome "$(trial .outcome)"; then
    echo "$target has had its trial ($(trial .outcome)): the next boot is the confirmed system"
    return
  fi
  # Recorded as not armed until it is, so an arming that fails or is cut off
  # holds the reboot instead of rebooting into the confirmed system again.
  record "$target" not-armed "the shutdown was cut off while arming it"
  hook=0
  pre_arm "$target" "$confirmed" || hook=$?
  case $hook in
  0 | 10) err="" ;;
  124 | 137) err="the pre-arm hook timed out after 120 s" ;;
  *) err="the pre-arm hook exited $hook" ;;
  esac
  # The hook's 10, or a rollback guard that differs, boots it without a
  # trial, as the confirmed system: GRUB's default first, so a reset after
  # this boots it too.
  skip=""
  if [ -z "$err" ]; then
    if [ "$hook" = 10 ]; then
      skip="the pre-arm hook skipped its trial"
    fi
    if guarded=$(guard_differs "$target" "$confirmed"); then
      skip="${skip:+$skip; }the rollback guard differs: $guarded"
    fi
  fi
  if [ -n "$skip" ]; then
    if err=$(write_boot_cfg "$target" 2>&1); then
      record "$target" skipped "$skip"
      set_confirmed "$target"
      echo "booting $target without a trial ($skip): it's the confirmed system now"
      return
    fi
    err="couldn't make it GRUB's default without a trial: $(tail -n1 <<<"$err")"
  fi
  if [ -n "$err" ] || ! err=$(arm "$target" 2>&1); then
    err=$(tail -n1 <<<"$err")
    echo "couldn't arm a trial boot of $target: $err"
    record "$target" not-armed "${err:-arming it failed}"
    write_boot_cfg "$confirmed" || true
    env_set "" || true
    return
  fi
  jq '.outcome = "pending" | .detail = ""' "$TRIAL" >"$TRIAL.tmp"
  mv -f "$TRIAL.tmp" "$TRIAL"
  sync -f "$STATE"
  echo "armed a trial boot of $target; it falls back to $confirmed"
}

confirm() {
  local current
  current=$(readlink -f /run/current-system)
  status_set check '"ok"'
  if trial_boot && [ "$(trial .system)" = "$booted" ]; then
    # A trial held at the deadline whose check passes later is confirmed.
    if [ "$(trial .outcome)" != pending ] && [ "$(trial .outcome)" != held ]; then
      echo "this boot's trial already ended ($(trial .outcome)): not confirming it"
    elif [ "$current" != "$booted" ]; then
      echo "not confirming: the running system, $current, isn't the trial"
      notify_admins warning "Trial boot not confirmed" "${booted##*/} passed its boot check, but the box was switched to ${current##*/} during the trial, so the trial isn't confirmed. The next shutdown ends it."
    else
      # GRUB's default first, so a reset after this boots the system the
      # record is about to confirm.
      write_boot_cfg "$booted"
      set_confirmed "$booted"
      resolve confirmed "it passed its boot check"
      restore_panic_sysctls
      status_set trial '"confirmed"'
      notify_admins ok "Trial boot confirmed" "${booted##*/} booted and passed its boot check, on kernel $(uname -r), so GRUB boots it by default now."
    fi
  elif [ "$booted" != "$(confirmed)" ] && ! trial_boot; then
    echo "$booted passed its boot check outside a trial: it's the confirmed system now"
    if check_supported; then
      write_boot_cfg "$booted"
    fi
    set_confirmed "$booted"
  else
    echo "$now" >"$STATE/confirmed_at"
  fi
  report
  metrics
  systemctl start --no-block nixhost-reboot-detect.service || true
}

revert() {
  local failed
  status_set check '"failed"'
  if pending_trial; then
    failed=$(journalctl -b -u nixhost-boot-check.service -o cat | sed -n 's/^checks failed after boot: *//p' | tail -n1 || true)
    if breaker_open; then
      hold "its boot check failed${failed:+ ($failed)}"
      return
    fi
    resolve failed-check "its boot check failed${failed:+ ($failed)}"
    status_set trial '"reverted"'
    metrics
    reboot_now
  else
    report
    notify_admins warning "Health check failing after boot" "nixhost-boot-check fails on ${booted##*/}. It isn't a trial boot, so the box stays up: see journalctl -u nixhost-boot-check."
    metrics
  fi
}

deadline() {
  if ! pending_trial; then
    return
  fi
  if check_passed; then
    echo "the boot check passed: nixhost-boot-confirm confirms the trial"
    return
  fi
  if breaker_open; then
    hold "its boot check hadn't passed $(setting .deadline) s after boot"
    return
  fi
  resolve deadline "its boot check hadn't passed $(setting .deadline) s after boot"
  status_set trial '"reverted"'
  metrics
  reboot_now
}

switched() {
  local current deployed differs
  current=$(readlink -f /run/current-system)
  if pending_trial || [ "$current" = "$(confirmed)" ] || ! check_supported; then
    return
  fi
  deployed=$(boot_default 2>/dev/null || true)
  if [ "$current" != "$deployed" ]; then
    echo "$current isn't GRUB's default (a test deploy?): not confirming it"
    return
  fi
  differs=$(boot_differences "$booted" "$current")
  if [ -n "$differs" ]; then
    echo "$current needs a reboot (${differs% }): its trial confirms it"
    return
  fi
  write_boot_cfg "$current"
  set_confirmed "$current"
  echo "$current passed the deploy health check and boots as it runs: it's the confirmed system"
  metrics
  systemctl start --no-block nixhost-reboot-detect.service || true
}

retry() {
  local deployed confirmed
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run it as root: sudo nixhost-boot retry" >&2
    exit 1
  fi
  if [ -e "$STATE/unsupported" ]; then
    echo "Trying trial boots again: $(<"$STATE/unsupported")."
    rm -f "$STATE/unsupported" "$STATE/notified-unsupported"
  fi
  deployed=$(boot_default 2>/dev/null || true)
  confirmed=$(confirmed)
  if [ -z "$deployed" ] || [ "$deployed" = "$confirmed" ]; then
    echo "Nothing to retry: GRUB's default is the confirmed system."
    return
  fi
  rm -f "$TRIAL"
  if check_supported; then
    write_boot_cfg "$confirmed"
  fi
  echo "The next reboot tries $deployed."
  systemctl start nixhost-reboot-detect.service || true
}

status() {
  echo "Booted:    $booted$(trial_boot && echo " (trial boot)" || true)"
  echo "Confirmed: $(confirmed)"
  echo "Deployed:  $(boot_default 2>/dev/null || echo unknown)"
  if [ -r "$TRIAL" ]; then
    echo "Last trial: $(trial .system): $(trial .outcome) ($(trial .detail))"
  fi
  if ! check_supported; then
    echo "Trial boots are off: $unsupported_reason"
  fi
  if ! watchdog_present; then
    echo "No hardware watchdog."
  fi
}

case "${1:-}" in
status) status ;;
start | stop | confirm | revert | deadline | switched | retry)
  exec 9>/run/nixhost-boot.lock
  flock 9
  "$1"
  ;;
*)
  echo "usage: nixhost-boot <start|stop|confirm|revert|deadline|switched|retry|status>" >&2
  exit 2
  ;;
esac
