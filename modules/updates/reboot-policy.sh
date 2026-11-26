# nixhost-reboot <policy|status|login|hold|at|now>. SETTINGS (window, delays,
# pause) comes from the module; reboot-detect writes required.json.
RUN=/run/nixhost/reboot
STATE=/var/lib/nixhost-reboot

# setting <name>: from SETTINGS, read once; empty for false or null.
declare -A SETTING
while IFS=$'\t' read -r key value; do
  SETTING[$key]=$value
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value // "")"' "$SETTINGS")
setting() {
  echo "${SETTING[$1]}"
}

# fmt <epoch>: such as "Thu 26 Nov 03:30 UTC". A builtin, so the login
# message stays quick.
export TZ=UTC
fmt() {
  printf '%(%a %d %b %H:%M UTC)T\n' "$1"
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

# next_window <epoch>: the first policy run inside the window at or after that
# time. The timer runs the policy on the quarter hour.
next_window() {
  local run
  run=$((($1 + 899) / 900 * 900))
  if in_window "$run"; then
    echo "$run"
    return
  fi
  run=$((run - run % 86400 + $(setting windowStart) * 60))
  if [ "$run" -le "$1" ]; then
    run=$((run + 86400))
  fi
  echo $(((run + 899) / 900 * 900))
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
  rm -f "$RUN"/status-line "$RUN"/policy.json "$RUN"/hold-until "$RUN"/hold-by \
    "$RUN"/reboot-at "$RUN"/reboot-at-by "$RUN"/rebooting-at "$RUN"/notified-*
  systemctl stop nixhost-reboot-at.timer 2>/dev/null || true
}

# load_state: the pending reboot as it stands now, in globals: when it
# became pending, the deadline, holds, pauses, the time chosen with
# reboot-at, the next time the policy may reboot (planned, 0 for none), a
# running deadline countdown (scheduled), logins and inhibitors. It only
# reads: policy acts on it, and message shows it.
load_state() {
  now=$(date +%s)
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
  # Held by trial boots (ethpandaops.reboot.trial): rebooting again would
  # only boot the confirmed system.
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
  hold_expired=0
  if [ "$hold" -gt 0 ] && [ "$hold" -le "$now" ]; then
    hold_expired=1
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
  if [ "$paused" = 1 ]; then
    earliest=$(max "$earliest" "$pause_end")
  fi
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
  case "$held" in
  trial-reverted) what="$what, held: the new system failed its trial boot" ;;
  trial-not-armed) what="$what, held: no trial boot of the new system could be set up" ;;
  esac
  if [ -n "$held" ]; then
    planned=$at
  fi

  scheduled=$(scheduled_reboot)
  sessions=$(open_sessions | sort -u | paste -sd, -)
  inhibitors=$(shutdown_inhibitors | paste -sd, -)
}

policy() {
  mkdir -p "$RUN" "$STATE"
  local first reason

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

  load_state
  if [ "$hold_expired" = 1 ]; then
    notify_users info "Reboot hold expired" "The reboot hold set by $hold_by has expired."
    rm -f "$RUN/hold-until" "$RUN/hold-by"
  fi

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

  # The line already-open shells and tmux show, and the data reboot-hold
  # and reboot-at check against. The login message is worked out at login.
  if [ "$scheduled" -gt 0 ]; then
    first="Rebooting at $(fmt "$scheduled") for a pending update. Save your work."
  elif [ -n "$held" ]; then
    first="Update held: no trial boot of the new system is possible now, and the admins have been told. Run reboot-status."
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
      notify_users info "Update held" "${what}. The box stays on the last confirmed system until the admins deal with it."
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

# eta <epoch>: how long until then, in whole minutes rounded up, such as
# "in 2d 3h", "in 5h 12m", "in 4m" or "now".
eta() {
  local left=$((($1 - now + 59) / 60 * 60))
  if [ "$left" -le 0 ]; then
    echo now
  elif [ "$left" -ge 86400 ]; then
    echo "in $((left / 86400))d $((left % 86400 / 3600))h"
  elif [ "$left" -ge 3600 ]; then
    echo "in $((left / 3600))h $((left % 3600 / 60))m"
  else
    echo "in $((left / 60))m"
  fi
}

# fact <label> <line>...: a labelled line of the message, then its continuations.
fact() {
  local label=$1 line
  shift
  for line in "$@"; do
    printf '  %-10s %s\n' "$label" "$line"
    label=""
  done
}

# message: the pending reboot as it stands now, for people logging in (the
# login subcommand, which sshd runs through pam_exec) and reboot-status: a
# panda saying when, then why, the deadline, what it waits for, and the
# commands.
message() {
  local why kind width i head line logged_in=() panda bubble waits=()
  load_state
  why=$(jq -r '
    def change($name; $booted; $new):
      if $booted == $new then "rebuilt \($name) \($new)" else "\($name) \($booted) -> \($new)" end;
    [.components[] as $c
      | if $c == "kernel" then change("kernel"; .kernel.booted; .kernel.new)
        elif $c == "systemd" then change("systemd"; .systemd.booted | ltrimstr("systemd-"); .systemd.new | ltrimstr("systemd-"))
        else {"kernel-modules": "new kernel modules", "kernel-params": "new kernel parameters",
              "etc/modules-load.d/nixos.conf": "new boot module list",
              "boot-default": "a deploy set to start at the next boot"}[$c] // "new \($c)"
        end]
    | join(", ")' "$RUN/required.json")
  if [ -n "$critical" ]; then
    why="$why (critical)"
  fi

  if [ "$scheduled" -gt 0 ]; then
    kind="countdown"
    bubble=("REBOOTING SOON! SAVE YOUR WORK!" "$(fmt "$scheduled")" "$(eta "$scheduled"): the deadline has passed")
  elif [ "$at" -gt 0 ] && [ "$planned" = "$at" ]; then
    kind="at"
    bubble=("REBOOT COMING!" "$(fmt "$at")" "$(eta "$at"), set by $at_by with reboot-at")
  elif [ -n "$held" ]; then
    kind="held"
    if [ "$held" = trial-not-armed ]; then
      bubble=("REBOOT PENDING, BUT HELD" "no trial boot could be set up," "so it waits for an admin")
    else
      bubble=("REBOOT PENDING, BUT HELD" "the update failed its trial boot," "so it waits for an admin")
    fi
  elif [ "$supervised" = 1 ]; then
    kind="admin"
    bubble=("REBOOT PENDING" "a new kernel series, so an admin" "picks the time")
  elif [ "$planned" -ge "$deadline" ]; then
    kind="deadline"
    bubble=("REBOOT COMING!" "$(fmt "$deadline")" "$(eta "$deadline"): the hard deadline")
  else
    kind="window"
    bubble=("REBOOT COMING!" "$(fmt "$planned")" "$(eta "$planned"), if nobody is logged in")
  fi

  # The panda, with the speech bubble at its eyes.
  mapfile -t panda <<'PANDA'
   .-.           .-.
  (###)._______.(###)
   `-/           \-'
    /  .--.   .--.  \
   |  /#o##\ /##o#\  |
   |  \####/ \####/  |
   |        ^        |
    \     \___/     /
     `-._________.-'
PANDA
  width=0
  for line in "${bubble[@]}"; do
    width=$(max "$width" "${#line}")
  done
  head=$(printf '%*s' "$((width + 2))" "" | tr ' ' -)
  panda[2]=$(printf '%-24s   .%s.' "${panda[2]}" "$head")
  panda[3]=$(printf '%-24s  /  %-*s  %s' "${panda[3]}" "$width" "${bubble[0]}" "\\")
  panda[4]=$(printf '%-24s <   %-*s   |' "${panda[4]}" "$width" "${bubble[1]}")
  panda[5]=$(printf '%-24s  %s  %-*s  /' "${panda[5]}" "\\" "$width" "${bubble[2]}")
  panda[6]=$(printf "%-24s   '%s'" "${panda[6]}" "$head")
  echo
  for i in "${!panda[@]}"; do
    echo "${panda[$i]}"
  done
  echo

  fact "Why" "$why"
  fact "Since" "$(fmt "$since")"
  if [ "$supervised" = 1 ] && [ -z "$held" ] && [ "$kind" != countdown ]; then
    fact "Deadline" "$(fmt "$deadline") ($(eta "$deadline")): the admins', not a reboot"
  elif [ -z "$held" ] && [ "$kind" != countdown ]; then
    fact "Deadline" "$(fmt "$deadline") ($(eta "$deadline")): reboots even if you're busy"
  fi
  case "$held" in
  trial-reverted)
    fact "Held" "The new system failed its trial boot, so the box went back to" \
      "the last confirmed one. An admin deploys a fix, or runs" "'sudo nixhost-boot retry' to try it again."
    ;;
  trial-not-armed)
    fact "Held" "No trial boot of the new system could be set up. An admin" \
      "fixes it (journalctl -u nixhost-boot) and runs" "'sudo nixhost-boot retry'."
    ;;
  esac
  if [ "$kind" = admin ]; then
    fact "Admins" "Reboot it with reboot-at or reboot-now while someone who" \
      "can fix a boot that fails is on hand."
  fi
  if [ "$at" -gt 0 ] && [ "$kind" != at ] && [ "$kind" != countdown ]; then
    fact "Reboot-at" "$(fmt "$at") ($(eta "$at")), set by $at_by, even if you're busy"
  fi

  # What keeps it from an earlier window. Pauses and holds end by the
  # deadline; logins and inhibitors only hold up the window.
  if [ "$kind" = window ] || [ "$kind" = deadline ]; then
    if [ "$paused" = 1 ]; then
      fact "Paused" "by the admins until $(fmt "$pause_end") ($(eta "$pause_end"))"
    fi
    if [ "$hold" -gt "$now" ]; then
      fact "On hold" "by $hold_by (reboot-hold) until $(fmt "$hold") ($(eta "$hold"))"
    fi
  fi
  if [ "$kind" = window ]; then
    # Who is logging in counts: their session may not be listed yet.
    IFS=, read -ra logged_in <<<"$sessions"
    if [ -n "${PAM_USER:-}" ]; then
      logged_in+=("$PAM_USER")
    fi
    if [ "${#logged_in[@]}" -gt 0 ]; then
      line=$(printf '%s\n' "${logged_in[@]}" | sort -u | paste -sd, -)
      waits+=("everyone to log out (logged in now: ${line//,/, })")
    fi
    if [ -n "$inhibitors" ]; then
      waits+=("inhibitors to end: ${inhibitors//,/, }")
    fi
  fi
  if [ "${#waits[@]}" -gt 0 ]; then
    fact "Waits for" "${waits[@]}"
  fi
  if [ "$kind" = window ]; then
    fact "Long job?" "reboot-hold 3d holds the reboot (sudo users, up to the deadline)"
  fi
  fact "Commands" "reboot-status | reboot-hold 2d | reboot-at \"Fri 02:00\" | reboot-now"
  echo
}

status() {
  if ! pending; then
    echo "No reboot pending."
    return
  fi
  message
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
  # The SSH login message: nothing while no reboot is pending.
  login) if pending; then message; fi ;;
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
    echo "usage: nixhost-reboot <policy|status|login|hold|at|now>" >&2
    exit 2
    ;;
esac
