# Drift from the configuration in git, as nixhost_drift_* and
# nixhost_ssh_* textfile metrics:
# - accounts, uid-0 accounts and members of privileged groups that the
#   configuration doesn't declare;
# - files in /etc that differ from the running system's /etc, and files in
#   sensitive /etc directories that it doesn't have;
# - authorized_keys files in home directories (sshd ignores them here);
# - comin still running with an older unit than the installed one;
# - sockets listening beyond loopback on ports the configuration doesn't open,
#   and changes to the NixOS firewall's rules since activation;
# - a running or boot system other than the one the last deployment recorded,
#   as after a health-check rollback;
# - SSH logins, by whether the key is one the configuration pins.
#
# The box's root can change all of this and fake the metrics too, so they
# catch mistakes, leftovers and a stolen login key, not a determined root.
# Activation (each deploy) puts users, groups and /etc back as configured.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.monitoring.drift;

  # Group members as NixOS writes them to /etc/group: members plus every user
  # listing the group in extraGroups.
  membersOf =
    group:
    lib.unique (
      (config.users.groups.${group}.members or [ ])
      ++ lib.attrNames (
        lib.filterAttrs (
          _: user: (user.enable or true) && lib.elem group user.extraGroups
        ) config.users.users
      )
    );

  # initrd SSH host keys kept in /etc, as installers copy them there: not in
  # the system's /etc, but configured.
  initrdHostKeys =
    lib.concatMap
      (key: [
        key
        "${key}.pub"
      ])
      (
        map (lib.removePrefix "/etc/") (
          lib.filter (lib.hasPrefix "/etc/") (map toString config.boot.initrd.network.ssh.hostKeys)
        )
      );

  # Where the bootloader's default entry names its system. GRUB's first entry
  # (default 0) and systemd-boot's default are the system the last
  # switch-to-configuration switch or boot installed, whichever profile it
  # came from; comin switches with its own profile, so
  # /nix/var/nix/profiles/system is no guide.
  grub = config.boot.loader.grub;
  bootLoader =
    if config.boot.loader.systemd-boot.enable then
      { kind = "systemd-boot"; }
    else if
      grub.enable
      && toString grub.default == "0"
      && !grub.extraEntriesBeforeNixOS
      && grub.mirroredBoots != [ ]
    then
      {
        kind = "grub";
        config = "${(lib.head grub.mirroredBoots).path}/grub/grub.cfg";
      }
    else
      null;

  fw = config.networking.firewall;
  # proto:port and proto:from-to the firewall opens (everywhere or on one
  # interface), and sshd's ports: what may listen beyond loopback.
  openPorts =
    proto:
    let
      sets = [ fw ] ++ lib.attrValues fw.interfaces;
    in
    map (port: "${lib.toLower proto}:${toString port}") (
      lib.concatMap (set: set."allowed${proto}Ports") sets
      ++ lib.optionals (proto == "TCP" && config.services.openssh.enable) config.services.openssh.ports
    )
    ++ map (range: "${lib.toLower proto}:${toString range.from}-${toString range.to}") (
      lib.concatMap (set: set."allowed${proto}PortRanges") sets
    );

  settings = pkgs.writeText "nixhost-drift.json" (
    builtins.toJSON {
      users = lib.mapAttrsToList (_: user: user.name) (
        lib.filterAttrs (_: user: user.enable or true) config.users.users
      );
      groups = lib.genAttrs cfg.groups membersOf;
      inherit (cfg) etcDirs;
      etcIgnore = cfg.etcIgnore ++ initrdHostKeys;
      comin = config.services.comin.enable or false;
      inherit bootLoader;
      listen = {
        # Plus the DHCP clients' and the mDNS responder's sockets, which
        # systemd-networkd and systemd-resolved open whatever the firewall says.
        allowed = lib.unique (
          openPorts "TCP"
          ++ openPorts "UDP"
          ++ [
            "udp:68"
            "udp:546"
            "udp:5353"
          ]
          ++ cfg.listeners.allowed
        );
        # tailscaled listens on changing ports on its tailnet address.
        ignoreProcesses =
          cfg.listeners.ignoreProcesses ++ lib.optional config.services.tailscale.enable "tailscaled";
      };
      # NixOS's own rules: the iptables firewall's nixos-fw* chains and the
      # INPUT and PREROUTING jumps, or the nftables firewall's table.
      firewall =
        if !fw.enable then
          null
        else if config.networking.nftables.enable then
          {
            kind = "nftables";
            unit = "nftables.service";
          }
        else
          {
            kind = "iptables";
            unit = "firewall.service";
          };
      # The branch deployed with switch, whose system is also the boot default.
      deployBranch =
        if config.ethpandaops.deploy.enable or false then config.ethpandaops.deploy.branch else null;
    }
  );

  script =
    name: preamble: file: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        ${preamble}
        ${config.ethpandaops.lib.shell}
        ${builtins.readFile ./drift-common.sh}
        ${builtins.readFile file}
      '';
    };

  drift = script "nixhost-drift" "SETTINGS=${settings}" ./drift.sh (
    with pkgs;
    [
      coreutils
      findutils
      diffutils
      gawk
      gnugrep
      iproute2
      jq
      systemd
    ]
    ++ lib.optional fw.enable (if config.networking.nftables.enable then nftables else fw.package)
  );
  sshLogins = script "nixhost-ssh-logins" "" ./ssh-logins.sh (
    with pkgs;
    [
      coreutils
      gawk
      gnugrep
      openssh
      systemd
    ]
  );

  timer = period: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = period;
    };
  };
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.monitoring.drift = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Report drift from the configuration and SSH logins as textfile metrics.";
    };
    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "wheel"
        "ssh-users"
      ];
      description = "Groups whose undeclared members are reported.";
    };
    etcDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ssh"
        "ssh/authorized_keys.d"
        "sudoers.d"
        "pam.d"
        "systemd/system"
      ];
      description = "Directories under /etc where a file the configuration doesn't have is reported.";
    };
    etcIgnore = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ssh/ssh_host_*" ];
      description = "Paths under /etc (shell globs) that change at runtime by design. initrd SSH host keys under /etc are ignored too.";
    };
    listeners = {
      allowed = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "tcp:8080"
          "udp:5353"
        ];
        description = "Ports (proto:port or proto:from-to) that may listen beyond loopback besides those the firewall opens, sshd's, and the DHCP clients' and mDNS responder's (udp:68, udp:546, udp:5353).";
      };
      ignoreProcesses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "dockerd" ];
        description = "Programs whose listening sockets aren't reported, by executable name without NixOS's wrapper (.<name>-wrapped). tailscaled is left out whenever Tailscale is on.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /var/lib/nixhost-drift 0700 root root -" ];

    systemd.services.nixhost-drift = {
      description = "Compare users, groups and /etc with the configuration";
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe drift;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.nixhost-drift = timer "5min";

    systemd.services.nixhost-ssh-logins = {
      description = "Count SSH logins by whether the key is a configured one";
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe sshLogins;
      };
    };
    systemd.timers.nixhost-ssh-logins = timer "1min";
  };
}
