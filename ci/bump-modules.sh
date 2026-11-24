# bump-modules [--input nixos-modules] [--repo ethpandaops/nixos-modules]
#   [--min-age-hours 0] [--build "<host...>"] [--branch master]
#   [--mode push|pr]: move the input to the newest commit on the repo's
# default branch whose check run passed and that is at least --min-age-hours
# old; build the hosts, commit and land it (lib.sh), which starts check.
#
# nixos-modules' master only takes pull requests whose check (every VM test)
# passed. A fleet with staging takes it at once (--min-age-hours 0): its
# rollout runs staging first. A single host with no staging waits a day, so
# a bad commit can be reverted first.
input=nixos-modules repo=ethpandaops/nixos-modules min_age=0 build="" branch=master mode=push
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
  *)
    echo "usage: bump-modules [--input nixos-modules] [--repo ethpandaops/nixos-modules] [--min-age-hours 0] [--build \"<host...>\"] [--branch master] [--mode push|pr]" >&2
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
new_rev=""
while read -r sha committed; do
  [[ $committed < "$cutoff" || $committed == "$cutoff" ]] || continue
  if [ "$(gh api "repos/$repo/commits/$sha/check-runs?check_name=check" \
    --jq '[.check_runs[] | select(.conclusion == "success")] | length')" -gt 0 ]; then
    new_rev=$sha
    break
  fi
done < <(gh api "repos/$repo/commits?sha=$default&per_page=30" --jq '.[] | "\(.sha) \(.commit.committer.date)"')
if [ -z "$new_rev" ]; then
  echo "::warning::no commit on $repo $default with a passing check and $min_age hours old or more among its last 30"
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
nix flake lock --override-input "$input" "github:$repo/$new_rev"
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
