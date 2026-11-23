# Install the raid1-disks layout with disko onto two blank disks, boot the
# result in BIOS or UEFI mode, and check both arrays came up. Like
# nixos-anywhere, the installer runs the newest kernel.
{
  self,
  pkgs,
  nixpkgs,
  disko,
  efi,
}:
let
  diskoLib = import "${disko}/lib" {
    inherit (pkgs) lib;
    makeTest = import "${nixpkgs}/nixos/tests/make-test-python.nix";
    eval-config = import "${nixpkgs}/nixos/lib/eval-config.nix";
    qemu-common = import "${nixpkgs}/nixos/lib/qemu-common.nix";
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs efi;
  name = "raid1-disks-${if efi then "uefi" else "bios"}";
  disko-config = import ../../modules/raid1-layout.nix [
    "/dev/disk/by-id/disk-a"
    "/dev/disk/by-id/disk-b"
  ];
  extraInstallerConfig.boot.kernelPackages = pkgs.linuxPackages_latest;
  extraSystemConfig = {
    imports = [ self.nixosModules.raid1-disks ];
    # The harness sets these per firmware mode; the module installs for both
    # in either mode, which is what this test checks.
    boot.loader.grub.efiSupport = pkgs.lib.mkForce true;
    boot.loader.grub.efiInstallAsRemovable = pkgs.lib.mkForce true;
    # The test harness swaps in its own device names.
    ethpandaops.raid1.disks = [
      "/dev/disk/by-id/disk-a"
      "/dev/disk/by-id/disk-b"
    ];
  };
  extraTestScript = ''
    machine.succeed("test -b /dev/md/root")
    machine.succeed("test -b /dev/md/esp")
    machine.succeed("mountpoint /boot")
    machine.succeed("grep -A1 '^md' /proc/mdstat | grep -q '\\[UU\\]'")
    machine.succeed("findmnt -n -o SOURCE / | grep -q '^/dev/md'")
  '';
}
