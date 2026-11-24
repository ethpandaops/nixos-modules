# nixhost-notify <admins|users|all> <message>: the one way the box tells people
# something (deploy rollbacks, reboot notices, RAID events). Every message is
# also logged to the journal. Delivery failures are logged and never fail the
# caller.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.notify;
  target = import ./notify-target.nix { inherit lib; };

  settings = pkgs.writeText "nixhost-notify.json" (
    builtins.toJSON {
      host = config.networking.hostName;
      admins = cfg.admins;
      users = lib.concatLists (
        lib.mapAttrsToList (name: user: map (t: t // { user = name; }) user.notify) config.ethpandaops.users
      );
    }
  );

  package = pkgs.writeShellApplication {
    name = "nixhost-notify";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      util-linux
    ];
    text = ''
      settings=${settings}
      if [ "$#" -lt 2 ]; then
        echo "usage: nixhost-notify <admins|users|all> <message>" >&2
        exit 2
      fi
      audience=$1
      shift
      host=$(jq -r .host "$settings")
      message="[$host] $*"
      logger -t nixhost-notify -- "($audience) $message"

      case "$audience" in
        admins) filter='.admins[]' ;;
        users) filter='.users[]' ;;
        all) filter='.admins[], .users[]' ;;
        *)
          echo "nixhost-notify: unknown audience $audience" >&2
          exit 2
          ;;
      esac

      jq -c "$filter" "$settings" | while read -r t; do
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
        case "$type" in
          discord)
            # A Discord webhook URL ending in /slack is its Slack-compatible endpoint.
            field=content
            case "''${url%%\?*}" in */slack) field=text ;; esac
            body=$(jq -nc --arg m "''${message:0:1900}" --arg f "$field" '{($f): $m}')
            ctype=application/json
            ;;
          webhook) body=$(jq -nc --arg m "$message" '{text: $m}'); ctype=application/json ;;
          ntfy) body=$message; ctype=text/plain ;;
        esac
        # On failure, log curl's error and the start of the reply, on one line.
        # The URL, often a secret, goes in on stdin rather than in the
        # command line, which any local user can read.
        response=$(mktemp)
        if ! error=$(printf 'url = "%s"\n' "''${url//\"/%22}" | curl -sS --fail-with-body --max-time 15 --retry 3 --retry-delay 5 \
          -o "$response" -H "Content-Type: $ctype" --data-binary "$body" --config - 2>&1); then
          reply=$(head -c 300 "$response")
          logger -t nixhost-notify -- "delivery to a $type target failed: ''${error//$'\n'/ } ''${reply//$'\n'/ }"
        fi
        rm -f "$response"
      done
      exit 0
    '';
  };
in
{
  imports = [ ./users.nix ];

  options.ethpandaops.notify = {
    admins = lib.mkOption {
      type = lib.types.listOf target;
      default = [ ];
      description = "Where admin notices go.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = package;
      description = "The nixhost-notify command, for other modules to call.";
    };
  };

  config = {
    assertions = map (t: {
      assertion = (t.url == null) != (t.urlFile == null);
      message = "ethpandaops.notify: set exactly one of url and urlFile on every target.";
    }) (cfg.admins ++ lib.concatMap (u: u.notify) (lib.attrValues config.ethpandaops.users));
    environment.systemPackages = [ package ];
  };
}
