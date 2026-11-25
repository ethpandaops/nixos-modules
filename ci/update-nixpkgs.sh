# update-nixpkgs [--build "<host...>"] [--min-age-hours 24] [--branch master]
#   [--mode push|pr] [--rev <commit> --fixes "<CVE...>"]: move nixpkgs to the
# newest release of its channel (the branch in flake.lock, such as
# nixos-26.05) published at least --min-age-hours ago, so a bad release can be
# pulled first; build the hosts, commit and land it (lib.sh), which starts
# check.
#
# A release's age is from when the channel bot pushed the branch (GitHub's
# activity API), which is when channels.nixos.org published it. Taking the
# newest release that is old enough, rather than only the tip, keeps a
# channel that moves every day from holding updates back.
#
# --rev and --fixes are cve-scan's security fast path: take that channel
# release however new it is, because it fixes those critical CVEs. The
# commit's trailers say so (Urgency: security, and Fixes: per CVE); a staged
# rollout reads them to shorten its waits, never to skip its canaries.
build="" min_age=24 branch=master mode=push rev="" fixes=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --build)
    build=$2
    shift 2
    ;;
  --min-age-hours)
    min_age=$2
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
  --rev)
    rev=$2
    shift 2
    ;;
  --fixes)
    fixes=$2
    shift 2
    ;;
  *)
    echo "usage: update-nixpkgs [--build \"<host...>\"] [--min-age-hours 24] [--branch master] [--mode push|pr] [--rev <commit> --fixes \"<CVE...>\"]" >&2
    exit 2
    ;;
  esac
done
read -r -a hosts <<<"$build"
if [ "${rev:+x}" != "${fixes:+x}" ]; then
  echo "--rev and --fixes go together: the fast path takes a release for the CVEs it fixes" >&2
  exit 2
fi

# A pull request lands nothing; a push to the branch deploys.
[ "$mode" = pr ] || placeholders error
kernel() {
  [ "${#hosts[@]}" -gt 0 ] || return 0
  nix eval --raw ".#nixosConfigurations.${hosts[0]}.config.boot.kernelPackages.kernel.version"
}
ref=$(jq -r .nodes.nixpkgs.original.ref flake.lock)
old_rev=$(jq -r .nodes.nixpkgs.locked.rev flake.lock)
old_modified=$(jq -r .nodes.nixpkgs.locked.lastModified flake.lock)
cutoff=$(date -u -d "-$min_age hours" +%Y-%m-%dT%H:%M:%SZ)
if [ -n "$rev" ]; then
  new_rev=$rev
else
  new_rev=$(gh api "repos/NixOS/nixpkgs/activity?ref=refs/heads/$ref&activity_type=push&per_page=30" \
    --jq "[.[] | select(.actor.login == \"nixos-channel-bot\" and .timestamp <= \"$cutoff\")][0].after // empty")
fi
if [ -z "$new_rev" ]; then
  echo "::error::no $ref release $min_age hours old or more among its last 30 pushes"
  exit 1
fi
if [ "$new_rev" = "$old_rev" ]; then
  echo "nixpkgs $ref ${old_rev:0:12} is the newest release $min_age hours old or more"
  exit 0
fi
old_kernel=$(kernel)
nix flake lock --override-input nixpkgs "github:NixOS/nixpkgs/$new_rev"
if [ "$(jq -r .nodes.nixpkgs.locked.lastModified flake.lock)" -le "$old_modified" ]; then
  echo "::notice::the locked nixpkgs ${old_rev:0:12} is newer than ${new_rev:0:12}; leaving it"
  git checkout -- flake.lock
  exit 0
fi
new_kernel=$(kernel)
message=$(mktemp)
{
  echo "flake.lock: nixpkgs $ref ${old_rev:0:12}..${new_rev:0:12}"
  echo
  echo "https://github.com/NixOS/nixpkgs/compare/$old_rev...$new_rev"
  if [ "$old_kernel" != "$new_kernel" ]; then
    echo "Kernel $old_kernel -> $new_kernel: the reboot policy takes it from here."
  fi
  if [ -n "$fixes" ]; then
    echo
    echo "Security: this release fixes critical CVEs the locked one has, so it's taken"
    echo "without waiting $min_age hours. A staged rollout still runs its canaries first."
  fi
  echo
  echo "Update: nixpkgs"
  if [ -n "$fixes" ]; then
    echo "Urgency: security"
    for cve in $fixes; do
      echo "Fixes: $cve"
    done
  fi
} >"$message"
cat "$message"
build_hosts "${hosts[@]}"
commit_as_bot "$message" flake.lock
land "$mode" "$branch" "$message" update-nixpkgs
