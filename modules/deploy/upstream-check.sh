# Is the remote branch ahead of what comin last deployed, and since when?
# Also reports how old the running nixpkgs and nixos-modules are.
now=$(date +%s)
deployed=""
deployed_at=0
if [ -r "$STATE_DIR/deployed.json" ]; then
  deployed=$(jq -r .sha "$STATE_DIR/deployed.json")
  deployed_at=$(jq -r .at "$STATE_DIR/deployed.json")
fi

check_ok=0
ahead=0
since_file=$STATE_DIR/upstream-ahead-since
if upstream=$(git_remote --exit-code "refs/heads/$(setting .branch)" | cut -f1) && [ -n "$upstream" ]; then
  check_ok=1
  if [ "$upstream" != "$deployed" ]; then
    ahead=1
    [ -s "$since_file" ] || echo "$now" >"$since_file"
  else
    rm -f "$since_file"
  fi
else
  echo "could not read the remote branch"
fi

{
  echo "# HELP nixhost_deploy_upstream_check_ok Whether the last read of the remote branch worked."
  echo "# TYPE nixhost_deploy_upstream_check_ok gauge"
  echo "nixhost_deploy_upstream_check_ok $check_ok"
  echo "# HELP nixhost_deploy_upstream_ahead Whether the remote branch differs from the deployed commit."
  echo "# TYPE nixhost_deploy_upstream_ahead gauge"
  echo "nixhost_deploy_upstream_ahead $ahead"
  if [ -s "$since_file" ]; then
    echo "# HELP nixhost_deploy_upstream_ahead_since_timestamp_seconds Since when the remote branch has been ahead."
    echo "# TYPE nixhost_deploy_upstream_ahead_since_timestamp_seconds gauge"
    echo "nixhost_deploy_upstream_ahead_since_timestamp_seconds $(cat "$since_file")"
  fi
  echo "# HELP nixhost_deploy_last_deployed_timestamp_seconds When comin last deployed successfully."
  echo "# TYPE nixhost_deploy_last_deployed_timestamp_seconds gauge"
  echo "nixhost_deploy_last_deployed_timestamp_seconds $deployed_at"
  # 26.05.20261121.94c3211 -> 2026-11-21
  if [[ "$(setting .nixosVersion)" =~ \.([0-9]{8})\. ]]; then
    echo "# HELP nixhost_nixpkgs_last_modified_timestamp_seconds Commit date of the running nixpkgs."
    echo "# TYPE nixhost_nixpkgs_last_modified_timestamp_seconds gauge"
    echo "nixhost_nixpkgs_last_modified_timestamp_seconds $(date -u -d "${BASH_REMATCH[1]}" +%s)"
  fi
  if [ -r /etc/nixhost/modules.json ]; then
    echo "# HELP nixhost_modules_last_modified_timestamp_seconds Commit date of the running nixos-modules."
    echo "# TYPE nixhost_modules_last_modified_timestamp_seconds gauge"
    echo "nixhost_modules_last_modified_timestamp_seconds $(jq -r .lastModified /etc/nixhost/modules.json)"
  fi
} | write_metrics nixhost_deploy
