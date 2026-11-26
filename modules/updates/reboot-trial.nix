# Reboots that undo themselves (ethpandaops.reboot.trial, off by default).
# GRUB boots the last confirmed system by default, and a newly deployed
# system only once, as a trial:
#
# - Any orderly shutdown arms the trial (nixhost-boot.service's ExecStop),
#   whoever reboots: the reboot policy, kured, an admin. A crash or a reset
#   boots the confirmed system, and the admins hear when that skipped a
#   deployed system. A preArm hook runs first: it can have the new system
#   boot without a trial, as the confirmed one (outcome skipped), or arm
#   nothing (not-armed). A system whose rollback guard
#   (ethpandaops.rollback.guard) differs from the confirmed one's boots
#   without a trial the same way, since going back couldn't undo it.
# - GRUB clears the trial flag on disk before it boots the trial, so a reset
#   comes back to the confirmed system. On md RAID, where GRUB can't write
#   through the array, it clears the copy on each member; if it can't clear
#   them all, it boots the confirmed system instead (reboot-trial.cfg). That
#   needs the members to hold the filesystem at their start: a plain
#   partition, or md RAID1 with metadata 0.90 or 1.0. Elsewhere, such as /boot
#   on md metadata 1.2, trials are off: GRUB boots the deployed system as it
#   would without this module, nixhost_boot_trial_supported is 0 and the
#   admins hear once.
# - A trial that hangs is reset: by the hardware watchdog, which systemd
#   arms in the initrd and in stage 2, if the kernel or systemd stop; by a
#   deadline in the initrd (until it switches root, after NixOS activation)
#   and in stage 2 if the boot doesn't finish, such as an initrd waiting for
#   its root array. A panic reboots after 60 s, soft and hard lockups panic,
#   and an initrd failure panics instead of waiting at an emergency shell.
#   Without a watchdog trials still run, and the admins hear once.
# - After every boot, once, nixhost-boot-check runs the deploy health check
#   without its rollback; comin waits for it. On a trial, a pass makes the
#   system the confirmed one (and GRUB's default); a failure reboots into the
#   confirmed system.
# - A live switch whose deploy health check passes becomes the confirmed
#   system when a reboot wouldn't change anything boot-relevant (reboot-
#   detect's components or fstab), so a crash doesn't boot old configuration.
# - The next boot records how a trial ended. A system whose trial failed, or
#   that a shutdown couldn't arm, isn't tried again until another one is
#   deployed or an admin runs `nixhost-boot retry`; meanwhile reboot-detect
#   holds its reboot (required.json's held: trial-reverted or
#   trial-not-armed, with /run/reboot-required down so kured doesn't reboot
#   it over and over) and the admins hear about it. A failed nixhost-boot
#   holds it too.
# - The rollback breaker (../deploy/breaker.nix): a trial that reverts
#   (failed-check, deadline, hung) trips it and a confirmed one closes it.
#   While it's open, a trial that fails its check or misses the stage-2
#   deadline isn't rebooted: it ends held (not counted as a revert), stays
#   up on the trial system for a person to decide, and the admins hear
#   (critical); its reboot is held like a reverted one's. A trial that
#   hangs still comes back on the confirmed system through GRUB, the
#   watchdog and the initrd deadline, whatever the breaker says: a hung box
#   can't be reached at all.
#
# Also:
# - `grub-reboot` is ignored while trials are on: boot.cfg sets GRUB's
#   default after NixOS's next_entry handling.
# - A boot.cfg GRUB can't read whole fails open: GRUB boots its own entry 0,
#   the deployed system, outside a trial (outcome bypassed).
# - Revert and deadline reboots go through logind (so delay inhibitors run)
#   but don't take kured's lock.
#
# This boot's state is /run/nixhost/boot/status.json (bootId, system,
# confirmed, supported, trial: none, pending, confirmed, reverted or held,
# check: pending, ok or failed) and nixhost_boot_status{boot_id,trial,check}.
# nixhost_boot_reverts_total counts trials that failed their check, missed
# the deadline or hung. /var/lib/nixhost-boot/trial.json has the last trial:
# system, confirmed (its fallback), outcome and detail; a trial the preArm
# hook or the rollback guard skipped is outcome skipped, and its boot's
# trial is none.
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
  sysctl = config.boot.kernel.sysctl;

  # How long before the deadline a trial's boot check gives up on the
  # outside checks (DNS, the git remote): room for its last round of checks.
  outsideMargin = 120;

  # Enabled health checks whose timeout isn't under half the deadline.
  slowChecks = lib.mapAttrsToList (name: c: "${name} (${toString c.timeout} s)") (
    lib.filterAttrs (_: c: c.enable && c.kind == "health" && 2 * c.timeout >= cfg.deadline) (
      config.ethpandaops.checks or { }
    )
  );

  settings = pkgs.writeText "nixhost-boot.json" (
    builtins.toJSON {
      grubDirs = map (b: "${b.path}/grub") grub.mirroredBoots;
      inherit (cfg) deadline;
      inherit (config.ethpandaops.reboot.detect) components;
      # Added to the trial's kernel command line: reboot 60 s after a panic,
      # turn soft and hard lockups into panics, and panic rather than wait at
      # the initrd's emergency shell.
      trialParams = "panic=60 softlockup_panic=1 hardlockup_panic=1 boot.panic_on_fail";
      preArm =
        if cfg.preArm == null then
          null
        else
          lib.getExe (
            pkgs.writeShellApplication {
              name = "nixhost-boot-pre-arm";
              text = cfg.preArm;
            }
          );
      # What the lockup panics go back to once a trial is confirmed.
      panicSysctls = lib.mapAttrs (key: default: toString (sysctl."kernel.${key}" or default)) {
        softlockup_panic = 0;
        hardlockup_panic = 0;
      };
    }
  );

  package = pkgs.writeShellApplication {
    name = "nixhost-boot";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      gawk
      gnugrep
      gnused
      grub2 # grub-editenv
      jq
      systemd
      util-linux # findmnt, flock
    ];
    text = ''
      SETTINGS=${settings}
      NOTIFY=${lib.getExe config.ethpandaops.notify.package}
      ${config.ethpandaops.lib.shell}
      ${config.ethpandaops.lib.bootDefault}
      ${config.ethpandaops.lib.breaker}
      ${builtins.readFile ./reboot-trial.sh}
    '';
  };
  command = subcommand: "${lib.getExe package} ${subcommand}";
  oneshot = description: subcommand: {
    inherit description;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = command subcommand;
    };
  };
in
{
  imports = [
    ../deploy/breaker.nix
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
        covers the initrd too. On a trial, the check retries the outside
        health checks (DNS, the git remote) until ${toString outsideMargin} s
        before it. Every enabled health check's timeout must be under half
        of it.
      '';
    };
    preArm = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      example = lib.literalExpression ''
        '''
          # A k3s minor upgrade migrates its datastore, which booting the
          # old system again wouldn't undo: snapshot it, and skip the trial.
          if ! cmp -s "$1/etc/k3s-minor" "$2/etc/k3s-minor"; then
            k3s etcd-snapshot save || exit 1
            exit 10
          fi
        '''
      '';
      description = ''
        Bash (shellchecked; errexit, nounset, pipefail) that a shutdown runs
        just before it arms a trial, with the system about to boot as $1
        and the confirmed system as $2, for at most 120 s:

        - exit 0 arms the trial;
        - exit 10 boots the new system without a trial, for a change booting
          the old one again can't undo: it becomes the confirmed system and
          GRUB's default, trial.json records the outcome skipped (no revert
          counted), and the admins hear once at the next boot;
        - any other exit, or the timeout, arms nothing: the next boot is the
          confirmed system, and the reboot is held (trial-not-armed) until
          another system is deployed or an admin runs `nixhost-boot retry`.

        After an exit 0, a system whose rollback guard differs from the
        confirmed one's boots without a trial too.

        It runs in nixhost-boot.service's ExecStop, so order that unit after
        the services it needs (systemd.services.nixhost-boot.after), and
        they still run then.
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
        assertion = config.boot.initrd.systemd.enable && config.boot.initrd.systemd.shell.enable;
        message = "ethpandaops.reboot.trial needs the systemd initrd (boot.initrd.systemd.enable), with its shell for the boot deadline.";
      }
      {
        assertion = config.ethpandaops.deploy.healthCheck.enable or false;
        message = "ethpandaops.reboot.trial needs the deploy module's health check (ethpandaops.deploy.healthCheck.enable).";
      }
      {
        assertion = slowChecks == [ ];
        message = "ethpandaops.reboot.trial.deadline (${toString cfg.deadline} s) must be more than twice every enabled health check's timeout, so a trial's boot check can finish before it: ${lib.concatStringsSep ", " slowChecks}.";
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
    # that never assembles or in a NixOS activation that hangs (which runs
    # after initrd-switch-root.target), reboots. Isolating to the switch-root
    # or emergency target leaves it running; switching root ends it, because
    # systemd sends every remaining initrd process SIGTERM, which it takes as
    # a clean exit. A Conflicts= on initrd-switch-root.service would stop it
    # as soon as that service's start job is queued, before activation.
    boot.initrd.systemd.services.nixhost-initrd-deadline = {
      description = "Reboot a trial boot still in the initrd at its deadline";
      wantedBy = [ "initrd.target" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionKernelCommandLine = "nixhost.trial";
        IgnoreOnIsolate = true;
      };
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "infinity";
      };
      script = ''
        trap 'exit 0' TERM
        sleep ${toString cfg.deadline} &
        wait
        systemctl reboot --force
      '';
    };

    # Settles the last trial at boot, and arms the next one when it's stopped
    # at shutdown, before /boot is unmounted.
    systemd.services.nixhost-boot = {
      description = "Boot the confirmed system by default, and try a new one once";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      onFailure = [ "nixhost-boot-failed.service" ];
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
    systemd.services.nixhost-boot-failed = {
      description = "Tell the admins nixhost-boot failed";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        ${lib.getExe config.ethpandaops.notify.package} --severity critical --title "nixhost-boot failed" admins \
          "nixhost-boot.service failed, so no trial can be armed and reboots for a newly deployed system are held. See journalctl -u nixhost-boot."
      '';
    };

    systemd.services.nixhost-boot-check = {
      wantedBy = [ "multi-user.target" ];
      after = [ "nixhost-boot.service" ];
      onSuccess = [ "nixhost-boot-confirm.service" ];
      onFailure = [ "nixhost-boot-revert.service" ];
      environment.NIXHOST_OUTSIDE_CHECKS_UNTIL = toString (cfg.deadline - outsideMargin);
    };
    systemd.services.nixhost-boot-confirm = oneshot "Make a system that passed its boot check GRUB's default" "confirm";
    systemd.services.nixhost-boot-revert = oneshot "Reboot a trial that failed its boot check into the confirmed system" "revert";

    # A live switch that passes the deploy health check.
    systemd.services.nixhost-health-check.onSuccess = [ "nixhost-boot-switched.service" ];
    systemd.services.nixhost-boot-switched = oneshot "Confirm a switched system a reboot wouldn't change" "switched";

    # No deploy during a trial, before its boot check has decided it.
    systemd.services.comin = lib.mkIf (config.services.comin.enable or false) {
      wantedBy = lib.mkForce [ "nixhost-boot-check.service" ];
      after = [ "nixhost-boot-check.service" ];
    };

    systemd.timers.nixhost-boot-deadline = {
      wantedBy = [ "timers.target" ];
      unitConfig.ConditionKernelCommandLine = "nixhost.trial";
      timerConfig = {
        OnBootSec = "${toString cfg.deadline}s";
        AccuracySec = "1s";
      };
    };
    systemd.services.nixhost-boot-deadline = oneshot "Reboot a trial that hasn't passed its boot check by the deadline" "deadline";
  };
}
