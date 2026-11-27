# The disko layout behind digitalocean.nix, as a function of the disk: a BIOS
# boot partition for GRUB (droplets boot with SeaBIOS) and ext4 root on the
# rest.
disk: {
  disko.devices.disk.main = {
    type = "disk";
    device = disk;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
