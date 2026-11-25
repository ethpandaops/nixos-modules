# Reboots that undo themselves, on the raid1-disks layout: GRUB on two disks
# with the ESP on md RAID1, where GRUB can't write through the array, booted
# in BIOS or UEFI mode with an i6300esb watchdog. A "deploy" makes one of the
# installed system's specialisations the bootloader's default, as comin's
# switch does, and a reboot tries it:
# - the installed system is confirmed on its first boot;
# - a good system boots once as a trial, passes its boot check and becomes
#   GRUB's default, with both disks' copies of the trial flag cleared by
#   GRUB and the mirror still consistent;
# - a system that comes up but fails its boot check reboots into the
#   confirmed one, through logind (PrepareForShutdown, for delay inhibitors
#   such as the kubelet's); its reboot is then held (no kured sentinel, no
#   reboot in the window or at the deadline) and another reboot doesn't try
#   it again;
# - a block inhibitor doesn't stop that revert;
# - a system whose initrd never finishes, as when its root array doesn't
#   assemble, is reset at the deadline;
# - a system whose kernel stops in the initrd is reset by the watchdog;
# and each time the box comes back on the confirmed system.
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
  disks = [
    "/dev/disk/by-id/disk-a"
    "/dev/disk/by-id/disk-b"
  ];
  deadline = 120;
  # Logs PrepareForShutdown, which logind sends delay inhibitors before it reboots.
  shutdownSignal.systemd.services.nixhost-test-shutdown-signal = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.dbus}/bin/dbus-monitor --system type=signal,interface=org.freedesktop.login1.Manager,member=PrepareForShutdown";
  };
  unhealthy = {
    imports = [ shutdownSignal ];
    environment.etc."nixhost-test-unhealthy".text = "";
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs efi;
  name = "reboot-trial-${if efi then "uefi" else "bios"}";
  disko-config = import ../../modules/raid1-layout.nix disks;
  extraInstallerConfig.boot.kernelPackages = pkgs.linuxPackages_latest;
  extraSystemConfig =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.base
        self.nixosModules.deploy
        self.nixosModules.reboot-interactive
        self.nixosModules.raid1-disks
      ];
      boot.loader.grub.efiSupport = lib.mkForce true;
      boot.loader.grub.efiInstallAsRemovable = lib.mkForce true;
      ethpandaops.raid1.disks = disks;
      ethpandaops.deploy = {
        # comin isn't run here; the health check's offline checks are.
        repository = "/var/lib/remote.git";
        deployKeyFile = null;
        healthCheck = {
          timeout = 20;
          checkDefaultRoute = false;
          dnsName = null;
          checkRemote = false;
          extraScript = "[ ! -e /etc/nixhost-test-unhealthy ]";
        };
      };
      services.comin.enable = lib.mkForce false;
      # srvos's closure diff can't read the installer's Nix output.
      srvos.update-diff.enable = false;
      ethpandaops.reboot.trial = {
        enable = true;
        inherit deadline;
        watchdogModules = [ "i6300esb" ];
      };
      # Reset soon after the watchdog stops being fed.
      boot.initrd.systemd.settings.Manager.RuntimeWatchdogSec = "10s";
      environment.systemPackages = [ pkgs.mtools ];

      # The systems to deploy.
      specialisation = {
        good.configuration.boot.kernelParams = [ "nixhost.test=good" ];
        unhealthy.configuration = unhealthy;
        # The same, with a shutdown lock held, which logind won't override for root without polkit.
        blocked.configuration = {
          imports = [ unhealthy ];
          systemd.services.nixhost-test-block = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=shutdown --mode=block --who=test --why=longjob ${pkgs.coreutils}/bin/sleep infinity";
          };
        };
        # An initrd that never finishes, like one waiting for a root array
        # that doesn't assemble.
        hang.configuration.boot.initrd.systemd.services.nixhost-test-hang = {
          requiredBy = [ "initrd.target" ];
          before = [ "initrd.target" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "/bin/sleep infinity";
            TimeoutStartSec = "infinity";
          };
        };
        # A kernel that stops once systemd has armed the watchdog, with no
        # reboot after the panic: only the watchdog can reset it.
        freeze.configuration.boot.initrd.systemd.services.nixhost-test-freeze = {
          requiredBy = [ "initrd.target" ];
          before = [ "initrd.target" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig.Type = "oneshot";
          script = ''
            armed() {
              for fd in /proc/1/fd/*; do
                case "$(readlink "$fd")" in /dev/watchdog*) return 0 ;; esac
              done
              return 1
            }
            until armed; do sleep 1; done
            echo 0 > /proc/sys/kernel/panic
            echo c > /proc/sysrq-trigger
          '';
        };
      };
    };
  extraTestScript = ''
    import json
    import time

    def sh(command):
        return machine.succeed(command).strip()

    def settle():
        # This boot's checks have passed and nixhost-boot-confirm has run.
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds("[ $(systemctl show -p ExecMainExitTimestampMonotonic --value nixhost-boot-confirm) != 0 ]", timeout=180)
        return sh("readlink -f /run/booted-system")

    def boot():
        machine.start()
        return settle()

    def deploy(name):
        # What comin's switch leaves the bootloader with: the new system as its default.
        system = sh(f"readlink -f {base}/specialisation/{name}")
        machine.succeed(f"{system}/bin/switch-to-configuration boot", "systemctl start nixhost-reboot-detect.service")
        return system

    def reboot():
        machine.execute("systemctl --no-block reboot")
        machine.wait_for_shutdown()

    def wait_reset(within):
        # The VM goes down by itself (the harness turns a reset into an exit)
        # within this many seconds of starting; returns how long it took.
        started = time.monotonic()
        assert machine.process
        machine.process.wait(timeout=within)
        machine.wait_for_shutdown()
        return time.monotonic() - started

    def trial():
        return json.loads(sh("cat /var/lib/nixhost-boot/trial.json"))

    def metric(series):
        return sh(f"grep -h '^{series} ' /var/lib/node-exporter/*.prom | cut -d' ' -f2")

    def esp_members():
        members = sh("ls /sys/block/$(basename $(readlink -f /dev/md/esp))/slaves").split()
        assert len(members) == 2, members
        return members

    def env_copies():
        # The trial flag in each ESP member's copy of nixhost/env, read past md.
        return [sh(f"MTOOLS_SKIP_CHECK=1 mtype -i /dev/{m} ::/grub/nixhost/env | sed -n 's/^nixhost_trial=//p'") for m in esp_members()]

    def mirror_differences():
        # Which files the 512-byte sectors that differ between the ESP's
        # members belong to (metadata 1.0: the filesystem starts at sector 0
        # of each member).
        a, b = esp_members()
        sectors = sorted({int(n) for n in sh(f"cmp -l -n $(blockdev --getsize64 /dev/md/esp) /dev/{a} /dev/{b} | head -n 100000 | awk '{{print int(($1 - 1) / 512)}}' | uniq").split()})
        owners = {}
        for line in sh("find /boot -type f -print0 | xargs -0 -n1 sh -c 'filefrag -b512 -v \"$0\" | sed \"s|^|$0 |\"'").splitlines():
            parts = line.replace(":", " ").replace("..", " ").split()
            # <path> <ext> <logical start> <logical end> <physical start> <physical end> <length> ...
            if len(parts) > 6 and parts[1].isdigit() and parts[4].isdigit() and parts[5].isdigit():
                for sector in sectors:
                    if int(parts[4]) <= sector <= int(parts[5]):
                        owners[sector] = parts[0]
        return {sector: owners.get(sector, "filesystem metadata or free space") for sector in sectors}

    base = settle()

    with subtest("the first boot confirms the installed system, which GRUB boots by default"):
        assert sh("readlink -f /var/lib/nixhost-boot/confirmed") == base
        machine.succeed("grep -q -- '--id nixhost-confirmed' /boot/grub/nixhost/boot.cfg", "grep -q 'source \"$nixhost_dir/boot.cfg\"' /boot/grub/grub.cfg")
        machine.fail("grep -q nixhost-trial /boot/grub/nixhost/boot.cfg")
        assert metric("nixhost_boot_fallback_ready") == "1"
        assert metric("nixhost_boot_trial") == "0"
        assert metric("nixhost_healthcheck_ok") == "1"

    # From here on the VM has a hardware watchdog for systemd to arm.
    machine.shutdown()
    machine.start_command._cmd += " -device i6300esb"
    assert boot() == base
    machine.succeed("journalctl -b -o cat | grep -q 'Using hardware watchdog /dev/watchdog0'")

    with subtest("a good system boots once as a trial, passes its boot check and becomes the default"):
        good = deploy("good")
        assert "boot-default" in json.loads(sh("cat /run/nixhost/reboot/required.json"))["components"]
        reboot()
        assert boot() == good
        machine.succeed(f"grep -q 'nixhost.trial={good.split('/')[-1]} panic=60 boot.panic_on_fail' /proc/cmdline")
        t = trial()
        assert t["system"] == good and t["confirmed"] == base and t["outcome"] == "confirmed", t
        assert sh("readlink -f /var/lib/nixhost-boot/confirmed") == good
        machine.succeed(f"grep -q 'NixOS - confirmed: {good.split('/')[-1]}' /boot/grub/nixhost/boot.cfg")
        machine.wait_until_succeeds("journalctl -t nixhost-notify | grep -q 'Trial boot confirmed'")
        assert metric("nixhost_boot_reverts_total") == "0"
        machine.succeed("systemctl start nixhost-reboot-detect.service", "test ! -e /run/reboot-required")

    with subtest("GRUB cleared the flag in both disks' copies, past md, and the mirror is consistent"):
        assert env_copies() == ["", ""], env_copies()
        a, b = esp_members()
        machine.succeed(f"cmp <(MTOOLS_SKIP_CHECK=1 mtype -i /dev/{a} ::/grub/nixhost/env) <(MTOOLS_SKIP_CHECK=1 mtype -i /dev/{b} ::/grub/nixhost/env)")
        machine.succeed(f"cmp /boot/grub/nixhost/env <(MTOOLS_SKIP_CHECK=1 mtype -i /dev/{a} ::/grub/nixhost/env)")
        # No sector of nixhost's files differs between the members. (UEFI
        # firmware may write to the ESP it booted from, past md.)
        md = sh("basename $(readlink -f /dev/md/esp)")
        machine.succeed(f"echo check > /sys/block/{md}/md/sync_action")
        machine.wait_until_succeeds(f"[ $(cat /sys/block/{md}/md/sync_action) = idle ]")
        differences = mirror_differences()
        print(f"mismatch_cnt {sh(f'cat /sys/block/{md}/md/mismatch_cnt')}; sectors that differ: {differences}")
        assert not any("/nixhost/" in owner for owner in differences.values()), differences

    with subtest("a system that comes up but fails its boot check reboots into the confirmed one"):
        unhealthy = deploy("unhealthy")
        reboot()
        machine.start()
        wait_reset(within=300)
        assert boot() == good
        machine.fail("grep -q nixhost.trial /proc/cmdline")
        t = trial()
        assert t["system"] == unhealthy and t["outcome"] == "failed-check" and "extra-script" in t["detail"], t
        # It was the trial that ran and failed, in the boot before this one.
        machine.succeed(f"journalctl -b -1 -k -o cat | grep -q 'Command line:.*nixhost.trial={unhealthy.split('/')[-1]}'")
        machine.succeed("journalctl -b -1 -o cat -u nixhost-boot-check | grep -q 'checks failed after boot: extra-script'")
        # Through logind, so the kubelet's graceful shutdown would run.
        machine.succeed("journalctl -b -1 -o cat -u nixhost-test-shutdown-signal | grep -A1 'member=PrepareForShutdown' | grep -q 'boolean true'")
        machine.fail("journalctl -b -1 -o cat -u nixhost-boot-revert | grep -q 'logind refused'")
        assert metric("nixhost_boot_reverts_total") == "1"
        machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'Trial boot reverted: The trial boot of {unhealthy.split('/')[-1]} ended failed-check'")

    with subtest("its reboot is held: no sentinel for kured, no reboot in the window or at the deadline"):
        machine.succeed("systemctl stop nixhost-reboot-policy.timer", "systemctl start nixhost-reboot-detect.service")
        required = json.loads(sh("cat /run/nixhost/reboot/required.json"))
        assert required["required"] and required["held"] == "trial-reverted", required
        machine.fail("test -e /run/reboot-required")
        machine.fail("test -e /run/nixhost/reboot/reboot-required")
        assert metric('nixhost_reboot_pending_held{reason="trial-reverted"}') == "1"
        assert metric("nixhost_reboot_pending") == "1"
        # 03:00 UTC eight days on: in the window, past the 7-day deadline.
        machine.succeed("date -u -s \"$(date -u -d '+8 days' +%F) 03:00:00\"", "systemctl start nixhost-reboot-policy.service")
        machine.fail("systemctl is-active -q nixhost-deadline-reboot.service")
        assert "waiting:" in sh("journalctl -o cat _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value nixhost-reboot-policy)")
        assert "failed its trial boot" in sh("reboot-status")

    with subtest("another reboot boots the confirmed system and doesn't try the failed one"):
        reboot()
        assert boot() == good
        machine.fail("grep -q nixhost.trial /proc/cmdline")
        assert trial()["outcome"] == "failed-check"
        machine.succeed("nixhost-boot retry", "test -e /run/reboot-required")

    with subtest("a block inhibitor doesn't stop a revert: logind refuses, so it starts reboot.target itself"):
        blocked = deploy("blocked")
        reboot()
        machine.start()
        wait_reset(within=300)
        assert boot() == good
        t = trial()
        assert t["system"] == blocked and t["outcome"] == "failed-check", t
        machine.succeed("journalctl -b -1 -o cat -u nixhost-test-block | grep -q .", "journalctl -b -1 -o cat -u nixhost-boot-revert | grep -q 'logind refused the reboot; starting reboot.target directly'")
        assert metric("nixhost_boot_reverts_total") == "2"

    with subtest("a system whose initrd never finishes is reset at the deadline"):
        hang = deploy("hang")
        reboot()
        machine.start()
        took = wait_reset(within=${toString deadline} + 180)
        assert took >= ${toString deadline}, took
        assert boot() == good
        t = trial()
        assert t["system"] == hang and t["outcome"] == "hung", t
        assert metric("nixhost_boot_reverts_total") == "3"

    with subtest("a kernel that stops in the initrd is reset by the watchdog, well before the deadline"):
        freeze = deploy("freeze")
        reboot()
        machine.start()
        took = wait_reset(within=${toString deadline} - 20)
        print(f"the watchdog reset the frozen trial {took:.0f} s after it started")
        assert boot() == good
        t = trial()
        assert t["system"] == freeze and t["outcome"] == "hung", t
        assert metric("nixhost_boot_reverts_total") == "4"
  '';
}
