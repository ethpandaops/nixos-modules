# Locking kernel module loading after boot, and the modules to load at boot
# so that's safe. With security.lockKernelModules nothing loads a module once
# multi-user.target is reached and udev has settled, root included, until the
# next reboot: a service that needs one later gets an error, and the feature
# breaks.
#
# Collect, then lock:
#   1. Leave lock off, with monitoring and monitoring.logs (its audit rules)
#      on. nixhost-kernel exports nixhost_kernel_module_late_loads_total
#      {module}: every module loaded after boot, which is exactly what the
#      lock would refuse.
#   2. Add each to allowlist. A change to the list takes effect at the next
#      boot; reboot-detect counts it as a reboot under the lock.
#   3. Once nothing new has loaded late for a week or two, set lock.
# Hardware drivers need no entry: udev loads them before the lock.
{ config, lib, ... }:
let
  cfg = config.ethpandaops.kernelModules;
in
{
  options.ethpandaops.kernelModules = {
    lock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable module loading once the box has booted (security.lockKernelModules).";
    };
    allowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "overlay"
        "br_netfilter"
        "inet_diag"
        "tcp_diag"
      ];
      description = ''
        Modules loaded at boot (boot.kernelModules), so they're there once
        the lock is on: everything a service needs after boot. nixos-modules'
        own checks use ss, which wants inet_diag, tcp_diag, udp_diag,
        unix_diag and netlink_diag.
      '';
    };
  };

  config = {
    boot.kernelModules = cfg.allowlist;
    security.lockKernelModules = lib.mkIf cfg.lock true;
  };
}
