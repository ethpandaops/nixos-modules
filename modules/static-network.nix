# Static addressing for a server's uplink with systemd-networkd. The NIC is
# matched by MAC, so a renamed interface keeps its network. IPv4 is a /32
# with the gateway as point-to-point peer, which works whether or not the
# gateway is in the address's subnet. IPv6 is optional.
{ config, lib, ... }:
let
  cfg = config.ethpandaops.network;
in
{
  options.ethpandaops.network = {
    mac = lib.mkOption {
      type = lib.types.strMatching "([0-9a-f]{2}:){5}[0-9a-f]{2}";
      description = "MAC address of the uplink NIC, lower case.";
    };
    ipv4 = {
      address = lib.mkOption {
        type = lib.types.str;
        example = "192.0.2.10";
        description = "The IPv4 address, without a prefix.";
      };
      gateway = lib.mkOption {
        type = lib.types.str;
        example = "192.0.2.1";
      };
    };
    ipv6 = {
      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "2001:db8::2/64";
        description = "An IPv6 address with its prefix, or null for none.";
      };
      gateway = lib.mkOption {
        type = lib.types.str;
        default = "fe80::1";
      };
    };
  };

  config = {
    networking.useNetworkd = true;
    networking.useDHCP = false;

    systemd.network.networks."10-uplink" = {
      matchConfig.MACAddress = cfg.mac;
      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = false;
      };
      addresses = [
        {
          Address = "${cfg.ipv4.address}/32";
          Peer = "${cfg.ipv4.gateway}/32";
        }
      ]
      ++ lib.optional (cfg.ipv6.address != null) { Address = cfg.ipv6.address; };
      routes = [
        { Gateway = cfg.ipv4.gateway; }
      ]
      ++ lib.optional (cfg.ipv6.address != null) { Gateway = cfg.ipv6.gateway; };
      linkConfig.RequiredForOnline = "routable";
    };

    assertions = [
      {
        assertion = config.networking.nameservers != [ ];
        message = "ethpandaops.network gets no DNS servers from DHCP; set networking.nameservers.";
      }
    ];
  };
}
