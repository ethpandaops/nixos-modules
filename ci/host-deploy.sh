# host-deploy --host <host> --sha <commit> [--branch deploy]: build the host's
# system at the commit (the checkout) and fast-forward the deploy branch to
# it. comin on the box pulls that branch, so it only ever moves forward.
#
# Several runs may build side by side (no concurrency group: GitHub cancels a
# queued run when another queues, which could drop the newest commit). Each
# push is a fast-forward, so the newest commit wins and an older one finds
# the branch already past it.
host="" sha="" branch=deploy
while [ "$#" -gt 0 ]; do
  case "$1" in
  --host)
    host=$2
    shift 2
    ;;
  --sha)
    sha=$2
    shift 2
    ;;
  --branch)
    branch=$2
    shift 2
    ;;
  *)
    echo "usage: host-deploy --host <host> --sha <commit> [--branch deploy]" >&2
    exit 2
    ;;
  esac
done
if [ -z "$host" ] || [ -z "$sha" ]; then
  echo "host-deploy: --host and --sha are required" >&2
  exit 2
fi

placeholders error
build_hosts "$host"
for attempt in 1 2 3; do
  git fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" || true
  if git merge-base --is-ancestor "$sha" "origin/$branch" 2>/dev/null; then
    echo "$branch already contains $sha"
    exit 0
  fi
  if git push origin "$sha:refs/heads/$branch"; then
    exit 0
  fi
  echo "push $attempt rejected; looking again"
  sleep 10
done
echo "::error::$branch is neither behind nor ahead of $sha; was its source or $branch rewritten?"
exit 1
