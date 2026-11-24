# What decides how disruptive a change to the system is, for a rollout to
# compare between two commits without building them:
#   nix eval --json .#nixosConfigurations.<host>.config.ethpandaops.fingerprint
# toplevel changes with anything. kernel, initrd, systemd, kernelParams and
# kernelModules (loaded at boot) apply only after a reboot, as reboot-detect
# counts them, and so do switch inhibitors: comin deploys a change to one
# with `boot`. A fleet adds its own keys, such as a k3s version.
{ config, lib, ... }:
{
  options.ethpandaops.fingerprint = lib.mkOption {
    type = lib.types.attrsOf lib.types.unspecified;
    description = "Store paths and values a rollout compares between two commits to classify a change. Fleets may add keys.";
  };

  config.ethpandaops.fingerprint = {
    toplevel = config.system.build.toplevel.drvPath;
    kernel = config.boot.kernelPackages.kernel.drvPath;
    initrd = config.system.build.initialRamdisk.drvPath;
    systemd = config.systemd.package.drvPath;
    kernelParams = config.boot.kernelParams;
    kernelModules = config.boot.kernelModules;
    inherit (config.system.switch) inhibitors;
  };
}
