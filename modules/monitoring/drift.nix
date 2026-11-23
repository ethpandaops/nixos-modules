# Drift from the configuration in git, as nixhost_drift_* and
# nixhost_ssh_* textfile metrics:
# - accounts, uid-0 accounts and members of privileged groups that the
#   configuration doesn't declare;
# - files in /etc that differ from the running system's /etc, and files in
#   sensitive /etc directories that it doesn't have;
# - authorized_keys files in home directories (sshd ignores them here);
# - comin still running with an older unit than the installed one;
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

  settings = pkgs.writeText "nixhost-drift.json" (
    builtins.toJSON {
      users = lib.mapAttrsToList (_: user: user.name) (
        lib.filterAttrs (_: user: user.enable or true) config.users.users
      );
      groups = lib.genAttrs cfg.groups membersOf;
      inherit (cfg) etcDirs;
      etcIgnore = cfg.etcIgnore ++ initrdHostKeys;
      comin = config.services.comin.enable or false;
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
      jq
      systemd
    ]
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
