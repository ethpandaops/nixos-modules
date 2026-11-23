# Works out whether the box needs a reboot to run what is deployed: it
# compares the booted system with /run/current-system for the kernel, initrd,
# kernel modules and systemd. It only reports: the standard
# /run/reboot-required sentinel (which tools such as kured read),
# /run/nixhost/reboot/required.json and nixhost_reboot_pending* metrics.
# reboot-interactive, or another tool, decides when to reboot.
#
# comin deploys the main branch with `switch`, so /run/current-system is also
# what the box boots next. A `test` deploy from the testing branch can make it
# report a reboot that would not change anything; that clears on the reboot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.reboot.detect;
  detect = pkgs.writeShellApplication {
    name = "nixhost-reboot-detect";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      COMPONENTS=(${lib.escapeShellArgs cfg.components})
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./reboot-detect.sh}
    '';
  };
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.reboot.detect.components = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "kernel"
      "initrd"
      "kernel-modules"
      "systemd"
    ];
    description = "Links in the system closure that need a reboot when they change.";
  };

  config = {
    systemd.tmpfiles.rules = [ "d /run/nixhost/reboot 0755 root root -" ];

    systemd.services.nixhost-reboot-detect = {
      # Started on demand (by deploys and the reboot-* commands), so never rate-limit it.
      startLimitIntervalSec = 0;
      description = "Check whether a reboot is needed to run the deployed system";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe detect;
      };
    };
    systemd.timers.nixhost-reboot-detect = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "15min";
      };
    };
  };
}
