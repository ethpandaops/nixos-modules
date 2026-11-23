# Shared by the deploy scripts. SETTINGS is the module's JSON.
# shellcheck disable=SC2034 # not every script uses both
STATE_DIR=/var/lib/nixhost-deploy
# shellcheck disable=SC2034
RUN_DIR=/run/nixhost-deploy

# setting <jq path>: a value from SETTINGS; false and null read as empty.
setting() {
  jq -r "$1 // empty" "$SETTINGS"
}

# git_remote <args>: `git ls-remote <repository> <args>`, with the deploy key.
git_remote() {
  local key
  key=$(setting .deployKeyFile)
  if [ -n "$key" ]; then
    GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(setting .knownHostsFile) -o ConnectTimeout=15" \
      timeout 60 git ls-remote "$(setting .repository)" "$@"
  else
    timeout 60 git ls-remote "$(setting .repository)" "$@"
  fi
}

notify_admins() {
  "$NOTIFY" admins "$*" || true
}
