# nixhost-reboot <policy|status|hold|at|now>. SETTINGS (window, delays,
# pause) comes from the module; reboot-detect writes required.json.
RUN=/run/nixhost/reboot
STATE=/var/lib/nixhost-reboot

setting() {
  jq -r ".$1 // empty" "$SETTINGS"
}

fmt() {
  date -u -d "@$1" '+%a %d %b %H:%M UTC'
}

readnum() {
  local value
  value=$(cat "$1" 2>/dev/null || true)
  [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo 0
}

max() {
  if [ "$1" -gt "$2" ]; then echo "$1"; else echo "$2"; fi
}

# in_window <epoch>: is that time inside the nightly window (UTC)?
in_window() {
  local minute start end
  minute=$((($1 % 86400) / 60))
  start=$(setting windowStart)
  end=$(setting windowEnd)
  if [ "$start" -lt "$end" ]; then
    [ "$minute" -ge "$start" ] && [ "$minute" -lt "$end" ]
  else
    [ "$minute" -ge "$start" ] || [ "$minute" -lt "$end" ]
  fi
}

# next_window <epoch>: that time if it is inside the window, else the next start.
next_window() {
  local opening
  if in_window "$1"; then
    echo "$1"
    return
  fi
  opening=$(($1 - $1 % 86400 + $(setting windowStart) * 60))
  if [ "$opening" -le "$1" ]; then
    opening=$((opening + 86400))
  fi
  echo "$opening"
}

# Logged-in sessions that block a window reboot: active or online, not ones
# closing after a disconnect.
open_sessions() {
  local id state
  for id in $(loginctl list-sessions --json=short | jq -r '.[] | select(.class == "user") | .session'); do
    state=$(loginctl show-session "$id" --property=State --value 2>/dev/null || true)
    if [ "$state" = active ] || [ "$state" = online ]; then
      loginctl show-session "$id" --property=Name --value
    fi
  done
}

# Blocking shutdown inhibitors, as "who (why)".
shutdown_inhibitors() {
  busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager ListInhibitors |
    jq -r '.data[0][] | select((.[0] | split(":") | index("shutdown")) and .[3] == "block") | "\(.[1]) (\(.[2]))"'
}

# When the deadline countdown will reboot, as epoch seconds, or 0.
scheduled_reboot() {
  if systemctl is-active -q nixhost-deadline-reboot.service; then
    readnum "$RUN/rebooting-at"
  else
    echo 0
  fi
}

# reboot_regardless: an orderly reboot that inhibitors can't stop. logind
# refuses `shutdown -r +N` and, without polkit, `systemctl reboot -i` while a
# block inhibitor is held; starting reboot.target through systemd skips it.
reboot_regardless() {
  systemctl start --no-block --job-mode=replace-irreversibly reboot.target
}

# countdown <epoch>: wall warnings, then reboot_regardless. Runs as
# nixhost-deadline-reboot.service.
countdown() {
  local at=$1 minutes delay
  for minutes in 60 30 10 1 0; do
    # One clock read: two can straddle a second and ask sleep for -1.
    delay=$((at - minutes * 60 - $(date +%s)))
    if [ "$delay" -lt 0 ]; then
      continue
    fi
    sleep "$delay"
    if [ "$minutes" -gt 0 ]; then
      wall "This box reboots in $minutes minute(s), at $(fmt "$at"), to finish an update: the deadline has passed. Save your work."
    fi
  done
  reboot_regardless
}

# notify_users <critical|warning|info|ok> <title> <message>
notify_users() {
  local severity=$1 title=$2
  shift 2
  "$NOTIFY" --severity "$severity" --title "$title" users "$*" || true
}

# remember <file> <value>: true the first time a value is seen, so each notice goes out once.
remember() {
  if [ "$(cat "$RUN/$1" 2>/dev/null || true)" = "$2" ]; then
    return 1
  fi
  echo "$2" >"$RUN/$1"
}

# record_reboot <reason>: noted before rebooting, reported once the box is back.
record_reboot() {
  jq -n --arg reason "$1" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" \
    '{$reason, $boot}' >"$STATE/rebooting.json"
}

as_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if ! id -nG | tr ' ' '\n' | grep -qx wheel; then
      echo "Only sudo users can change the reboot schedule. Ask an admin." >&2
      exit 1
    fi
    exec sudo "$0" "$@"
  fi
}

# duration_seconds 48h|2d|90m|1w
duration_seconds() {
  if [[ ! "$1" =~ ^([0-9]+)([mhdw])$ ]]; then
    echo "Give a duration such as 90m, 48h, 3d or 1w." >&2
    exit 2
  fi
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    w) echo $((n * 604800)) ;;
  esac
}

pending() {
  [ -r "$RUN/required.json" ] && [ "$(jq -r .required "$RUN/required.json")" = true ]
}

# kernel_series_change: whether the pending kernel is of another series
# (major.minor) than the booted one, such as 7.3.5 -> 7.4.1.
kernel_series_change() {
  local booted new
  jq -e '.components | index("kernel")' "$RUN/required.json" >/dev/null || return 1
  booted=$(jq -r .kernel.booted "$RUN/required.json")
  new=$(jq -r .kernel.new "$RUN/required.json")
  [ "$(cut -d. -f1-2 <<<"$booted")" != "$(cut -d. -f1-2 <<<"$new")" ]
}

clear_pending_state() {
  rm -f "$RUN"/motd "$RUN"/status-line "$RUN"/policy.json "$RUN"/hold-until "$RUN"/hold-by \
    "$RUN"/reboot-at "$RUN"/reboot-at-by "$RUN"/rebooting-at "$RUN"/notified-*
  systemctl stop nixhost-reboot-at.timer 2>/dev/null || true
}

policy() {
  mkdir -p "$RUN" "$STATE"
  local now since deadline paused pause_end hold hold_by at at_by earliest planned scheduled
  local what first critical supervised held sessions inhibitors reason
  now=$(date +%s)

  # Back from a reboot this policy started: say so once.
  if [ -r "$STATE/rebooting.json" ]; then
    if [ "$(jq -r .boot "$STATE/rebooting.json")" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then
      notify_users ok "Back after a reboot" "The box is back after its reboot ($(jq -r .reason "$STATE/rebooting.json")), running kernel $(uname -r)."
      rm -f "$STATE/rebooting.json"
    fi
  fi

  if ! pending; then
    clear_pending_state
    write_metrics nixhost_reboot_policy </dev/null
    echo "no reboot pending"
    return
  fi

  since=$(jq -r .since "$RUN/required.json")
  deadline=$((since + $(setting maxDelay)))
  critical=$(setting critical)
  # A new kernel series never reboots by itself, in the window or at the
  # deadline: if it doesn't boot on this hardware, someone with console
  # access has to be on hand. An admin reboots with reboot-at or reboot-now;
  # the deadline becomes theirs (nixhost_reboot_deadline_timestamp_seconds).
  supervised=0
  if [ -n "$(setting holdKernelSeriesChange)" ] && [ -z "$critical" ] && kernel_series_change; then
    supervised=1
  fi
  # A system whose trial boot failed (ethpandaops.reboot.trial): the box went
  # back to the confirmed system, and rebooting again wouldn't try it.
  held=$(jq -r '.held // empty' "$RUN/required.json")
  paused=0
  pause_end=0
  if [ -n "$(setting pauseUntil)" ]; then
    pause_end=$(date -u -d "$(setting pauseUntil)" +%s)
    if [ "$now" -lt "$pause_end" ]; then
      paused=1
      deadline=$(max "$deadline" "$pause_end")
    fi
  fi

  hold=$(readnum "$RUN/hold-until")
  hold_by=$(cat "$RUN/hold-by" 2>/dev/null || echo someone)
  if [ "$hold" -gt 0 ] && [ "$hold" -le "$now" ]; then
    notify_users info "Reboot hold expired" "The reboot hold set by $hold_by has expired."
    rm -f "$RUN/hold-until" "$RUN/hold-by"
    hold=0
  fi
  if [ "$hold" -gt "$deadline" ]; then
    hold=$deadline
  fi

  at=$(readnum "$RUN/reboot-at")
  at_by=$(cat "$RUN/reboot-at-by" 2>/dev/null || echo someone)
  if [ "$supervised" = 0 ] && [ "$at" -gt "$deadline" ]; then
    at=$deadline
  fi

  earliest=$(max "$((since + $(setting minDelay)))" "$(max "$hold" "$now")")
  planned=$(next_window "$earliest")
  if [ "$planned" -gt "$deadline" ]; then
    planned=$deadline
  fi
  if [ "$at" -gt 0 ] && [ "$at" -lt "$planned" ]; then
    planned=$at
  fi

  if jq -e '.components | index("kernel")' "$RUN/required.json" >/dev/null; then
    what="Kernel security update waiting: $(jq -r '"\(.kernel.booted) -> \(.kernel.new)"' "$RUN/required.json")"
  else
    what="System update waiting for a reboot ($(jq -r '.components | join(", ")' "$RUN/required.json"))"
  fi
  if [ -n "$critical" ]; then
    what="$what, marked critical by the admins"
  fi

  if [ "$supervised" = 1 ]; then
    what="$what, a new kernel series"
    planned=$at
  fi
  if [ -n "$held" ]; then
    what="$what, held: the new system failed its trial boot"
    planned=$at
  fi

  scheduled=$(scheduled_reboot)
  sessions=$(open_sessions | sort -u | paste -sd, -)
  inhibitors=$(shutdown_inhibitors | paste -sd, -)

  if [ "$scheduled" -eq 0 ]; then
    reason=""
    if [ "$paused" = 0 ] && [ "$supervised" = 0 ] && [ -z "$held" ] && [ "$now" -ge "$deadline" ]; then
      echo "deadline $(fmt "$deadline") reached; rebooting in $(setting deadlineWarningMinutes) minutes"
      record_reboot "deadline reached"
      scheduled=$((now + $(setting deadlineWarningMinutes) * 60))
      echo "$scheduled" >"$RUN/rebooting-at"
      systemctl reset-failed nixhost-deadline-reboot.service 2>/dev/null || true
      systemd-run --quiet --unit=nixhost-deadline-reboot --description="Reboot at the update deadline" \
        "$(readlink -f "$0")" countdown "$scheduled"
      wall "This box reboots at $(fmt "$scheduled") to finish an update: the deadline has passed. Save your work."
      "$NOTIFY" --severity warning --title "Rebooting at the deadline" all \
        "Deadline reached: rebooting at $(fmt "$scheduled") to finish an update. ${what}." || true
    elif [ "$at" -gt 0 ] && [ "$now" -ge "$at" ]; then
      reason="the time $at_by chose with reboot-at"
    elif [ "$paused" = 0 ] && [ "$supervised" = 0 ] && [ -z "$held" ] && [ "$now" -ge "$((since + $(setting minDelay)))" ] &&
      [ "$now" -ge "$hold" ] && in_window "$now" && [ -z "$sessions" ] && [ -z "$inhibitors" ]; then
      reason="nightly window, nobody logged in"
    else
      echo "waiting: planned $(fmt "$planned"), deadline $(fmt "$deadline"), sessions [$sessions], inhibitors [$inhibitors], hold $hold, paused $paused, supervised $supervised"
    fi
    if [ -n "$reason" ]; then
      echo "rebooting now: $reason"
      record_reboot "$reason"
      notify_users warning "Rebooting now" "Rebooting now ($reason) to finish an update. ${what}."
      if [ "$at" -gt 0 ] && [ "$now" -ge "$at" ]; then
        reboot_regardless
      else
        systemctl reboot
      fi
      return
    fi
  fi

  # The login message, the one-line status and reboot-status's data.
  {
    echo "*** $what (since $(fmt "$since"))"
    if [ "$scheduled" -gt 0 ]; then
      echo "*** REBOOTING at $(fmt "$scheduled"). Save your work."
    else
      if [ -n "$held" ]; then
        echo "*** The new system failed its trial boot and the box went back to the last confirmed one, so it doesn't reboot for it: an admin deploys a fix, or runs 'sudo nixhost-boot retry' to try it once more at the next reboot"
      elif [ "$supervised" = 1 ]; then
        echo "*** It doesn't reboot by itself: an admin reboots it (reboot-at or reboot-now) with someone on hand who can fix a boot that fails"
      fi
      if [ "$paused" = 1 ]; then
        echo "*** Automatic reboots are paused by the admins until $(fmt "$pause_end")"
      fi
      if [ "$hold" -gt "$now" ]; then
        echo "*** Held by $hold_by until $(fmt "$hold") (reboot-hold 0 clears it)"
      fi
      if [ "$at" -gt 0 ] && [ "$planned" = "$at" ]; then
        echo "*** Planned reboot: $(fmt "$planned"), as $at_by asked with reboot-at"
      elif [ "$supervised" = 0 ] && [ -z "$held" ] && [ "$planned" -lt "$deadline" ]; then
        echo "*** Planned reboot: $(fmt "$planned"), only if nobody is logged in and no hold is set"
      fi
      if [ -z "$held" ] && [ "$supervised" = 1 ]; then
        echo "*** Admins' deadline: $(fmt "$deadline")"
      elif [ -z "$held" ]; then
        echo "*** Hard deadline:  $(fmt "$deadline") (reboots then even if you're busy)"
      fi
    fi
    echo "*** Commands: reboot-status | reboot-hold 48h | reboot-at \"Fri 02:00\" | reboot-now"
    echo "*** Long job? Hold the reboot while it runs: reboot-hold 3d (sudo users, up to the deadline)"
  } >"$RUN/motd.tmp"
  mv -f "$RUN/motd.tmp" "$RUN/motd"
  chmod 0644 "$RUN/motd"
  if [ "$scheduled" -gt 0 ]; then
    first="Rebooting at $(fmt "$scheduled") for a pending update. Save your work."
  elif [ -n "$held" ]; then
    first="Update held: the new system failed its trial boot, and the admins have been told. Run reboot-status."
  elif [ "$supervised" = 1 ] && [ "$planned" -gt 0 ]; then
    first="Reboot pending for a new kernel series: planned $(fmt "$planned") with reboot-at. Run reboot-status."
  elif [ "$supervised" = 1 ]; then
    first="Reboot pending for a new kernel series: an admin will schedule it. Run reboot-status."
  else
    first="Reboot pending for an update: planned $(fmt "$planned"), deadline $(fmt "$deadline"). Run reboot-status."
  fi
  echo "$first" >"$RUN/status-line"
  jq -n --argjson since "$since" --argjson deadline "$deadline" --argjson planned "$planned" \
    --argjson hold "$hold" --argjson at "$at" --argjson paused "$paused" --argjson scheduled "$scheduled" \
    --argjson supervised "$supervised" --arg held "$held" \
    '{$since, $deadline, $planned, $hold, $at, $paused, $scheduled, $supervised, $held}' >"$RUN/policy.json"

  # One-time notices.
  if [ -n "$held" ]; then
    if remember notified-held "$since"; then
      notify_users info "Update held" "${what}. The box went back to the last confirmed system and stays there until the admins deploy a fix."
    fi
  elif remember notified-pending "$since"; then
    if [ "$supervised" = 1 ]; then
      notify_users info "Reboot pending: new kernel series" "A reboot is pending. ${what}, so it doesn't happen by itself: an admin will schedule it, and reboot-status on the box shows when."
    else
      notify_users info "Reboot pending" "A reboot is pending. ${what}. Planned: $(fmt "$planned"); deadline: $(fmt "$deadline"). Use reboot-hold or reboot-at on the box to choose another time."
    fi
  fi
  if [ "$supervised" = 1 ] && [ -z "$held" ] && remember notified-supervised "$(jq -r .kernel.new "$RUN/required.json")"; then
    "$NOTIFY" --severity warning --title "Supervised reboot needed" admins \
      "${what}: it needs a supervised reboot. Run reboot-at or reboot-now on the box while someone with console access is on hand, by $(fmt "$deadline")." || true
  fi
  if [ "$paused" = 0 ] && [ "$supervised" = 0 ] && [ -z "$held" ] && [ "$scheduled" -eq 0 ]; then
    if [ "$((deadline - now))" -le 3600 ] && remember notified-1h "$deadline"; then
      wall "This box reboots within an hour ($(fmt "$deadline")) to finish an update. Run reboot-status for details."
      notify_users warning "Reboot within an hour" "The box reboots within an hour, at $(fmt "$deadline"), to finish an update."
    elif [ "$((deadline - now))" -le 86400 ] && remember notified-24h "$deadline"; then
      wall "This box reboots by $(fmt "$deadline") to finish an update. Run reboot-status for details."
      notify_users info "Reboot within a day" "The box reboots by $(fmt "$deadline") (the deadline) to finish an update."
    fi
  fi

  write_metrics nixhost_reboot_policy <<METRICS
# HELP nixhost_reboot_deadline_timestamp_seconds When the box reboots regardless; for a new kernel series, when the admins should have rebooted it.
# TYPE nixhost_reboot_deadline_timestamp_seconds gauge
nixhost_reboot_deadline_timestamp_seconds $deadline
# HELP nixhost_reboot_supervised Whether the pending reboot is for a new kernel series, which waits for an admin's reboot-at or reboot-now.
# TYPE nixhost_reboot_supervised gauge
nixhost_reboot_supervised $supervised
# HELP nixhost_reboot_planned_timestamp_seconds The next time the policy may reboot, or 0 for none.
# TYPE nixhost_reboot_planned_timestamp_seconds gauge
nixhost_reboot_planned_timestamp_seconds $planned
# HELP nixhost_reboot_hold_until_timestamp_seconds A user's hold, or 0.
# TYPE nixhost_reboot_hold_until_timestamp_seconds gauge
nixhost_reboot_hold_until_timestamp_seconds $hold
# HELP nixhost_reboot_paused Whether the admins paused automatic reboots.
# TYPE nixhost_reboot_paused gauge
nixhost_reboot_paused $paused
# HELP nixhost_reboot_critical Whether the admins marked the update critical.
# TYPE nixhost_reboot_critical gauge
nixhost_reboot_critical $([ -n "$critical" ] && echo 1 || echo 0)
METRICS
}

status() {
  if ! pending; then
    echo "No reboot pending."
    return
  fi
  cat "$RUN/motd" 2>/dev/null || echo "A reboot is pending."
  echo
  echo "Logged in now: $(open_sessions | sort -u | paste -sd, - || true)"
  echo "Shutdown inhibitors: $(shutdown_inhibitors | paste -sd, - || true)"
}

refresh() {
  systemctl start nixhost-reboot-policy.service
  status
}

hold() {
  as_root hold "$@"
  local seconds now deadline held
  if [ "$#" -ne 1 ]; then
    echo "usage: reboot-hold <duration such as 48h> | reboot-hold 0" >&2
    exit 2
  fi
  if [ "$1" = 0 ] || [ "$1" = clear ]; then
    rm -f "$RUN/hold-until" "$RUN/hold-by"
    echo "Hold cleared."
    refresh
    return
  fi
  seconds=$(duration_seconds "$1")
  if ! pending; then
    echo "No reboot pending; nothing to hold."
    return
  fi
  now=$(date +%s)
  deadline=$(jq -r .deadline "$RUN/policy.json" 2>/dev/null || echo 0)
  held=$((now + seconds))
  if [ "$deadline" -gt 0 ] && [ "$held" -gt "$deadline" ]; then
    held=$deadline
    echo "Capped at the deadline, $(fmt "$deadline")."
  fi
  echo "$held" >"$RUN/hold-until"
  echo "${SUDO_USER:-root}" >"$RUN/hold-by"
  notify_users info "Reboot held" "${SUDO_USER:-root} held the reboot until $(fmt "$held")."
  refresh
}

at() {
  as_root at "$@"
  local when now deadline
  if [ "$#" -eq 0 ]; then
    echo "usage: reboot-at <time, such as \"Fri 02:00\" or \"2026-12-01 03:00\"> | reboot-at clear" >&2
    exit 2
  fi
  if [ "$1" = clear ]; then
    rm -f "$RUN/reboot-at" "$RUN/reboot-at-by"
    systemctl stop nixhost-reboot-at.timer 2>/dev/null || true
    echo "Reboot time cleared."
    refresh
    return
  fi
  if ! pending; then
    echo "No reboot pending."
    return
  fi
  if ! when=$(TZ=UTC date -d "$*" +%s 2>/dev/null); then
    echo "Can't read that time. Try \"Fri 02:00\" or \"2026-12-01 03:00\" (UTC)." >&2
    exit 2
  fi
  now=$(date +%s)
  deadline=$(jq -r .deadline "$RUN/policy.json" 2>/dev/null || echo 0)
  if [ "$when" -le "$now" ]; then
    echo "That time has passed. Use reboot-now to reboot now." >&2
    exit 2
  fi
  if [ "$deadline" -gt 0 ] && [ "$when" -gt "$deadline" ] &&
    [ "$(jq -r '.supervised // 0' "$RUN/policy.json" 2>/dev/null)" != 1 ]; then
    echo "That's after the deadline, $(fmt "$deadline"), when the box reboots anyway." >&2
    exit 2
  fi
  echo "$when" >"$RUN/reboot-at"
  echo "${SUDO_USER:-root}" >"$RUN/reboot-at-by"
  systemctl stop nixhost-reboot-at.timer 2>/dev/null || true
  systemd-run --quiet --unit=nixhost-reboot-at --on-calendar="$(date -u -d "@$when" '+%F %T UTC')" \
    systemctl start nixhost-reboot-policy.service
  echo "The box will reboot at $(fmt "$when")."
  refresh
}

now_() {
  as_root now "$@"
  local answer
  if [ "${1:-}" != "-y" ]; then
    read -rp "Reboot $(hostname) now? [y/N] " answer
    case "$answer" in
      y | Y | yes) ;;
      *) exit 1 ;;
    esac
  fi
  record_reboot "reboot-now by ${SUDO_USER:-root}"
  systemctl reboot
}

case "${1:-}" in
  policy) policy ;;
  countdown) countdown "$2" ;;
  status) status ;;
  hold)
    shift
    hold "$@"
    ;;
  at)
    shift
    at "$@"
    ;;
  now)
    shift
    now_ "$@"
    ;;
  *)
    echo "usage: nixhost-reboot <policy|status|hold|at|now>" >&2
    exit 2
    ;;
esac
