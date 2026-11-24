# nixhost-notify [--severity critical|warning|info|ok] [--title <title>]
#   <admins|users|all> <message>
# SETTINGS (written by notify.nix) has the host's name, fleet and environment
# and the targets. Each notice posts under the host's name, as a Discord embed
# (or its Slack-compatible equivalent) coloured by severity, with the host,
# fleet, environment and severity as fields. Every notice is also logged to
# the journal; a failed delivery is logged and never fails the caller.
severity=info
title=Notice
while [ "$#" -gt 0 ]; do
  case "$1" in
  --severity)
    severity=$2
    shift 2
    ;;
  --title)
    title=$2
    shift 2
    ;;
  *) break ;;
  esac
done
if [ "$#" -lt 2 ]; then
  echo "usage: nixhost-notify [--severity critical|warning|info|ok] [--title <title>] <admins|users|all> <message>" >&2
  exit 2
fi
audience=$1
shift
message="$*"

case "$severity" in
critical) color=15548997 hex='#ED4245' priority=urgent tag=rotating_light ;;
warning) color=15770634 hex='#F0A30A' priority=high tag=warning ;;
ok) color=5763719 hex='#57F287' priority=default tag=white_check_mark ;;
info) color=5793266 hex='#5865F2' priority=default tag=information_source ;;
*)
  echo "nixhost-notify: unknown severity $severity" >&2
  exit 2
  ;;
esac
case "$audience" in
admins) filter='.admins[]' ;;
users) filter='.users[]' ;;
all) filter='.admins[], .users[]' ;;
*)
  echo "nixhost-notify: unknown audience $audience" >&2
  exit 2
  ;;
esac

host=$(jq -r .host "$SETTINGS")
logger -t nixhost-notify -- "($audience) [$host] $severity: $title: $message"

# Host, fleet, environment and severity, as Discord embed fields; the fleet
# and environment only where the monitoring module sets them.
fields=$(jq -c --arg severity "$severity" '
  [{name: "Host", value: .host}]
  + (if .fleet then [{name: "Fleet", value: .fleet}] else [] end)
  + (if .environment then [{name: "Environment", value: .environment}] else [] end)
  + [{name: "Severity", value: $severity}]
  | map(. + {inline: true})' "$SETTINGS")
now=$(date +%s)
# Discord's limits: 256 characters for a title, 4096 for a description.
title=${title:0:250}
message=${message:0:3900}

# discord: an embed. Mentions in the text never ping anyone.
embed() {
  jq -nc --arg username "$host" --arg title "$title" --arg text "$message" --argjson color "$color" \
    --argjson fields "$fields" --arg at "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" '
    {username: $username, allowed_mentions: {parse: []},
     embeds: [{title: $title, description: $text, color: $color, fields: $fields, timestamp: $at}]}'
}
# Discord's /slack endpoint and other Slack-compatible webhooks: an attachment.
attachment() {
  jq -nc --arg username "$host" --arg title "$title" --arg text "$message" --arg color "$hex" \
    --argjson fields "$fields" --argjson at "$now" '
    {username: $username,
     attachments: [{fallback: "\($username): \($title)", color: $color, title: $title, text: $text,
                    fields: ($fields | map({title: .name, value, short: .inline})), ts: $at}]}'
}

jq -c "$filter" "$SETTINGS" | while read -r t; do
  type=$(jq -r .type <<<"$t")
  url=$(jq -r '.url // empty' <<<"$t")
  file=$(jq -r '.urlFile // empty' <<<"$t")
  if [ -z "$url" ] && [ -n "$file" ]; then
    url=$(tr -d '[:space:]' <"$file" 2>/dev/null) || url=""
  fi
  if [ -z "$url" ]; then
    logger -t nixhost-notify -- "skipping a $type target with no URL"
    continue
  fi
  headers=(-H "Content-Type: application/json")
  case "$type" in
  discord)
    # A Discord webhook URL ending in /slack is its Slack-compatible endpoint.
    case "${url%%\?*}" in
    */slack) body=$(attachment) ;;
    *) body=$(embed) ;;
    esac
    ;;
  webhook) body=$(attachment) ;;
  ntfy)
    body=$message
    headers=(-H "Content-Type: text/plain" -H "Title: [$host] $title" -H "Priority: $priority" -H "Tags: $tag")
    ;;
  esac
  # On failure, log curl's error and the start of the reply, on one line.
  # The URL, often a secret, goes in on stdin rather than in the command
  # line, which any local user can read.
  response=$(mktemp)
  if ! error=$(printf 'url = "%s"\n' "${url//\"/%22}" | curl -sS --fail-with-body --max-time 15 --retry 3 --retry-delay 5 \
    -o "$response" "${headers[@]}" --data-binary "$body" --config - 2>&1); then
    reply=$(head -c 300 "$response")
    logger -t nixhost-notify -- "delivery to a $type target failed: ${error//$'\n'/ } ${reply//$'\n'/ }"
  fi
  rm -f "$response"
done
exit 0
