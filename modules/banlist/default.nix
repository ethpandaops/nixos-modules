# The fleet ban list: drop new connections from sources a central scorer (or
# a person) put on a signed list, on every host that pulls it, within a
# minute, until each entry expires.
#
# - nixhost-banlist-sets (before the firewall, early in boot) creates the
#   ipsets and the nixos-ban chain, first in the mangle table's PREROUTING
#   (so a restart puts the rules back as they were, and drift stays quiet):
#     lo, then the allow sets: RETURN (the allow list always wins)
#     new connections from nixhost-shadow{4,6}-v1: counted, not dropped
#     new connections from nixhost-ban{4,6}-v1: DROP
#   The chain isn't part of firewall.service, so nothing here can make a
#   firewall reload fail. If the kernel can't create the sets or rules (with
#   security.lockKernelModules, ip_set_hash_net loads only at the next boot),
#   the unit sets up nothing, says so, and exits 0; the box keeps its
#   firewall and drops nothing. Set names carry a version (-v1), so a
#   later change to their type gets new names instead of colliding.
# - nixhost-banlist-pull fetches the list every `interval` seconds, over IPv4
#   and IPv6 in turn on a dual-stack host (so the publisher sees both its
#   addresses), and loads it only if: ssh-keygen -Y verify accepts its
#   signature by one of publicKeys (namespace nixhost-banlist); it's version
#   1, generated within the last 10 minutes and not more than 5 minutes ahead;
#   its generation is at most 2^53, at most a day ahead of its signing time,
#   and not older than one this host loaded from the same key (kept across
#   reboots, per key, so switching to the standby key recovers from a
#   generation pushed ahead under the other); no entry is wider than /24
#   (IPv4) or /48 (IPv6); it has at most 5000 entries and covers at most 2^20
#   IPv4 addresses and 2^20 IPv6 /64s; and, when it follows the generation
#   this host has loaded, it adds at most 500 entries (not checked on the
#   puller's first load, or when nothing is dropped). Otherwise it keeps what
#   it has. Each entry's ipset timeout is its expiry, so a host that can't
#   reach the list stops blocking on its own as entries expire. A list in mode
#   "shadow", or a host in mode shadow, fills the shadow sets; a list in mode
#   "empty" empties both.
#
# Nothing here names a host, address or range of ours: the list's URL and
# credentials default to the host's log shipping ones (monitoring.logs). Our
# own addresses belong in the publisher's allow list, so they never reach
# the list; hosts only always allow the generic ranges in `allow`, and
# whatever an optional allowFile adds.
#
# Break-glass on one box: `systemctl stop nixhost-banlist-sets.service`
# takes the chain out at once (and stops the puller); drift reports the
# missing rules until it's started again or the box reboots. To leave the
# rules in place but block nothing: `systemctl stop nixhost-banlist-pull`,
# then `ipset flush nixhost-ban4-v1; ipset flush nixhost-ban6-v1`. To keep
# it off, commit `ethpandaops.banlist.mode = "off"`. Fleet-wide, empty the
# list at its source.
#
# Metrics (nixhost_banlist.prom): nixhost_banlist_info{mode,list_mode,
# effective,key} (key: the fingerprint that signed the loaded list),
# nixhost_banlist_ready (the chain is in place), _generation,
# _generated_timestamp_seconds, _last_success_timestamp_seconds,
# _entries{family,set}, _rejected_total{reason} and
# _matched_packets_total{family,set} (new-connection packets each set
# matched; set="shadow" is what enforcing would have dropped).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.banlist;
  logs = config.ethpandaops.monitoring.logs or { enable = false; };
  ipv6 = config.networking.enableIPv6;

  # Fully matched (builtins.match). An address without a prefix is one host.
  v4 = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}(/([0-9]|[12][0-9]|3[0-2]))?";
  # Loosely: ipset rejects a malformed address, and then sets up nothing.
  v6 = "[0-9a-fA-F:.]*:[0-9a-fA-F:.]*(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?";

  fileLines =
    file:
    lib.filter (l: l != "") (
      map (l: lib.trim (lib.head (lib.splitString "#" l))) (lib.splitString "\n" (builtins.readFile file))
    );
  allow = cfg.allow ++ lib.optionals (cfg.allowFile != null) (fileLines cfg.allowFile);
  allow4 = lib.filter (a: builtins.match v4 a != null) allow;
  allow6 = lib.filter (a: builtins.match v6 a != null) allow;
  invalid = lib.filter (a: builtins.match v4 a == null && builtins.match v6 a == null) allow;

  signers = pkgs.writeText "nixhost-banlist-signers" (
    lib.concatMapStrings (k: ''
      nixhost-banlist namespaces="nixhost-banlist" ${k}
    '') cfg.publicKeys
  );

  iptables = config.networking.firewall.package;

  sets = pkgs.writeShellApplication {
    name = "nixhost-banlist-sets";
    runtimeInputs = [
      pkgs.gnused
      pkgs.ipset
      iptables
    ];
    text = ''
      ALLOW4=${pkgs.writeText "nixhost-banlist-allow4" (lib.concatLines allow4)}
      ALLOW6=${pkgs.writeText "nixhost-banlist-allow6" (lib.concatLines allow6)}
      IPV6=${if ipv6 then "1" else ""}
      ${builtins.readFile ./sets.sh}
    '';
  };

  pull = pkgs.writeShellApplication {
    name = "nixhost-banlist-pull";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      diffutils
      gawk
      iptables
      ipset
      jq
      openssh
    ];
    text = ''
      VALIDATE=${./validate.jq}
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./pull.sh}
    '';
  };
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.banlist = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "off"
        "shadow"
        "enforce"
      ];
      default = "off";
      description = ''
        off: nothing (the default).
        shadow: load the list and count what it matches, but drop nothing.
        enforce: drop new connections from the list's sources, unless the
        list itself is in shadow mode. With security.lockKernelModules,
        turning it on needs a reboot (ip_set_hash_net loads at boot), which
        reboot-detect reports.
      '';
    };
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if logs.enable then "${lib.removeSuffix "/" logs.endpoint}/banlist/v1" else null;
      defaultText = lib.literalExpression ''"''${config.ethpandaops.monitoring.logs.endpoint}/banlist/v1"'';
      description = "Where the signed list is, fetched with basic auth.";
    };
    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if logs.enable then logs.user else null;
      defaultText = lib.literalExpression "config.ethpandaops.monitoring.logs.user";
      description = "The basic auth user.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if logs.enable then logs.passwordFile else null;
      defaultText = lib.literalExpression "config.ethpandaops.monitoring.logs.passwordFile";
      description = "A file holding the basic auth password.";
    };
    publicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGkPzuHMvZeH/FTawSYfiPv/4hTBSpy0279V0zXh8xdH nixhost-banlist"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgrKryEmCcI6FvMIwiLF53OobqY+HTCgS3CGfhB4Cj3 nixhost-banlist-standby"
      ];
      description = ''
        The keys the list may be signed with (ssh-keygen -Y sign -n
        nixhost-banlist): the active key and a standby, whose private half
        is kept apart. To rotate: sign with the standby (hosts accept it
        already, and its replay floor is its own), pin a new standby, let
        every host pick it up, then remove the old key.
      '';
    };
    allow = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # Private, CGNAT (the tailnet), loopback and link-local: never a
        # scanner on the internet, and often our own traffic.
        "10.0.0.0/8"
        "100.64.0.0/10"
        "127.0.0.0/8"
        "169.254.0.0/16"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "::1/128"
        "fc00::/7"
        "fe80::/10"
      ];
      description = "Sources the list never blocks, whatever it says, besides allowFile's.";
    };
    allowFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./banlist-allow.txt";
      description = ''
        Optional: more sources the list never blocks, from a file in the
        host's own repo, an address or CIDR per line, # comments. They win
        over the list even if the publisher's own allow list misses them.
      '';
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Seconds between fetches.";
    };
  };

  config = lib.mkMerge [
    # Mode off leaves no metrics behind from when it was on.
    (lib.mkIf (cfg.mode == "off") {
      systemd.tmpfiles.rules = [ "r ${config.ethpandaops.metrics.textfileDir}/nixhost_banlist.prom" ];
    })

    (lib.mkIf (cfg.mode != "off") {
      assertions = [
        {
          assertion = cfg.url != null && cfg.user != null && cfg.passwordFile != null;
          message = "ethpandaops.banlist needs url, user and passwordFile (by default monitoring.logs').";
        }
        {
          assertion = cfg.publicKeys != [ ];
          message = "ethpandaops.banlist.publicKeys is empty: no list could be verified.";
        }
        {
          assertion = invalid == [ ];
          message = "ethpandaops.banlist: not an address or CIDR: ${lib.concatStringsSep ", " invalid}";
        }
        {
          assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
          message = "ethpandaops.banlist needs the NixOS iptables firewall.";
        }
      ];

      # Loaded at boot, so they're there under security.lockKernelModules.
      boot.kernelModules = [
        "ip_set"
        "ip_set_hash_net"
        "xt_set"
      ];

      environment.systemPackages = [ pkgs.ipset ];

      systemd.services.nixhost-banlist-sets = {
        description = "Fleet ban list: ipsets and the nixos-ban chain";
        wantedBy = [ "sysinit.target" ];
        wants = [ "network-pre.target" ];
        after = [ "systemd-modules-load.service" ];
        before = [
          "network-pre.target"
          "firewall.service"
          "shutdown.target"
        ];
        conflicts = [ "shutdown.target" ];
        unitConfig.DefaultDependencies = false;
        # Restarted, not stopped and started, on a change, so the puller
        # (PartOf) restarts with it.
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe sets} start";
          ExecStop = "${lib.getExe sets} stop";
        };
      };

      systemd.services.nixhost-banlist-pull = {
        description = "Fleet ban list: fetch, check and load the signed list";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "nixhost-banlist-sets.service"
        ];
        after = [
          "network-online.target"
          "nixhost-banlist-sets.service"
        ];
        partOf = [ "nixhost-banlist-sets.service" ];
        environment = {
          URL = cfg.url;
          USER_NAME = cfg.user;
          PASSWORD_FILE = cfg.passwordFile;
          SIGNERS = "${signers}";
          MODE = cfg.mode;
          INTERVAL = toString cfg.interval;
          IPV6 = if ipv6 then "1" else "";
        };
        startLimitIntervalSec = 0;
        serviceConfig = {
          ExecStart = lib.getExe pull;
          Restart = "always";
          RestartSec = 30;
          StateDirectory = "nixhost-banlist";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "nixhost-banlist";
          RuntimeDirectoryMode = "0700";
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
          ];
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "full";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
        };
      };
    })
  ];
}
