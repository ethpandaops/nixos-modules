# refresh-keys --host <host> [--branch master] [--mode push|pr]: refresh
# keys/<login>.keys from github.com/<login>.keys for the people already
# listed (never adding or removing anyone), build the host, commit and land
# it (lib.sh), which starts check. WEBHOOK (a Discord webhook, plain or
# ending in /slack) gets every change and problem; without it the run fails
# rather than change keys unannounced. RUN_URL links the notice to the run.
#
# keys/github-ids.json pins each login to its GitHub account ID, so a renamed
# account whose old name someone else registers doesn't hand them a login.
# A fetch that fails, returns lines that aren't SSH keys or returns no keys
# at all (as after someone deletes theirs) keeps the pinned keys and fails
# the run, for a person to decide.
host="" branch=master mode=push
while [ "$#" -gt 0 ]; do
  case "$1" in
  --host)
    host=$2
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
    echo "usage: refresh-keys --host <host> [--branch master] [--mode push|pr]" >&2
    exit 2
    ;;
  esac
done
if [ -z "$host" ]; then
  echo "refresh-keys: --host is required" >&2
  exit 2
fi
if [ -z "${WEBHOOK:-}" ]; then
  echo "::error::Set the KEYS_WEBHOOK secret: key changes aren't deployed without a notice."
  exit 1
fi
# A pull request lands nothing; a push to the branch deploys.
[ "$mode" = pr ] || placeholders error

work=$(mktemp -d)
: >"$work/changes"
: >"$work/problems"
fingerprints() { ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2, $NF}' || true; }
problem() {
  echo "::warning::$*"
  echo "$*" >>"$work/problems"
}
for file in keys/*.keys; do
  login=$(basename "$file" .keys)
  id=$(jq -r --arg login "$login" '.[$login] // empty' keys/github-ids.json)
  if [ -z "$id" ]; then
    problem "$login has no account ID in keys/github-ids.json; kept the pinned keys"
    continue
  fi
  if ! account=$(gh api "user/$id" --jq .login); then
    problem "could not look up GitHub account $id ($login); kept the pinned keys"
    continue
  fi
  # GitHub logins ignore case.
  if [ "${account,,}" != "${login,,}" ]; then
    problem "GitHub account $id is now $account, not $login; kept the pinned keys. Rename keys/$login.keys and its users.nix and github-ids.json entries by hand."
    continue
  fi
  if ! curl -fsS --max-time 30 "https://github.com/$account.keys" >"$file.new"; then
    problem "could not fetch github.com/$account.keys; kept the pinned keys"
    rm -f "$file.new"
    continue
  fi
  lines=$(grep -c . "$file.new" || true)
  valid=$(ssh-keygen -lf "$file.new" 2>/dev/null | wc -l || true)
  if [ "$lines" -eq 0 ]; then
    problem "$login has no keys on GitHub; kept the pinned keys. If that's a revocation, empty keys/$login.keys by hand."
    rm -f "$file.new"
    continue
  fi
  if [ "$valid" -ne "$lines" ]; then
    problem "github.com/$account.keys returned $lines lines but $valid SSH keys; kept the pinned keys"
    rm -f "$file.new"
    continue
  fi
  if cmp -s "$file" "$file.new"; then
    rm "$file.new"
    continue
  fi
  {
    echo "$login:"
    comm -13 <(sort "$file") <(sort "$file.new") | fingerprints | sed 's/^/  added /'
    comm -23 <(sort "$file") <(sort "$file.new") | fingerprints | sed 's/^/  removed /'
  } >>"$work/changes"
  mv "$file.new" "$file"
done

landed=""
if [ -s "$work/changes" ]; then
  cat "$work/changes"
  { echo "keys: refresh from GitHub"; echo; cat "$work/changes"; } >"$work/message"
  if build_hosts "$host" && git add keys && commit_as_bot "$work/message" &&
    land "$mode" "$branch" "$work/message" refresh-keys; then
    landed=1
  fi
fi

if [ -s "$work/changes" ] || [ -s "$work/problems" ]; then
  text=""
  if [ -s "$work/changes" ]; then
    if [ -n "$landed" ]; then
      if [ "$mode" = pr ]; then
        text+=$'Changed in a pull request; they deploy once a person lands it:\n'"$(cat "$work/changes")"$'\n'
      else
        text+=$'Changed; they deploy once check passes:\n'"$(cat "$work/changes")"$'\n'
      fi
    else
      text+=$'Changed on GitHub but not committed (the build or push failed):\n'"$(cat "$work/changes")"$'\n'
    fi
  fi
  if [ -s "$work/problems" ]; then
    title="SSH key refresh needs a person" color=15770634
    text+=$'Needs a person:\n'"$(cat "$work/problems")"
  else
    title="SSH keys changed" color=5793266
  fi
  echo "$title"
  echo "$text"
  post_notice "$WEBHOOK" "$title" "$text" "$color" "$host" "${RUN_URL:-}"
fi
if [ -s "$work/problems" ] || { [ -s "$work/changes" ] && [ -z "$landed" ]; }; then
  exit 1
fi
