# Kernel protections, the audit system and BPF program loads, as
# nixhost_kernel_*, nixhost_audit_* and nixhost_bpf_* textfile metrics.
# SETTINGS (written by kernel.nix) says which protections the configuration
# turns on and which programs may load BPF.
STATE=/var/lib/nixhost-kernel
now=$(date +%s)
current=$(readlink -f /run/current-system)
out=$(mktemp)
trap 'rm -f "$out"' EXIT
mkdir -p "$STATE"

# Protections the configuration turns on, 1 when in force. A kernel parameter
# that the booted system didn't have yet waits for a reboot
# (nixhost_kernel_protection_pending); one it had but the running kernel
# lacks was taken off the command line at boot.
cmdline=" $(cat /proc/cmdline) "
booted_params=" $(cat /run/booted-system/kernel-params 2>/dev/null || true) "
audit_status=""
if [ "$(jq -r .audit "$SETTINGS")" = true ]; then
  audit_status=$(auditctl -s 2>/dev/null || true)
fi
{
  echo "# HELP nixhost_kernel_protection Whether a kernel or audit protection the configuration turns on is in force."
  echo "# TYPE nixhost_kernel_protection gauge"
  pending=()
  # Fields are separated by \x1f: IFS would merge empty tab-separated ones.
  while IFS=$'\x1f' read -r check kind arg want; do
    ok=0
    case "$kind" in
    sysctl) [ "$(cat "/proc/sys/$arg" 2>/dev/null)" != "$want" ] || ok=1 ;;
    cmdline)
      if [[ $cmdline == *" $arg "* ]]; then
        ok=1
      elif [[ $booted_params != *" $arg "* ]]; then
        pending+=("$check")
      fi
      ;;
    audit) [ "$(awk '$1 == "enabled" { print $2 }' <<<"$audit_status")" != "$want" ] || ok=1 ;;
    firewall)
      ok=1
      if [ "$arg" = nftables ]; then
        nft list table inet nixos-fw >/dev/null 2>&1 || ok=0
      else
        for command in $arg; do
          "$command" -w -C INPUT -j nixos-fw 2>/dev/null || ok=0
        done
      fi
      ;;
    esac
    echo "nixhost_kernel_protection{check=\"$(label "$check")\"} $ok"
  done < <(jq -r '.checks[] | [.check, .kind, .arg, .want] | join("\u001f")' "$SETTINGS")
  echo "# HELP nixhost_kernel_protection_pending A protection that is off only until the next reboot (a kernel parameter the booted system didn't have)."
  echo "# TYPE nixhost_kernel_protection_pending gauge"
  for check in "${pending[@]}"; do
    echo "nixhost_kernel_protection_pending{check=\"$(label "$check")\"} 1"
  done
} >>"$out"

if [ "$(jq -r .audit "$SETTINGS")" = true ]; then
  # The kernel's audit counters: events lost (a full backlog or rate limit,
  # which can hide records) and waiting.
  {
    for field in lost backlog; do
      echo "# HELP nixhost_audit_$field The kernel audit system's $field count (auditctl -s)."
      echo "# TYPE nixhost_audit_$field gauge"
      echo "nixhost_audit_$field $(awk -v f="$field" '$1 == f { print $2 }' <<<"$audit_status" | grep -E '^[0-9]+$' || echo 0)"
    done
  } >>"$out"

  # The loaded audit rules against those loaded when audit-rules-nixos last
  # started: deleting or adding a rule (auditctl -d/-D/-a) is reported line by
  # line until the next activation reloads them. Runs in the 2 minutes after
  # a load or an activation leave the baseline alone.
  unit=audit-rules-nixos.service
  set_up=$(($(systemctl show -p ActiveEnterTimestampMonotonic --value "$unit") / 1000000))
  uptime=$(cut -d. -f1 /proc/uptime)
  activated=$(stat -c %Y /run/current-system)
  if [ "$(systemctl show -p ActiveState --value "$unit")" = active ] &&
    [ $((uptime - set_up)) -ge 120 ] && [ $((now - activated)) -ge 120 ]; then
    key="$current $(systemctl show -p InvocationID --value "$unit")"
    rules=$(auditctl -l 2>/dev/null | grep -v '^No rules$' || true)
    if [ "$(cat "$STATE/audit-rules-key" 2>/dev/null)" != "$key" ]; then
      printf '%s\n' "$rules" >"$STATE/audit-rules"
      printf '%s\n' "$key" >"$STATE/audit-rules-key"
    fi
    mapfile -t changed < <(printf '%s\n' "$rules" |
      diff --unchanged-line-format= --old-line-format='- %L' --new-line-format='+ %L' "$STATE/audit-rules" - || true)
    {
      echo "# HELP nixhost_audit_rules Audit rules loaded in the kernel."
      echo "# TYPE nixhost_audit_rules gauge"
      echo "nixhost_audit_rules $(printf '%s\n' "$rules" | awk NF | wc -l)"
      echo "# HELP nixhost_audit_rules_changed Audit rules added (+) or removed (-) since audit-rules-nixos loaded them."
      echo "# TYPE nixhost_audit_rules_changed gauge"
      echo "nixhost_audit_rules_changed ${#changed[@]}"
      echo "# HELP nixhost_audit_rules_changed_info One series per change, at most $MAX_SERIES."
      echo "# TYPE nixhost_audit_rules_changed_info gauge"
      n=0
      for rule in "${changed[@]}"; do
        n=$((n + 1))
        [ "$n" -le "$MAX_SERIES" ] || break
        echo "nixhost_audit_rules_changed_info{rule=\"$(label "$rule")\"} 1"
      done
    } >>"$out"
  fi

  # From the audit records in the journal since the last run:
  # - BPF program loads (the bpf rule, key "bpf", bpf(BPF_PROG_LOAD)). A load
  #   by systemd (PID 1, for unit IP filters, device and filesystem
  #   restrictions), by a program named in knownLoaders (an executable in the
  #   Nix store) or by an executable in knownExecutables (an exact path, such
  #   as one inside a container's image) is known; any other is not.
  # - Kernel modules loaded after boot (KERN_MODULE records, from the modules
  #   rule), counting from when multi-user.target was reached: what
  #   security.lockKernelModules would refuse.
  counts_file=$STATE/bpf-loads
  modules_file=$STATE/module-late-loads
  cursor_file=$STATE/bpf-cursor
  last_unknown_file=$STATE/bpf-last-unknown
  declare -A counts=() known_names=() known_exes=() late=()
  while read -r name; do
    known_names[$name]=1
  done < <(jq -r '.knownLoaders[]' "$SETTINGS")
  while read -r path; do
    known_exes[$path]=1
  done < <(jq -r '.knownExecutables[]' "$SETTINGS")
  counts["systemd true"]=${counts["systemd true"]:-0}
  if [ -r "$counts_file" ]; then
    while read -r loader known count; do
      counts["$loader $known"]=$count
    done <"$counts_file"
  fi
  if [ -r "$modules_file" ]; then
    while read -r module count; do
      late[$module]=$count
    done <"$modules_file"
  fi
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  booted_at=$(systemctl show -p ActiveEnterTimestamp --value multi-user.target)
  booted_at=$([ -z "$booted_at" ] || date -d "$booted_at" +%s)
  if [ -s "$cursor_file" ]; then
    since=(--after-cursor="$(cat "$cursor_file")")
  else
    since=(--boot)
  fi
  cursor=""
  # One line per audit entry: its cursor, its kind (bpf for a successful
  # bpf-key load, module for a module load) and the details.
  while IFS=$'\x1f' read -r entry_cursor kind pid exe comm auid at entry_boot module; do
    cursor=$entry_cursor
    if [ "$kind" = module ]; then
      # Earlier boots' records (the end of the last one) can't be placed.
      if [ "$entry_boot" = "${boot_id//-/}" ] && [ -n "$booted_at" ] && [ "$at" -gt "$booted_at" ] && [ -n "$module" ]; then
        if [ -z "${late[$module]+set}" ] && [ "${#late[@]}" -ge "$MAX_SERIES" ]; then
          module=other
        fi
        late[$module]=$((${late[$module]:-0} + 1))
      fi
      continue
    fi
    [ "$kind" = bpf ] || continue
    loader=${exe##*/}
    loader=${loader#.}
    loader=${loader%-wrapped}
    known=false
    if [ "$pid" = 1 ]; then
      known=true
      loader=systemd
    elif [[ $exe == /nix/store/* ]] && [ -n "${known_names[$loader]:-}" ]; then
      known=true
    elif [ -n "${known_exes[$exe]:-}" ]; then
      known=true
    fi
    if [ "$known" = false ]; then
      [ -n "$loader" ] || loader=unknown
      [ "$auid" != 4294967295 ] || auid="unset" # no login uid: started by a service
      printf '%s\x1f%s\x1f%s\x1f%s\n' "$at" "$(label "$exe")" "$(label "$comm")" "$auid" >"$last_unknown_file"
      # Past MAX_SERIES unknown loaders, the rest count as "other".
      if [ -z "${counts["$loader false"]+set}" ] &&
        [ "$(printf '%s\n' "${!counts[@]}" | grep -c ' false$')" -ge "$MAX_SERIES" ]; then
        loader=other
      fi
    fi
    counts["$loader $known"]=$((${counts["$loader $known"]:-0} + 1))
  done < <(journalctl --quiet --no-pager --output=json "${since[@]}" _TRANSPORT=audit |
    jq -r 'def unquote: ltrimstr("\"") | rtrimstr("\"");
      [.__CURSOR,
      (if (._AUDIT_FIELD_KEY // "" | unquote) == "bpf" and ._AUDIT_FIELD_SUCCESS == "yes" then "bpf"
       elif ._AUDIT_TYPE_NAME == "KERN_MODULE" then "module" else "" end),
      ._PID // "", ._EXE // "", ._COMM // "", ._AUDIT_LOGINUID // "unset",
      ((.__REALTIME_TIMESTAMP | tonumber) / 1000000 | floor | tostring),
      ._BOOT_ID // "", (._AUDIT_FIELD_NAME // "" | unquote)] | join("\u001f")')
  for entry in "${!counts[@]}"; do
    echo "$entry ${counts[$entry]}"
  done | sort >"$counts_file.tmp"
  mv -f "$counts_file.tmp" "$counts_file"
  for module in "${!late[@]}"; do
    echo "$module ${late[$module]}"
  done | sort >"$modules_file.tmp"
  mv -f "$modules_file.tmp" "$modules_file"
  [ -z "$cursor" ] || echo "$cursor" >"$cursor_file"
  {
    echo "# HELP nixhost_bpf_loads_total BPF programs loaded, by loading program and whether it is a known loader."
    echo "# TYPE nixhost_bpf_loads_total counter"
    while read -r loader known count; do
      echo "nixhost_bpf_loads_total{loader=\"$(label "$loader")\",known=\"$known\"} $count"
    done <"$counts_file"
    if [ -s "$last_unknown_file" ]; then
      IFS=$'\x1f' read -r at exe comm auid <"$last_unknown_file"
      echo "# HELP nixhost_bpf_last_unknown_load_timestamp_seconds The last BPF load by a program that isn't a known loader."
      echo "# TYPE nixhost_bpf_last_unknown_load_timestamp_seconds gauge"
      echo "nixhost_bpf_last_unknown_load_timestamp_seconds{exe=\"$exe\",comm=\"$comm\",auid=\"$auid\"} $at"
    fi
    echo "# HELP nixhost_kernel_module_late_modules Kernel modules loaded after boot (after multi-user.target): what security.lockKernelModules would refuse. Add each to boot.kernelModules (ethpandaops.kernelModules.allowlist) before locking."
    echo "# TYPE nixhost_kernel_module_late_modules gauge"
    echo "nixhost_kernel_module_late_modules ${#late[@]}"
    echo "# HELP nixhost_kernel_module_late_loads_total Loads of each kernel module after boot, at most $MAX_SERIES modules."
    echo "# TYPE nixhost_kernel_module_late_loads_total counter"
    while read -r module count; do
      echo "nixhost_kernel_module_late_loads_total{module=\"$(label "$module")\"} $count"
    done <"$modules_file"
  } >>"$out"
fi

{
  echo "# HELP nixhost_kernel_last_run_timestamp_seconds When the kernel and audit check last finished."
  echo "# TYPE nixhost_kernel_last_run_timestamp_seconds gauge"
  echo "nixhost_kernel_last_run_timestamp_seconds $now"
} >>"$out"
write_metrics nixhost_kernel <"$out"
