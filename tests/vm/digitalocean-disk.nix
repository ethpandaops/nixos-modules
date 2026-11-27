# A droplet's disk as nixos-anywhere leaves it: disko's layout from the
# digitalocean module, installed and then booted by SeaBIOS through GRUB on
# the BIOS boot partition, with no hardware watchdog. A deployed system boots
# once as a trial and is confirmed, and the admins hear once that there's
# no watchdog. The network from the metadata is the digitalocean test's.
{
  self,
  pkgs,
  nixpkgs,
  disko,
}:
let
  inherit (pkgs) lib;
  diskoLib = import "${disko}/lib" {
    inherit lib;
    makeTest = import "${nixpkgs}/nixos/tests/make-test-python.nix";
    eval-config = import "${nixpkgs}/nixos/lib/eval-config.nix";
    qemu-common = import "${nixpkgs}/nixos/lib/qemu-common.nix";
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "digitalocean-disk";
  efi = false;
  disko-config = import ../../modules/digitalocean-layout.nix "/dev/vda";
  extraSystemConfig =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.base
        self.nixosModules.deploy
        self.nixosModules.reboot-interactive
        self.nixosModules.digitalocean
      ];
      systemd.services.digitalocean-network.enable = false;
      ethpandaops.checks.digitalocean-network.enable = false;
      ethpandaops.deploy = {
        repository = "/var/lib/remote.git";
        deployKeyFile = null;
        healthCheck = {
          checkDefaultRoute = false;
          dnsName = null;
          checkRemote = false;
        };
      };
      services.comin.enable = lib.mkForce false;
      # srvos's closure diff can't read the installer's Nix output.
      srvos.update-diff.enable = false;
      ethpandaops.reboot.trial.enable = true;
      specialisation.good.configuration.boot.kernelParams = [ "nixhost.test=good" ];
    };
  extraTestScript = ''
    import json
    import shlex

    def sh(command):
        return machine.succeed(command).strip()

    def settle():
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds("[ $(systemctl show -p ExecMainExitTimestampMonotonic --value nixhost-boot-confirm) != 0 ]", timeout=300)
        return sh("readlink -f /run/booted-system")

    def metric(series):
        return sh(f"awk -v s={shlex.quote(series + ' ')} 'index($0, s) == 1 {{ print $NF; exit }}' /var/lib/node-exporter/*.prom")

    base = settle()

    with subtest("GRUB boots from the BIOS boot partition, and root is ext4 on the rest of the disk"):
        machine.succeed("dd if=/dev/vda bs=512 count=1 2>/dev/null | grep -q GRUB")
        assert sh("lsblk -no PARTTYPE /dev/vda1") == "21686148-6449-6e6f-744e-656564454649"
        assert sh("findmnt -no SOURCE,FSTYPE /") == "/dev/vda2 ext4"

    with subtest("a deployed system boots once as a trial and is confirmed, with no hardware watchdog"):
        assert metric("nixhost_boot_trial_supported") == "1"
        assert metric("nixhost_boot_watchdog_present") == "0"
        machine.wait_until_succeeds("journalctl -t nixhost-notify -o cat | grep -q 'No hardware watchdog: '")
        good = sh(f"readlink -f {base}/specialisation/good")
        machine.succeed(f"{good}/bin/switch-to-configuration boot", "sync")
        machine.execute("systemctl --no-block reboot", check_output=False)
        machine.wait_for_shutdown()
        machine.start()
        assert settle() == good
        machine.succeed(f"grep -q 'nixhost.trial={good.split('/')[-1]}' /proc/cmdline")
        trial = json.loads(sh("cat /var/lib/nixhost-boot/trial.json"))
        assert trial["system"] == good and trial["confirmed"] == base and trial["outcome"] == "confirmed", trial
  '';
}
