# bump-modules [--input nixos-modules] [--repo ethpandaops/nixos-modules]
#   [--min-age-hours 0] [--build "<host...>"] [--branch master]
#   [--mode push|pr] [--after <owner/repo>]: move the input to the newest
# commit on the repo's default branch whose check run passed and that is at
# least --min-age-hours old; build the hosts, commit and land it (lib.sh),
# which starts check.
#
# nixos-modules' master only takes pull requests whose check (every VM test)
# passed. A fleet with staging takes it at once (--min-age-hours 0): its
# rollout runs staging first. A single host with no staging waits a day, so
# a bad commit can be reverted first.
#
# --after: take only commits a fleet with a staged rollout has already run.
# The newest commit is bounded by the input's revision at the last commit
# that fleet's first environment converged on (rollout-state's staging.json,
# `staged`), and, when the bump needs a reboot here (the kernel, initrd,
# systemd, kernel parameters, boot-time modules, an inhibitor or the NixOS
# release change in a built host's fingerprint), at the last commit its
# second environment's canaries settled on (production.json,
# `canariesSettled`). AFTER_TOKEN reads that repo. Until that fleet has a
# rollout state at all (no host of it runs its rollout yet), nothing is gated.
input=nixos-modules repo=ethpandaops/nixos-modules min_age=0 build="" branch=master mode=push after=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --input)
    input=$2
    shift 2
    ;;
  --repo)
    repo=$2
    shift 2
    ;;
  --min-age-hours)
    min_age=$2
    shift 2
    ;;
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
  --after)
    after=$2
    shift 2
    ;;
  *)
    echo "usage: bump-modules [--input nixos-modules] [--repo ethpandaops/nixos-modules] [--min-age-hours 0] [--build \"<host...>\"] [--branch master] [--mode push|pr] [--after <owner/repo>]" >&2
    exit 2
    ;;
  esac
done
read -r -a hosts <<<"$build"

# A pull request lands nothing; a push to the branch deploys.
[ "$mode" = pr ] || placeholders error
old_rev=$(jq -r --arg input "$input" '.nodes[.nodes.root.inputs[$input]].locked.rev' flake.lock)
old_modified=$(jq -r --arg input "$input" '.nodes[.nodes.root.inputs[$input]].locked.lastModified' flake.lock)
cutoff=$(date -u -d "-$min_age hours" +%Y-%m-%dT%H:%M:%SZ)
default=$(gh api "repos/$repo" --jq .default_branch)

# gate_rev <env> <jq path>: the input's revision at the commit the --after
# repo's rollout-state names, or nothing.
gate_rev() {
  local state commit
  state=$(GH_TOKEN=${AFTER_TOKEN:-} gh api "repos/$after/contents/$1.json?ref=rollout-state" --jq .content 2>/dev/null | base64 -d) || return 0
  commit=$(jq -r "$2 // empty" <<<"$state")
  [ -n "$commit" ] || return 0
  GH_TOKEN=${AFTER_TOKEN:-} gh api "repos/$after/contents/flake.lock?ref=$commit" --jq .content | base64 -d |
    jq -r --arg input "$input" '.nodes[.nodes.root.inputs[$input]].locked.rev // empty'
}

# pick [bound]: the newest commit old enough with a passing check, at or
# before bound when one is given.
pick() {
  local sha committed
  while read -r sha committed; do
    [[ $committed < "$cutoff" || $committed == "$cutoff" ]] || continue
    if [ -n "${1:-}" ] && ! [[ "$(gh api "repos/$repo/compare/$sha...$1" --jq .status)" =~ ^(identical|ahead)$ ]]; then
      continue
    fi
    if [ "$(gh api "repos/$repo/commits/$sha/check-runs?check_name=check" \
      --jq '[.check_runs[] | select(.conclusion == "success")] | length')" -gt 0 ]; then
      echo "$sha"
      return
    fi
  done < <(gh api "repos/$repo/commits?sha=$default&until=$cutoff&per_page=30" --jq '.[] | "\(.sha) \(.commit.committer.date)"')
}

# reboot_fields: the parts of the built hosts' fingerprints a reboot applies.
reboot_fields() {
  local host
  for host in "${hosts[@]}"; do
    nix eval --json ".#nixosConfigurations.$host.config.ethpandaops.fingerprint" |
      jq -c '{kernel, initrd, systemd, kernelParams, kernelModules, inhibitors, kernelVersion, nixosRelease}'
  done
}

staged="" canaries=""
# GitHub answers 404 for a private repo the token can't read, so see the
# repo first: a token that can't fails the run instead of lifting the gate.
if [ -n "$after" ] && ! GH_TOKEN=${AFTER_TOKEN:-} gh api "repos/$after" --silent; then
  echo "::error::AFTER_TOKEN can't read $after"
  exit 1
fi
if [ -n "$after" ] && ! probe=$(GH_TOKEN=${AFTER_TOKEN:-} gh api "repos/$after/contents/staging.json?ref=rollout-state" --silent 2>&1); then
  if [[ $probe != *"HTTP 404"* ]]; then
    echo "::error::can't read $after's rollout state: $probe"
    exit 1
  fi
  echo "::notice::$after has no rollout state yet, so nothing waits for it"
  after=""
fi
if [ -n "$after" ]; then
  staged=$(gate_rev staging '.staged[-1].commit')
  canaries=$(gate_rev production '.canariesSettled[-1].commit')
  if [ -z "$staged" ]; then
    echo "::notice::$after hasn't converged on a $input revision in staging yet; nothing to take"
    exit 0
  fi
  echo "$after staging ran $input ${staged:0:12}; its production canaries ${canaries:0:12}"
fi
new_rev=$(pick "$staged")
if [ -z "$new_rev" ]; then
  echo "::warning::no commit on $repo $default with a passing check among the last 30 that are $min_age hours old or more${staged:+ and that $after staging ran}"
  exit 0
fi
if [ "$new_rev" = "$old_rev" ]; then
  echo "$input ${old_rev:0:12} is the newest $repo commit with a passing check and $min_age hours old or more"
  exit 0
fi
if [ "$mode" = pr ] && git fetch -q origin "refs/heads/bump-$input" 2>/dev/null &&
  [ "$(git show FETCH_HEAD:flake.lock | jq -r --arg input "$input" '.nodes[.nodes.root.inputs[$input]].locked.rev')" = "$new_rev" ]; then
  echo "the bump-$input pull request already has ${new_rev:0:12}"
  exit 0
fi
before=""
[ -z "$after" ] || before=$(reboot_fields)
nix flake lock --override-input "$input" "github:$repo/$new_rev"
if [ -n "$after" ] && [ "$(reboot_fields)" != "$before" ] &&
  ! [[ -n "$canaries" && "$(gh api "repos/$repo/compare/$new_rev...$canaries" --jq .status)" =~ ^(identical|ahead)$ ]]; then
  git checkout -- flake.lock
  new_rev=$(pick "$canaries")
  if [ -z "$canaries" ] || [ -z "$new_rev" ] || [ "$new_rev" = "$old_rev" ]; then
    echo "::notice::the bump needs a reboot here, and $after's production canaries haven't run a newer $input yet"
    exit 0
  fi
  echo "the newest $input needs a reboot here; taking ${new_rev:0:12}, which $after's production canaries ran"
  nix flake lock --override-input "$input" "github:$repo/$new_rev"
fi
if [ "$(jq -r --arg input "$input" '.nodes[.nodes.root.inputs[$input]].locked.lastModified' flake.lock)" -le "$old_modified" ]; then
  echo "::notice::the locked $input ${old_rev:0:12} is newer than ${new_rev:0:12}; leaving it"
  git checkout -- flake.lock
  exit 0
fi
message=$(mktemp)
{
  echo "flake.lock: $input ${old_rev:0:12}..${new_rev:0:12}"
  echo
  echo "https://github.com/$repo/compare/$old_rev...$new_rev"
  echo
  gh api "repos/$repo/compare/$old_rev...$new_rev" --jq '.commits[] | "- \(.commit.message | split("\n")[0])"'
} >"$message"
cat "$message"
build_hosts "${hosts[@]}"
commit_as_bot "$message" flake.lock
land "$mode" "$branch" "$message" "bump-$input"
