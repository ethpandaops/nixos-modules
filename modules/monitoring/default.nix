# node-exporter (with the systemd and textfile collectors, which carry every
# nixhost_* metric) and comin's exporter, reachable only over the tailnet
# interface. The box joins the tailnet with a single-use tagged auth key, so
# whatever scrapes it labels the series; nothing here names the box.
{
  config,
  lib,
  ...
}:
let
  cfg = config.ethpandaops.monitoring;
  ts = cfg.tailscale;
in
{
  imports = [
    ../metrics.nix
    ./drift.nix
    ./kernel.nix
    ./labels.nix
    ./logs.nix
    ./vulnix.nix
  ];

  options.ethpandaops.monitoring = {
    nodeExporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9100;
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "The only interface the exporter ports are open on.";
    };
    tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Join the tailnet the metrics are scraped over.";
      };
      loginServer = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://headscale.example.org";
        description = "The control server URL, such as a Headscale instance. Null uses Tailscale's own.";
      };
      authKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression "config.sops.secrets.tailscale-authkey.path";
        description = "A single-use, tagged auth key, used on first start.";
      };
      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "tag:server" ];
        description = "Tags to advertise, if the auth key doesn't carry them. Give the tag no outgoing access in the tailnet policy.";
      };
    };
  };

  config = {
    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.nodeExporterPort;
      openFirewall = false;
      enabledCollectors = [
        "systemd"
        "textfile"
      ];
      extraFlags = [ "--collector.textfile.directory=${config.ethpandaops.metrics.textfileDir}" ];
    };

    # comin's exporter (from the deploy module) listens everywhere; only this
    # interface lets it through.
    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [
      cfg.nodeExporterPort
    ]
    ++ lib.optional (config.services.comin.enable or false) config.services.comin.exporter.port;

    services.tailscale = lib.mkIf ts.enable {
      enable = true;
      interfaceName = cfg.interface;
      # UDP 41641 for direct connections; Tailscale relays without it.
      openFirewall = true;
      inherit (ts) authKeyFile;
      extraUpFlags = [
        # The box needs no tailnet DNS or routes; it only answers scrapes.
        "--accept-dns=false"
        "--accept-routes=false"
      ]
      ++ lib.optional (ts.loginServer != null) "--login-server=${ts.loginServer}"
      ++ lib.optional (ts.tags != [ ]) "--advertise-tags=${lib.concatStringsSep "," ts.tags}";
    };
  };
}
