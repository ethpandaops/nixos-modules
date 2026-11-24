# nixhost-notify [--severity critical|warning|info|ok] [--title <title>]
# <admins|users|all> <message>: the one way the box tells people something
# (deploy rollbacks, reboot notices, RAID events). Each notice posts under the
# host's name as a Discord embed (or the Slack-compatible equivalent) coloured
# by severity, with the host, fleet and environment. Every message is also
# logged to the journal. Delivery failures are logged and never fail the
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
      # From the monitoring module (ethpandaops.host), when it's imported.
      fleet = config.ethpandaops.host.fleet or null;
      environment = config.ethpandaops.host.environment or null;
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
      SETTINGS=${settings}
      ${builtins.readFile ./notify.sh}
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
