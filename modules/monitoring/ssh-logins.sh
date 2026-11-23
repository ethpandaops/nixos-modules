# Count successful SSH logins from the journal, by user and by whether the key
# is one the running configuration pins for that user (the store copy of
# /etc/ssh/authorized_keys.d, not the live one, which root can edit). sshd
# accepts only those keys here, so an unknown key means the live file or
# sshd's configuration was changed.
now=$(date +%s)
current=$(readlink -f /run/current-system)
keys_dir=$current/etc/ssh/authorized_keys.d
counts_file=$STATE/ssh-logins
cursor_file=$STATE/ssh-cursor
last_unknown_file=$STATE/ssh-last-unknown

declare -A known=() counts=()
for file in "$keys_dir"/*; do
  [ -f "$file" ] || continue
  user=${file##*/}
  counts["$user known"]=0
  counts["$user unknown"]=0
  while read -r _ fingerprint _; do
    known["$user $fingerprint"]=1
  done < <(ssh-keygen -l -f "$file" 2>/dev/null || true)
done

if [ -r "$counts_file" ]; then
  while read -r user key count; do
    counts["$user $key"]=$count
  done <"$counts_file"
fi

if [ -s "$cursor_file" ]; then
  since=(--after-cursor="$(cat "$cursor_file")")
else
  since=(--boot)
fi
# Accepted publickey for alice from 192.0.2.1 port 51234 ssh2: ED25519 SHA256:...
accepted='^Accepted ([^ ]+) for ([^ ]+) from ([^ ]+) port [0-9]+ [^ :]+(: ([^ ]+) (SHA256:[^ ]+))?'
cursor=""
while IFS= read -r line; do
  if [[ $line == "-- cursor: "* ]]; then
    cursor=${line#-- cursor: }
    continue
  fi
  message=${line#*]: }
  [[ $message =~ $accepted ]] || continue
  method=${BASH_REMATCH[1]} user=${BASH_REMATCH[2]} from=${BASH_REMATCH[3]} fingerprint=${BASH_REMATCH[6]}
  key=unknown
  if [ "$method" = publickey ] && [ -n "${known["$user $fingerprint"]:-}" ]; then
    key=known
  fi
  counts["$user $key"]=$((${counts["$user $key"]:-0} + 1))
  if [ "$key" = unknown ]; then
    printf '%s %s %s %s %s\n' "${line%%.*}" "$user" "$method" "${fingerprint:-none}" "$from" >"$last_unknown_file"
  fi
done < <(journalctl --quiet --no-pager --output=short-unix --show-cursor "${since[@]}" \
  --identifier=sshd --identifier=sshd-session --identifier=sshd-auth)

for entry in "${!counts[@]}"; do
  echo "$entry ${counts[$entry]}"
done | sort >"$counts_file.tmp"
mv -f "$counts_file.tmp" "$counts_file"
[ -z "$cursor" ] || echo "$cursor" >"$cursor_file"

{
  echo "# HELP nixhost_ssh_logins_total Successful SSH logins by user, and whether the key is one the configuration pins for that user."
  echo "# TYPE nixhost_ssh_logins_total counter"
  while read -r user key count; do
    echo "nixhost_ssh_logins_total{user=\"$(label "$user")\",key=\"$key\"} $count"
  done <"$counts_file"
  if [ -s "$last_unknown_file" ]; then
    read -r at user method fingerprint from <"$last_unknown_file"
    echo "# HELP nixhost_ssh_last_unknown_login_timestamp_seconds The last login with a key the configuration doesn't pin for that user."
    echo "# TYPE nixhost_ssh_last_unknown_login_timestamp_seconds gauge"
    echo "nixhost_ssh_last_unknown_login_timestamp_seconds{user=\"$(label "$user")\",method=\"$(label "$method")\",fingerprint=\"$(label "$fingerprint")\",from=\"$(label "$from")\"} $at"
  fi
  echo "# HELP nixhost_ssh_logins_last_run_timestamp_seconds When the SSH login count last ran."
  echo "# TYPE nixhost_ssh_logins_last_run_timestamp_seconds gauge"
  echo "nixhost_ssh_logins_last_run_timestamp_seconds $now"
} | write_metrics nixhost_ssh
