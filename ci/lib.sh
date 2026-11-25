# Shared by the host repo CI scripts (ci/*.sh). They run in a checkout of the
# host repo, from the reusable workflows in .github/workflows/host-*.yaml and
# friends, with the runner's nix and git, and GH_TOKEN and GH_REPO set.

# placeholders <warn|error>: REPLACE markers left in *.nix or .sops.yaml. The
# workflows whose push leads to a deploy refuse to run while one is left.
placeholders() {
  if git grep -n -e '# REPLACE' -- '*.nix' .sops.yaml; then
    if [ "$1" = error ]; then
      echo "::error::REPLACE markers are left"
      exit 1
    fi
    echo "::warning::REPLACE markers are left; the pushing workflows refuse to run until they're gone"
  fi
}

# build_hosts <host...>: build each host's system.
build_hosts() {
  local host
  for host in "$@"; do
    nix build -L --no-link ".#nixosConfigurations.$host.config.system.build.toplevel"
  done
}

# land <mode> <branch> <message file> [pr branch]: get the commit at HEAD to
# the branch and start its check run. Pushes made with GITHUB_TOKEN start no
# workflow, so check is started by dispatch. That run's completion fires no
# workflow_run either, so the caller's check.yaml deploys a dispatched run on
# master itself (host-check.yaml's header).
# - push pushes it to the branch: for a repo whose nodes deploy any commit.
# - pr pushes it to the pr branch and opens or updates a pull request that a
#   person lands as their own signed commit: for a repo whose nodes deploy
#   only commits signed by an allowed key, which neither this bot's commit
#   nor GitHub's merge button has.
land() {
  local mode=$1 branch=$2 message=$3 pr_branch=${4:-}
  case "$mode" in
  push)
    git push origin "HEAD:refs/heads/$branch"
    gh workflow run check.yaml --ref "$branch"
    ;;
  pr)
    propose pr "$branch" "$message" "$pr_branch"
    ;;
  *)
    echo "unknown mode $mode" >&2
    exit 2
    ;;
  esac
}

# propose <mode> <branch> <message file> <pr branch>: push the commit at HEAD
# to the pr branch, start its check, and open or update a pull request for it
# against the branch (the message's subject as title, the rest as body). For
# the jobs that only ever propose (kernel-series, nixos-release, cve-scan's
# whitelist), mode is the repo's: push means the merge button lands it, pr
# adds how to land it as your own signed commit. Either way the commit
# message, trailers included, is what lands.
#
# A repository can refuse GitHub Actions pull requests ("Allow GitHub Actions
# to create and approve pull requests" off). There an issue proposes the
# branch instead, with the same text, its check and how to land it; issues
# need no such setting.
propose() {
  local mode=$1 branch=$2 message=$3 pr_branch=$4 title open body out
  case "$mode" in
  push | pr) ;;
  *)
    echo "unknown mode $mode" >&2
    exit 2
    ;;
  esac
  git push --force origin "HEAD:refs/heads/$pr_branch"
  gh workflow run check.yaml --ref "$pr_branch"
  title=$(head -n1 "$message")
  open=$(proposal "$pr_branch" "$branch")
  body=$(mktemp)
  if [[ $open != issue* ]]; then
    proposal_body "$mode" "$branch" "$message" "$pr_branch" pr >"$body"
    if [ -n "$open" ]; then
      gh pr edit "${open##*#}" --title "$title" --body-file "$body"
      return
    fi
    if out=$(gh pr create --base "$branch" --head "$pr_branch" --title "$title" --body-file "$body" 2>&1); then
      echo "$out"
      return
    fi
    if [[ $out != *"not permitted to create or approve pull requests"* ]]; then
      echo "$out" >&2
      exit 1
    fi
    echo "::notice::GitHub Actions may not open pull requests in $GH_REPO, so an issue proposes $pr_branch"
  fi
  proposal_body "$mode" "$branch" "$message" "$pr_branch" issue >"$body"
  if [ -n "$open" ]; then
    gh issue edit "${open##*#}" --title "$title" --body-file "$body"
  else
    gh issue create --title "$title" --body-file "$body"
  fi
}

# proposal_body <mode> <branch> <message file> <pr branch> <pr|issue>: the
# text of the pull request or issue that proposes the pr branch.
proposal_body() {
  local mode=$1 branch=$2 message=$3 pr_branch=$4 kind=$5 server=${GITHUB_SERVER_URL:-https://github.com}
  if [ "$kind" = issue ]; then
    proposal_marker "$pr_branch" "$branch"
  fi
  tail -n +3 "$message"
  if [ "$kind" = issue ]; then
    echo
    echo "---"
    echo "The change is the branch \`$pr_branch\`; its check:"
    echo "$server/$GH_REPO/actions/workflows/check.yaml?query=branch%3A$pr_branch"
    if [ "$mode" = push ]; then
      echo
      echo "Land it once check passes: open a pull request from"
      echo "$server/$GH_REPO/compare/$branch...$pr_branch?expand=1 and merge it, or"
      echo
      echo "    git fetch origin $pr_branch && git switch $branch && git pull --ff-only"
      echo "    git cherry-pick FETCH_HEAD"
      echo "    git push origin $branch"
      echo
      echo "Keep the commit message: its trailers tell a staged rollout what the change is."
      echo "The next run closes this issue once there's nothing left to propose."
    fi
  fi
  if [ "$mode" = pr ]; then
    echo
    [ "$kind" = issue ] || echo "---"
    echo "Land this as your own signed commit, not with the merge button: nodes that"
    echo "deploy only signed commits refuse this bot's commit and GitHub's merge."
    echo
    echo "    git fetch origin $pr_branch && git switch $branch && git pull --ff-only"
    echo "    git cherry-pick -S FETCH_HEAD"
    echo "    git push origin $branch"
    echo
    echo "Then close this $([ "$kind" = issue ] && echo issue || echo "pull request"); the next run opens a new one when there's more."
  fi
}

# proposal_marker <pr branch> <branch>: the line that marks the issue
# proposing the pr branch (an HTML comment, hidden on GitHub).
proposal_marker() {
  echo "<!-- proposal: $1 -> $2 -->"
}

# proposal <pr branch> <branch>: the open pull request from the pr branch into
# the branch ("pull request #12"), or else the open issue that proposes it
# ("issue #12"), or nothing.
proposal() {
  local number
  number=$(gh pr list --head "$1" --base "$2" --state open --json number --jq '.[0].number // empty')
  if [ -n "$number" ]; then
    echo "pull request #$number"
    return
  fi
  number=$(gh api "repos/$GH_REPO/issues?state=open&creator=github-actions%5Bbot%5D&per_page=100" \
    --jq "[.[] | select(.pull_request == null and (.body // \"\" | contains(\"$(proposal_marker "$1" "$2")\")))][0].number // empty")
  [ -z "$number" ] || echo "issue #$number"
}

# close_proposal <pr branch> <branch> <comment>: close the pull request or
# issue that proposes the pr branch, if one is open.
close_proposal() {
  local open
  open=$(proposal "$1" "$2")
  case "$open" in
  "pull request #"*) gh pr close "${open##*#}" --comment "$3" ;;
  "issue #"*) gh issue close "${open##*#}" --comment "$3" ;;
  esac
}

# commit_as_bot <message file> [paths...]: commit as github-actions[bot].
commit_as_bot() {
  local message=$1
  shift
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -F "$message" "$@"
}

# post_notice <webhook url> <title> <text> <colour> <host> [run url]: a Discord
# embed (a Slack attachment for a URL ending in /slack) posted under the
# host's name, like nixhost-notify's. The URL goes in on stdin.
post_notice() {
  local url=$1 title=$2 text=$3 color=$4 host=$5 run=${6:-} fields body hex
  hex=$(printf '#%06X' "$color")
  fields=$(jq -nc --arg host "$host" --arg run "$run" \
    '[{name: "Host", value: $host, inline: true}] + (if $run == "" then [] else [{name: "Run", value: "[GitHub Actions](\($run))", inline: true}] end)')
  if [[ "${url%%\?*}" == */slack ]]; then
    body=$(jq -nc --arg host "$host" --arg title "$title" --arg text "${text:0:3900}" --arg color "$hex" --argjson fields "$fields" \
      '{username: $host, attachments: [{fallback: "\($host): \($title)", color: $color, title: $title, text: $text,
        fields: ($fields | map({title: .name, value, short: .inline}))}]}')
  else
    body=$(jq -nc --arg host "$host" --arg title "$title" --arg text "${text:0:3900}" --argjson color "$color" --argjson fields "$fields" \
      '{username: $host, allowed_mentions: {parse: []}, embeds: [{title: $title, description: $text, color: $color, fields: $fields}]}')
  fi
  printf 'url = "%s"\n' "${url//\"/%22}" |
    curl -fsS -H "Content-Type: application/json" --data-binary "$body" --config -
}
