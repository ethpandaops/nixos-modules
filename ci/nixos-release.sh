# nixos-release [--branch master] [--mode push|pr]: about a month after the
# next NixOS release is out (nixpkgs has its YY.MM tag), propose moving the
# repo to it (nixos-26.05 to nixos-26.11, say) as a pull request from the
# nixos-release branch, whose check shows whether every host builds. A person
# reads the release notes and merges it: a renamed option fails to build, but
# a service whose behaviour changed builds and then breaks at runtime, so it
# never merges itself.
#
# It renames the release in flake.nix's input URLs (nixos-YY.MM, and
# release-YY.MM for inputs such as home-manager that follow it) and locks
# them again; system.stateVersion stays. One release at a time.
branch=master mode=push
while [ "$#" -gt 0 ]; do
  case "$1" in
  --branch)
    branch=$2
    shift 2
    ;;
  --mode)
    mode=$2
    shift 2
    ;;
  *)
    echo "usage: nixos-release [--branch master] [--mode push|pr]" >&2
    exit 2
    ;;
  esac
done
min_days=30

ref=$(jq -r .nodes.nixpkgs.original.ref flake.lock)
if ! [[ $ref =~ ^nixos-([0-9]{2})\.(05|11)$ ]]; then
  echo "nixpkgs follows $ref, not a NixOS release; nothing to do"
  exit 0
fi
release=${ref#nixos-}
if [ "${BASH_REMATCH[2]}" = 05 ]; then
  next="${BASH_REMATCH[1]}.11"
else
  next="$(printf '%02d' $((10#${BASH_REMATCH[1]} + 1))).05"
fi
if ! object=$(gh api "repos/NixOS/nixpkgs/git/ref/tags/$next" --jq '"\(.object.type) \(.object.sha)"' 2>/dev/null); then
  echo "NixOS $next isn't out yet"
  exit 0
fi
read -r type sha <<<"$object"
if [ "$type" = tag ]; then
  released=$(gh api "repos/NixOS/nixpkgs/git/tags/$sha" --jq .tagger.date)
else
  released=$(gh api "repos/NixOS/nixpkgs/git/commits/$sha" --jq .committer.date)
fi
if [ "$(date -u -d "$released + $min_days days" +%s)" -gt "$(date -u +%s)" ]; then
  echo "NixOS $next came out on ${released:0:10}; proposing it from $(date -u -d "$released + $min_days days" +%Y-%m-%d)"
  exit 0
fi

number=$(open_pr nixos-release "$branch")
if [ -n "$number" ] && git fetch -q origin refs/heads/nixos-release &&
  [ "$(git show FETCH_HEAD:flake.lock | jq -r .nodes.nixpkgs.original.ref)" = "nixos-$next" ]; then
  echo "pull request #$number already moves to NixOS $next; close it for a fresh one"
  exit 0
fi

sed -i -E "s/\b(nixos|release)-${release//./[.]}\b/\1-$next/g" flake.nix
nix flake lock
if [ "$(jq -r .nodes.nixpkgs.original.ref flake.lock)" != "nixos-$next" ]; then
  echo "::error::flake.lock's nixpkgs doesn't follow nixos-$next after renaming $ref in flake.nix"
  exit 1
fi
message=$(mktemp)
{
  echo "flake: NixOS $release -> $next"
  echo
  echo "NixOS $next came out on ${released:0:10}. This moves flake.nix's inputs from"
  echo "the $release release to $next; check shows whether every host builds."
  echo
  echo "Read the release notes before merging, the incompatible changes above all:"
  echo "https://nixos.org/manual/nixos/stable/release-notes#sec-release-$next-incompatibilities"
  echo "A renamed or removed option fails to build, but a service whose behaviour"
  echo "changed builds and then breaks at runtime. system.stateVersion stays as it"
  echo "is. Once this lands, update-nixpkgs follows nixos-$next. It never merges"
  echo "itself."
  echo
  echo "Update: nixos-release"
} >"$message"
cat "$message"
commit_as_bot "$message" flake.nix flake.lock
propose "$mode" "$branch" "$message" nixos-release
