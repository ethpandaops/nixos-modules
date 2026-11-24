# Is the remote branch ahead of what comin last deployed, and since when?
# With a source branch (such as master), is it ahead of the deploy branch?
# Also reports how old the running nixpkgs and nixos-modules are.
now=$(date +%s)
deployed=""
deployed_at=0
if [ -r "$STATE_DIR/deployed.json" ]; then
  deployed=$(jq -r .sha "$STATE_DIR/deployed.json")
  deployed_at=$(jq -r .at "$STATE_DIR/deployed.json")
fi

branch=$(setting .branch)
source=$(setting .sourceBranch)
check_ok=0
ahead=0
since_file=$STATE_DIR/upstream-ahead-since
source_since_file=$STATE_DIR/source-ahead-since
refs=$(git_remote "refs/heads/$branch" ${source:+"refs/heads/$source"}) || refs=""
upstream=$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<<"$refs")
source_head=""
[ -z "$source" ] || source_head=$(awk -v ref="refs/heads/$source" '$2 == ref { print $1 }' <<<"$refs")
if [ -n "$upstream" ]; then
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

# The source branch differing from the deploy branch: commits that never
# reached it. Right after a push it differs for as long as CI takes.
source_ahead=""
if [ -n "$upstream" ] && [ -n "$source_head" ]; then
  if [ "$source_head" != "$upstream" ]; then
    source_ahead=1
    [ -s "$source_since_file" ] || echo "$now" >"$source_since_file"
  else
    source_ahead=0
    rm -f "$source_since_file"
  fi
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
  if [ -n "$source_ahead" ]; then
    echo "# HELP nixhost_deploy_source_ahead Whether the source branch ($source) differs from the deploy branch."
    echo "# TYPE nixhost_deploy_source_ahead gauge"
    echo "nixhost_deploy_source_ahead $source_ahead"
    if [ -s "$source_since_file" ]; then
      echo "# HELP nixhost_deploy_source_ahead_since_timestamp_seconds Since when the source branch has differed from the deploy branch."
      echo "# TYPE nixhost_deploy_source_ahead_since_timestamp_seconds gauge"
      echo "nixhost_deploy_source_ahead_since_timestamp_seconds $(cat "$source_since_file")"
    fi
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
