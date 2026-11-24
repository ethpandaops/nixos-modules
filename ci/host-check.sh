# host-check --hosts "<host...>": what a host repo's check workflow runs on
# every push and pull request. The repo must configure exactly these hosts
# (everything in it is readable from each box, so it must never hold another
# server's configuration); REPLACE markers are a warning; then nix flake
# check builds every check, the hosts' systems included.
hosts=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --hosts)
    hosts=$2
    shift 2
    ;;
  *)
    echo "usage: host-check --hosts \"<host...>\"" >&2
    exit 2
    ;;
  esac
done

if [ -n "$hosts" ]; then
  want=$(printf '%s\n' "$hosts" | tr ' ' '\n' | awk NF | sort | jq -Rnc '[inputs]')
  have=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -c 'sort')
  if [ "$have" != "$want" ]; then
    echo "::error::nixosConfigurations must hold only $want, found $have"
    exit 1
  fi
fi
placeholders warn
nix flake check -L
