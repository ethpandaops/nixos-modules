# Shared by the drift scripts; not every script uses every variable.
# shellcheck disable=SC2034
STATE=/var/lib/nixhost-drift
# shellcheck disable=SC2034
MAX_SERIES=20 # at most this many series per finding, so a flood stays one alert

# label <value>: the value escaped for a Prometheus label.
label() {
  local v=${1//\\/\\\\}
  v=${v//\"/\\\"}
  printf '%s' "${v//$'\n'/\\n}"
}
