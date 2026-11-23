# The disko layout behind raid1-disks.nix, as a function of the disk list:
# every disk gets a BIOS boot partition, an ESP member and a root member. The
# ESP is an mdadm RAID1 with metadata 1.0 (stored at the end, so firmware
# sees plain FAT) and the root filesystem is ext4 on another RAID1.
disks:
let
  member = arrayName: {
    type = "mdraid";
    name = arrayName;
  };
  disk = index: device: {
    name = "disk${toString index}";
    value = {
      type = "disk";
      inherit device;
      content = {
        type = "gpt";
        partitions = {
          bios = {
            size = "1M";
            type = "EF02"; # GRUB core image for BIOS boot
            priority = 1;
          };
          esp = {
            size = "1G";
            type = "EF00";
            priority = 2;
            content = member "esp";
          };
          root = {
            size = "100%";
            content = member "root";
          };
        };
      };
    };
  };
  indexed = builtins.genList (i: disk i (builtins.elemAt disks i)) (builtins.length disks);
in
{
  disko.devices = {
    disk = builtins.listToAttrs indexed;
    mdadm = {
      esp = {
        type = "mdadm";
        level = 1;
        metadata = "1.0";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };
      root = {
        type = "mdadm";
        level = 1;
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
        };
      };
    };
  };
}
