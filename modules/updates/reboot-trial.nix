# Reboots that undo themselves (ethpandaops.reboot.trial, off by default).
# GRUB boots the last confirmed system by default, and a newly deployed
# system only once, as a trial:
#
# - Any orderly shutdown arms the trial (nixhost-boot.service's ExecStop),
#   whoever reboots: the reboot policy, kured, an admin. A crash or a reset
#   boots the confirmed system.
# - GRUB clears the trial flag on disk before it boots the trial, so a reset
#   comes back to the confirmed system. On md RAID, where GRUB can't write
#   through the array, it clears the copy on each member; if it can't clear
#   them all, it boots the confirmed system instead (reboot-trial.cfg).
# - A trial that hangs is reset: by the hardware watchdog, which systemd
#   arms in the initrd and in stage 2, if the kernel or systemd stop; by a
#   deadline in the initrd and in stage 2 if the boot just doesn't finish,
#   such as an initrd waiting for its root array. A panic reboots after 60 s,
#   and an initrd failure panics instead of waiting at an emergency shell.
# - After every boot nixhost-boot-check runs the deploy health check without
#   its rollback. On a trial, a pass makes the system the confirmed one (and
#   GRUB's default); a failure reboots into the confirmed system.
# - The next boot records how a trial ended. A system whose trial failed
#   isn't tried again until another one is deployed or an admin runs
#   `nixhost-boot retry`; meanwhile reboot-detect holds its reboot
#   (required.json's held, with /run/reboot-required down so kured doesn't
#   reboot it over and over) and the admins hear about it.
#
# Reported as nixhost_boot_* metrics: nixhost_boot_reverts_total counts
# trials that went back, nixhost_boot_trial is 1 while this boot is an
# unconfirmed trial. /var/lib/nixhost-boot/trial.json has the last trial:
# system, confirmed (its fallback) and outcome (pending, confirmed,
# failed-check, deadline, hung, unconfirmed or not-tried).
#
# Needs GRUB, the systemd initrd and the deploy module's health check.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.reboot.trial;
  grub = config.boot.loader.grub;

  settings = pkgs.writeText "nixhost-boot.json" (
    builtins.toJSON {
      grubDirs = map (b: "${b.path}/grub") grub.mirroredBoots;
      inherit (cfg) deadline;
      # Added to the trial's kernel command line: reboot 60 s after a panic,
      # and panic rather than wait at the initrd's emergency shell.
      trialParams = "panic=60 boot.panic_on_fail";
    }
  );

  package = pkgs.writeShellApplication {
    name = "nixhost-boot";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      gnused
      grub2 # grub-editenv
      jq
      systemd
      util-linux # flock
    ];
    text = ''
      SETTINGS=${settings}
      NOTIFY=${lib.getExe config.ethpandaops.notify.package}
      ${config.ethpandaops.lib.shell}
      ${config.ethpandaops.lib.bootDefault}
      ${builtins.readFile ./reboot-trial.sh}
    '';
  };
  command = subcommand: "${lib.getExe package} ${subcommand}";
in
{
  imports = [
    ../metrics.nix
    ../notify.nix
  ];

  options.ethpandaops.reboot.trial = {
    enable = lib.mkEnableOption "reboots that undo themselves: a new system boots once, as a trial, and becomes GRUB's default only once it passes nixhost-boot-check";
    deadline = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1200;
      description = ''
        Seconds after the kernel starts by which a trial boot must pass
        nixhost-boot-check, or it reboots into the confirmed system. It
        covers the initrd too. Keep the health check's timeouts well under it.
      '';
    };
    watchdogModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "sp5100_tco" # AMD chipsets
        "iTCO_wdt" # Intel chipsets, with lpc_ich or i2c_i801 underneath
        "lpc_ich"
        "i2c_i801"
      ];
      example = [ "i6300esb" ];
      description = ''
        Hardware watchdog drivers to put in the initrd, so systemd can arm the
        watchdog there; udev loads the ones that match the hardware.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = grub.enable && grub.mirroredBoots != [ ] && toString grub.default == "0";
        message = "ethpandaops.reboot.trial needs GRUB with its default boot.loader.grub.default = 0.";
      }
      {
        assertion = config.boot.initrd.systemd.enable;
        message = "ethpandaops.reboot.trial needs the systemd initrd (boot.initrd.systemd.enable).";
      }
      {
        assertion = config.ethpandaops.deploy.healthCheck.enable or false;
        message = "ethpandaops.reboot.trial needs the deploy module's health check (ethpandaops.deploy.healthCheck.enable).";
      }
      {
        assertion = cfg.deadline > 2 * (config.ethpandaops.deploy.healthCheck.timeout or 0);
        message = "ethpandaops.reboot.trial.deadline must be more than twice ethpandaops.deploy.healthCheck.timeout, so a trial's boot check can finish before it.";
      }
    ];

    environment.systemPackages = [ package ];

    boot.loader.grub.extraEntries = builtins.readFile ./reboot-trial.cfg;

    # The watchdog from the initrd on. systemd disarms it for the switch to
    # stage 2, whose own RuntimeWatchdogSec (srvos: 15 s) takes over.
    boot.initrd.availableKernelModules = cfg.watchdogModules;
    boot.initrd.systemd.settings.Manager.RuntimeWatchdogSec = lib.mkDefault (
      config.systemd.settings.Manager.RuntimeWatchdogSec or "30s"
    );

    # A trial still in the initrd at its deadline, say waiting for an array
    # that never assembles, reboots. Leaving the initrd stops it, and an
    # emergency shell doesn't.
    boot.initrd.systemd.services.nixhost-initrd-deadline = {
      description = "Reboot a trial boot still in the initrd at its deadline";
      wantedBy = [ "initrd.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionKernelCommandLine = "nixhost.trial";
        IgnoreOnIsolate = true;
      };
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "infinity";
        ExecStart = "/bin/sleep ${toString cfg.deadline}";
        ExecStartPost = "/bin/systemctl reboot --force";
      };
    };

    # Settles the last trial at boot, and arms the next one when it's stopped
    # at shutdown, before /boot is unmounted.
    systemd.services.nixhost-boot = {
      description = "Boot the confirmed system by default, and try a new one once";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = map (b: b.path) grub.mirroredBoots;
      # A switch must not stop it: only a shutdown runs ExecStop.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = command "start";
        ExecStop = command "stop";
        TimeoutStopSec = 300;
      };
    };

    systemd.services.nixhost-boot-check = {
      wantedBy = [ "multi-user.target" ];
      after = [ "nixhost-boot.service" ];
      onSuccess = [ "nixhost-boot-confirm.service" ];
      onFailure = [ "nixhost-boot-revert.service" ];
    };
    systemd.services.nixhost-boot-confirm = {
      description = "Make a system that passed its boot check GRUB's default";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command "confirm";
      };
    };
    systemd.services.nixhost-boot-revert = {
      description = "Reboot a trial that failed its boot check into the confirmed system";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command "revert";
      };
    };

    systemd.timers.nixhost-boot-deadline = {
      wantedBy = [ "timers.target" ];
      unitConfig.ConditionKernelCommandLine = "nixhost.trial";
      timerConfig = {
        OnBootSec = "${toString cfg.deadline}s";
        AccuracySec = "1s";
      };
    };
    systemd.services.nixhost-boot-deadline = {
      description = "Reboot a trial that hasn't passed its boot check by the deadline";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command "deadline";
      };
    };
  };
}
