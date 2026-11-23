# Mirrored disks with disko (disko.nixosModules.disko, imported by
# nixosModules.raid1-disks): every disk gets a BIOS boot partition, a member
# of an mdadm RAID1 ESP and a member of the RAID1 root (ext4). GRUB installs
# to every disk for BIOS and to the ESP's removable path for UEFI, so the
# server boots in either firmware mode and from either disk alone.
# mdadm events go to the admins through nixhost-notify.
#
# Needs a 6.19 or newer kernel, so it defaults to pkgs.linuxPackages_latest.
# Since 6.19 (upstream commit a4166f1c4893) a new array records its logical
# block size in the v1 superblock, and older kernels reject every member of
# such an array. Installers such as nixos-anywhere's run a newer kernel than
# NixOS's default, so a server booting the default kernel would never find
# its root array.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.raid1;
  mdadmEvent = pkgs.writeShellScript "nixhost-mdadm-event" ''
    exec ${lib.getExe config.ethpandaops.notify.package} admins "mdadm: $1 on $2 ''${3:-}"
  '';
in
{
  imports = [ ./notify.nix ];

  options.ethpandaops.raid1.disks = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    example = [
      "/dev/disk/by-id/nvme-EXAMPLE_SERIAL_1"
      "/dev/disk/by-id/nvme-EXAMPLE_SERIAL_2"
    ];
    description = "Two or more whole disks, as /dev/disk/by-id paths (sdX and nvmeXnY names can swap between boots).";
  };

  config = {
    assertions = [
      {
        assertion = builtins.length cfg.disks >= 2;
        message = "ethpandaops.raid1.disks needs at least two disks.";
      }
      {
        assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.19";
        message = ''
          ethpandaops.raid1: kernel ${config.boot.kernelPackages.kernel.version} can't assemble md arrays
          created by a 6.19 or newer kernel, such as the one in nixos-anywhere's installer, so the
          server wouldn't find its root array at boot. This module defaults to
          pkgs.linuxPackages_latest; don't set boot.kernelPackages to an older one.
        '';
      }
    ];

    disko.devices = (import ./raid1-layout.nix cfg.disks).disko.devices;

    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    boot.swraid = {
      enable = true;
      mdadmConf = "PROGRAM ${mdadmEvent}";
    };
    # systemd-boot can't install to an ESP on mdadm; GRUB can.
    boot.loader.systemd-boot.enable = false;
    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      # No NVRAM entry needed, and either disk's ESP copy boots.
      efiInstallAsRemovable = true;
    };
  };
}
