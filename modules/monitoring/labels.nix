# What a host is called in metrics, alerts and logs: its host name (the
# nixhost label), its fleet and its environment.
#
# The scraper sets the metric labels nixhost, fleet and environment itself
# (platform's nix-hosts-monitoring), so the box can't relabel its own series.
# The box states the same values in nixhost_info, under configured_* labels,
# so an alert can catch the two disagreeing, and puts them on its shipped logs
# (host.name, ethpandaops.fleet, deployment.environment).
{ config, lib, ... }:
let
  cfg = config.ethpandaops.host;
  name = lib.types.strMatching "[a-z0-9][a-z0-9-]*";
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.host = {
    fleet = lib.mkOption {
      type = name;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      example = "analytics";
      description = "The group of hosts this one belongs to, such as analytics. A one-off host is its own fleet, named after it.";
    };
    environment = lib.mkOption {
      type = name;
      example = "production";
      description = "The environment the host serves, such as production or staging. One fleet can span several.";
    };
  };

  config = {
    systemd.services.nixhost-info = {
      description = "Export the host's name, fleet and environment";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # The script embeds the values, so a change restarts the unit.
      script = ''
        ${config.ethpandaops.lib.shell}
        printf '%s\n' \
          "# HELP nixhost_info The host's name, fleet and environment as its configuration states them." \
          "# TYPE nixhost_info gauge" \
          'nixhost_info{configured_nixhost="${config.networking.hostName}",configured_fleet="${cfg.fleet}",configured_environment="${cfg.environment}"} 1' |
          write_metrics nixhost_info
      '';
    };
  };
}
