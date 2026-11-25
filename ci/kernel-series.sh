# kernel-series --build "<host...>" [--branch master] [--mode push|pr]
#   [--auto-merge true|false]: move the pinned kernel series
# (boot.kernelPackages = pkgs.linuxPackages_7_3, say) to a newer one once
# that series has reached x.y.4 in the locked nixpkgs and was already in the
# channel 3 weeks ago, as a pull request from the kernel-series branch,
# whose check builds every host. The first host's kernel says which series
# is pinned; the pin is the attribute name in the repo's .nix files
# (linuxPackages_X_Y, or linux_X_Y as in linuxKernel.packages.linux_X_Y).
#
# With --auto-merge true (mode push only), a later run lands the pull
# request once its check passed: the same change on top of the branch,
# built, pushed, and check started, whose pass deploys it, and the reboot
# policy reboots in its window. Turn it on only after self-reverting reboots
# have come through a real kernel-patch reboot on the repo's hosts, in the
# same change that sets ethpandaops.reboot.holdKernelSeriesChange = false.
# Until then a person merges it and reboots.
build="" branch=master mode=push auto_merge=false
while [ "$#" -gt 0 ]; do
  case "$1" in
  --build)
    build=$2
    shift 2
    ;;
  --branch)
    branch=$2
    shift 2
    ;;
  --mode)
    mode=$2
    shift 2
    ;;
  --auto-merge)
    auto_merge=$2
    shift 2
    ;;
  *)
    echo "usage: kernel-series --build \"<host...>\" [--branch master] [--mode push|pr] [--auto-merge true|false]" >&2
    exit 2
    ;;
  esac
done
read -r -a hosts <<<"$build"
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "kernel-series needs --build" >&2
  exit 2
fi
if [ "$auto_merge" = true ] && [ "$mode" != push ]; then
  echo "::warning::auto-merge needs mode push: in mode pr a person lands every change as a signed commit"
  auto_merge=false
fi
# The policy: a series is taken at x.y.4 or later, once the channel has had it 3 weeks.
min_patch=4 min_days=21

kernel() {
  nix eval --raw ".#nixosConfigurations.$1.config.boot.kernelPackages.kernel.version"
}
series() {
  cut -d. -f1-2 <<<"$1"
}
# kernels <flake>: the version of each linuxPackages_X_Y series that
# evaluates in that nixpkgs, one per line.
kernels() {
  # shellcheck disable=SC2016
  nix eval --inputs-from . --json "$1#legacyPackages.x86_64-linux" --apply '
    pkgs:
    let
      names = builtins.filter (n: builtins.match "linuxPackages_[0-9]+_[0-9]+" n != null) (builtins.attrNames pkgs);
      version = n: builtins.tryEval pkgs.${n}.kernel.version;
    in
    map (r: r.value) (builtins.filter (r: r.success) (map version names))' | jq -r '.[]'
}

ref=$(jq -r .nodes.nixpkgs.original.ref flake.lock)
current=$(kernel "${hosts[0]}")
pinned=$(series "$current")
cutoff=$(date -u -d "-$min_days days" +%Y-%m-%dT%H:%M:%SZ)
read -r then_rev then_date < <(gh api "repos/NixOS/nixpkgs/activity?ref=refs/heads/$ref&activity_type=push&actor=nixos-channel-bot&per_page=100" \
  --jq "[.[] | select(.timestamp <= \"$cutoff\")][0] // empty | \"\(.after) \(.timestamp)\"") || true
if [ -z "${then_rev:-}" ]; then
  echo "::error::no $ref release $min_days days old among the channel's last 100"
  exit 1
fi
mapfile -t then_series < <(kernels "github:NixOS/nixpkgs/$then_rev" | cut -d. -f1-2)

# The newest series past the pinned one that qualifies.
target="" target_series=""
while read -r version; do
  s=$(series "$version")
  patch=$(cut -d. -f3 <<<"$version.0")
  [ "$s" != "$pinned" ] && [ "$(printf '%s\n%s\n' "$s" "$pinned" | sort -V | tail -n1)" = "$s" ] || continue
  [ "${patch%%[!0-9]*}" -ge "$min_patch" ] || continue
  printf '%s\n' "${then_series[@]}" | grep -qxF "$s" || continue
  target=$version target_series=$s
  break
done < <(kernels nixpkgs | sort -V -r)
echo "pinned: $current; channel release $min_days days old: ${then_rev:0:12} ($then_date); target: ${target:-none}"
if [ -z "$target" ]; then
  close_pr kernel-series "$branch" "Nothing to move to: no series newer than $pinned is at x.y.$min_patch in $ref and was in it $min_days days ago."
  exit 0
fi
old_pin=${pinned/./_} new_pin=${target_series/./_}

# move: the change, in the working tree.
declare -A before
move() {
  local files host
  for host in "${hosts[@]}"; do
    before[$host]=$(kernel "$host")
  done
  mapfile -t files < <(git grep -lw -e "linuxPackages_$old_pin" -e "linux_$old_pin" -- '*.nix')
  if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::no linuxPackages_$old_pin or linux_$old_pin in the .nix files: where is the kernel pinned?"
    exit 1
  fi
  sed -i -E "s/\blinuxPackages_$old_pin\b/linuxPackages_$new_pin/g; s/\blinux_$old_pin\b/linux_$new_pin/g" "${files[@]}"
  if [ "$(series "$(kernel "${hosts[0]}")")" != "$target_series" ]; then
    echo "::error::${hosts[0]} doesn't run $target_series after renaming the pin in ${files[*]}"
    exit 1
  fi
}
message=$(mktemp)
write_message() {
  local host
  {
    echo "kernel: $pinned -> $target_series (linuxPackages_$new_pin)"
    echo
    echo "Linux $target_series is at $target in $ref, and the channel already had it"
    echo "$min_days days ago (${then_rev:0:12}, $then_date). Release notes:"
    echo "https://kernelnewbies.org/Linux_$target_series"
    echo
    for host in "${hosts[@]}"; do
      echo "- $host: ${before[$host]} -> $(kernel "$host")"
    done
    echo
    if [ "$auto_merge" = true ]; then
      echo "This lands by itself once its check passes, and the reboot policy reboots in"
      echo "its window; a boot that fails comes back on the last good system."
    else
      echo "A person merges this. A new series doesn't reboot by itself while"
      echo "ethpandaops.reboot.holdKernelSeriesChange is on (the default): the admins"
      echo "reboot with reboot-at or reboot-now while someone can reach the console."
    fi
    echo
    echo "Update: kernel-series"
  } >"$message"
}

number=$(open_pr kernel-series "$branch")
if [ -n "$number" ] && git fetch -q origin refs/heads/kernel-series &&
  git grep -qw -e "linuxPackages_$new_pin" -e "linux_$new_pin" FETCH_HEAD -- '*.nix'; then
  head=$(git rev-parse FETCH_HEAD)
  if [ "$auto_merge" != true ]; then
    echo "pull request #$number already moves to $target_series; a person merges it"
    exit 0
  fi
  read -r status conclusion < <(gh api "repos/$GH_REPO/actions/workflows/check.yaml/runs?head_sha=$head&per_page=1" \
    --jq '.workflow_runs[0] // {} | "\(.status // "none") \(.conclusion // "none")"')
  case "$conclusion" in
  success)
    placeholders error
    move
    write_message
    build_hosts "${hosts[@]}"
    commit_as_bot "$message" -a
    land push "$branch" "$message"
    gh pr close "$number" --comment "Landed on $branch as $(git rev-parse HEAD) after check passed on ${head:0:12}."
    exit 0
    ;;
  none)
    if [ "$status" != none ]; then
      echo "pull request #$number's check is $status; it lands once that passes"
      exit 0
    fi
    ;;
  esac
  echo "pull request #$number's check ended $conclusion; proposing it again on $branch"
fi
move
write_message
commit_as_bot "$message" -a
cat "$message"
propose "$mode" "$branch" "$message" kernel-series
