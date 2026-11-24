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
  # mdadm's PROGRAM: <event> <md device> [<component device>]. Events that
  # need someone are sent with the array's /proc/mdstat lines; NewArray
  # (every array at every boot) and RebuildNN (progress) aren't news.
  mdadmEvent = pkgs.writeShellApplication {
    name = "nixhost-mdadm-event";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      event=$1 array=$2 member=''${3:-}
      case "$event" in
      Fail) severity=critical title="RAID member failed" ;;
      FailSpare) severity=critical title="RAID spare failed while rebuilding" ;;
      DegradedArray) severity=critical title="RAID array degraded" ;;
      DeviceDisappeared) severity=critical title="RAID array disappeared" ;;
      SparesMissing) severity=warning title="RAID array missing spares" ;;
      RebuildStarted) severity=info title="RAID rebuild started" ;;
      RebuildFinished) severity=ok title="RAID rebuild finished" ;;
      SpareActive) severity=ok title="RAID spare in use" ;;
      MoveSpare) severity=info title="RAID spare moved" ;;
      TestMessage) severity=info title="RAID alert test" ;;
      *) exit 0 ;;
      esac
      name=$(basename "$(readlink -f "$array")")
      details="mdadm: $event on $array''${member:+ ($member)}"
      if mdstat=$(awk -v md="$name" '$1 == md { found = 1 } found && NF == 0 { exit } found' /proc/mdstat) &&
        [ -n "$mdstat" ]; then
        details+=$'\n```\n'"$mdstat"$'\n```'
      fi
      exec ${lib.getExe config.ethpandaops.notify.package} --severity "$severity" --title "$title" admins "$details"
    '';
  };
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

    # mdadm.conf is also copied into the initrd, so PROGRAM names a stable
    # path rather than the script's store path: otherwise every change to
    # nixhost-notify would change the initrd and ask for a reboot. Nothing
    # runs PROGRAM in the initrd. mdadm uses the first PROGRAM line, so this
    # one goes first.
    environment.systemPackages = [ mdadmEvent ];
    boot.swraid = {
      enable = true;
      mdadmConf = lib.mkBefore "PROGRAM /run/current-system/sw/bin/nixhost-mdadm-event";
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
