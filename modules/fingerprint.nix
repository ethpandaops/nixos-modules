# What decides how disruptive a change to the system is, for a rollout to
# compare between two commits without building them:
#   nix eval --json .#nixosConfigurations.<host>.config.ethpandaops.fingerprint
# toplevel changes with anything but the configuration revision
# (system.configurationRevision, which a host repo sets to its commit), so
# a commit that changes nothing else keeps it. kernel, initrd, systemd,
# kernelParams and kernelModules (loaded at boot) apply only after a
# reboot, as reboot-detect counts them, and so do switch inhibitors: comin
# deploys a change to one with `boot`. kernelVersion and nixosRelease name
# the kernel and the NixOS release. A fleet adds its own keys, such as a k3s
# version.
{
  config,
  lib,
  extendModules,
  ...
}:
{
  options.ethpandaops.fingerprint = lib.mkOption {
    type = lib.types.attrsOf lib.types.unspecified;
    description = "Store paths and values a rollout compares between two commits to classify a change. Fleets may add keys.";
  };

  config.ethpandaops.fingerprint = {
    toplevel =
      (extendModules {
        modules = [ { system.configurationRevision = lib.mkForce null; } ];
      }).config.system.build.toplevel.drvPath;
    kernel = config.boot.kernelPackages.kernel.drvPath;
    kernelVersion = config.boot.kernelPackages.kernel.version;
    initrd = config.system.build.initialRamdisk.drvPath;
    systemd = config.systemd.package.drvPath;
    kernelParams = config.boot.kernelParams;
    kernelModules = config.boot.kernelModules;
    nixosRelease = config.system.nixos.release;
    inherit (config.system.switch) inhibitors;
  };
}
