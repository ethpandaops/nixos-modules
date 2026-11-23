# Mirrored disks with disko (disko.nixosModules.disko, imported by
# nixosModules.raid1-disks): every disk gets a BIOS boot partition, a member
# of an mdadm RAID1 ESP and a member of the RAID1 root (ext4). GRUB installs
# to every disk for BIOS and to the ESP's removable path for UEFI, so the
# server boots in either firmware mode and from either disk alone.
# mdadm events go to the admins through nixhost-notify.
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
    ];

    disko.devices = (import ./raid1-layout.nix cfg.disks).disko.devices;

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
