# Works out whether the box needs a reboot to run what is deployed: it
# compares the booted system with the deployed one for the kernel, initrd,
# kernel modules, kernel parameters and systemd, and, with
# security.lockKernelModules, the modules loaded at boot. It only reports: the
# standard /run/reboot-required sentinel (which tools such as kured read), the
# same flag in /run/nixhost/reboot/reboot-required (a directory to mount into
# kured), /run/nixhost/reboot/required.json and nixhost_reboot_pending*
# metrics. reboot-interactive, or another tool, decides when to reboot.
#
# The deployed system is /run/current-system, unless the bootloader's default
# entry names a system that is neither running nor booted: then it was
# deployed with `boot` (comin does that for a change named in
# system.switch.inhibitors), none of it runs yet, and the reboot is needed
# whatever changed (component boot-default). A `test` deploy from the testing
# branch can make it report a reboot that would not change anything; that
# clears on the reboot.
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
      diffutils
      gawk
      jq
      systemd
    ];
    text = ''
      COMPONENTS=(${lib.escapeShellArgs cfg.components})
      ${config.ethpandaops.lib.shell}
      ${config.ethpandaops.lib.bootDefault}
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
      "kernel-params"
      "systemd"
    ]
    # With module loading locked after boot, a module added to
    # boot.kernelModules loads only at the next boot.
    ++ lib.optional config.security.lockKernelModules "etc/modules-load.d/nixos.conf";
    defaultText = lib.literalExpression ''
      [ "kernel" "initrd" "kernel-modules" "kernel-params" "systemd" ]
      ++ lib.optional config.security.lockKernelModules "etc/modules-load.d/nixos.conf"
    '';
    description = "Parts of the system that need a reboot when they change: links, compared by target, or files, such as kernel-params, compared by content.";
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
