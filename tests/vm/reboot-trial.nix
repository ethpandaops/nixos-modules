# Reboots that undo themselves, installed with disko and booted with GRUB.
# A "deploy" makes one of the installed system's specialisations the
# bootloader's default, as comin's switch does, and a reboot tries it.
#
# core (BIOS and UEFI; raid1-disks: the ESP on md RAID1 metadata 1.0, where
# GRUB can't write through the array; an i6300esb watchdog after the first
# boot):
# - the first boot confirms the installed system; without a watchdog the
#   admins hear once;
# - the boot check runs once per boot, though a switch restarts its target;
# - a switch that passes the deploy check and needs no reboot is confirmed,
#   so a crash boots it; a crash with a new system deployed boots the
#   confirmed one and the admins hear;
# - a good system boots once as a trial, passes and becomes the default,
#   with GRUB's flag cleared in both disks' copies and the lockup panics
#   back off;
# - on a trial, an unreachable git remote is retried past the health
#   check's timeout until near the deadline, and the trial confirms;
# - a system that fails its boot check reboots into the confirmed one
#   through logind (PrepareForShutdown), which opens the rollback breaker;
#   its reboot is held (no kured sentinel, no reboot in the window or at the
#   deadline) and another reboot doesn't try it again; a block inhibitor
#   doesn't stop a revert;
# - a power loss while arming, or a full ESP at shutdown, leaves the trial
#   not armed, uncounted and held, with nothing partial on the ESP;
# - a kernel that stops in the initrd is reset by the watchdog.
# hangs (BIOS): an initrd that never finishes and a NixOS activation that
#   hangs are reset at the deadline; a trial shut down before its check ends
#   unconfirmed; one whose check never finishes is reset by the stage-2
#   deadline.
# md12, md10 (BIOS, /boot on md RAID1 with metadata 1.2 and ext3, or 1.0
#   and ext4): with 1.2 trials are off, the admins hear once and a reboot
#   boots the deployed system directly; with 1.0 a trial confirms and a
#   failing one reverts, which opens the rollback breaker, so the next
#   failing one stays up, held; a pre-arm hook that exits 10 boots the
#   next system without a trial, as the confirmed one, and one that exits 1
#   arms nothing and holds the reboot; a system whose rollback guard
#   differs boots without a trial.
# Every scenario runs a pre-arm hook, which arms the trial when it exits 0.
{
  self,
  pkgs,
  nixpkgs,
  disko,
  efi,
  scenario,
}:
let
  inherit (pkgs) lib;
  diskoLib = import "${disko}/lib" {
    inherit lib;
    makeTest = import "${nixpkgs}/nixos/tests/make-test-python.nix";
    eval-config = import "${nixpkgs}/nixos/lib/eval-config.nix";
    qemu-common = import "${nixpkgs}/nixos/lib/qemu-common.nix";
  };
  disks = [
    "/dev/disk/by-id/disk-a"
    "/dev/disk/by-id/disk-b"
  ];
  mdBoot = lib.hasPrefix "md" scenario;
  deadline = if scenario == "hangs" then 120 else 240;

  # /boot on its own md RAID1, as Hetzner's installimage lays it out (1.2,
  # ext3) or as utility's migration rebuilds it (1.0).
  mdBootLayout =
    let
      metadata = if scenario == "md12" then "1.2" else "1.0";
      format = if scenario == "md12" then "ext3" else "ext4";
      disk = i: device: {
        name = "disk${toString i}";
        value = {
          type = "disk";
          inherit device;
          content = {
            type = "gpt";
            partitions = {
              bios = {
                size = "1M";
                type = "EF02";
                priority = 1;
              };
              boot = {
                size = "1G";
                priority = 2;
                content = {
                  type = "mdraid";
                  name = "boot";
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "mdraid";
                  name = "root";
                };
              };
            };
          };
        };
      };
    in
    {
      disko.devices = {
        disk = builtins.listToAttrs (lib.imap0 disk disks);
        mdadm = {
          boot = {
            type = "mdadm";
            level = 1;
            inherit metadata;
            content = {
              type = "filesystem";
              inherit format;
              mountpoint = "/boot";
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
    };

  # Logs PrepareForShutdown, which logind sends delay inhibitors before it reboots.
  shutdownSignal.systemd.services.nixhost-test-shutdown-signal = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.dbus}/bin/dbus-monitor --system type=signal,interface=org.freedesktop.login1.Manager,member=PrepareForShutdown";
  };
  unhealthy = {
    imports = [ shutdownSignal ];
    environment.etc."nixhost-test-unhealthy".text = "";
  };
  # An initrd service that never finishes, like one waiting for a root array
  # that doesn't assemble.
  initrdHang.boot.initrd.systemd.services.nixhost-test-hang = {
    requiredBy = [ "initrd.target" ];
    before = [ "initrd.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/bin/sleep infinity";
      TimeoutStartSec = "infinity";
    };
  };

  specialisations = {
    core = {
      good.configuration.boot.kernelParams = [ "nixhost.test=good" ];
      # Userspace only: a reboot wouldn't change anything.
      userspace.configuration.environment.etc."nixhost-test-userspace".text = "";
      unhealthy.configuration = unhealthy;
      # The same, with a shutdown lock held, which logind won't override for root without polkit.
      blocked.configuration = {
        imports = [ unhealthy ];
        systemd.services.nixhost-test-block = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=shutdown --mode=block --who=test --why=longjob ${pkgs.coreutils}/bin/sleep infinity";
        };
      };
      # Checks the git remote, which only appears at 60 s of uptime.
      slowremote.configuration =
        { lib, ... }:
        {
          ethpandaops.deploy.healthCheck.checkRemote = lib.mkForce true;
          systemd.services.nixhost-test-remote = {
            wantedBy = [ "multi-user.target" ];
            path = [ pkgs.git ];
            script = ''
              until [ "$(cut -d. -f1 /proc/uptime)" -ge 60 ]; do sleep 1; done
              if [ ! -d /var/lib/remote.git ]; then
                git init -q -b deploy /tmp/remote-work
                git -C /tmp/remote-work -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init
                git clone -q --bare /tmp/remote-work /var/lib/remote.git
              fi
            '';
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
    hangs = {
      hang.configuration = initrdHang;
      # NixOS activation, which runs in the initrd after
      # initrd-switch-root.target, never finishes.
      activationhang.configuration.system.activationScripts.nixhost-test-hang = ''
        if [ "''${IN_NIXOS_SYSTEMD_STAGE1:-}" = true ]; then sleep infinity; fi
      '';
      # The boot check waits for a service that never finishes.
      stuck.configuration.systemd.services = {
        nixhost-test-stuck.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          TimeoutStartSec = "infinity";
        };
        nixhost-boot-check = {
          wants = [ "nixhost-test-stuck.service" ];
          after = [ "nixhost-test-stuck.service" ];
        };
      };
    };
    md12.good.configuration.boot.kernelParams = [ "nixhost.test=good" ];
    md10 = {
      good.configuration.boot.kernelParams = [ "nixhost.test=good" ];
      unhealthy.configuration = unhealthy;
      skip.configuration.boot.kernelParams = [ "nixhost.test=skip" ];
      # A value no rollback may cross, as for a k3s minor upgrade.
      guarded.configuration.ethpandaops.rollback.guard.k3s = "1.34";
    };
  };

  scripts = {
    core = ''
      import re

      with subtest("the first boot confirms the installed system; without a hardware watchdog the admins hear once"):
          assert sh("readlink -f /var/lib/nixhost-boot/confirmed") == base
          machine.succeed(f"grep -q 'nixhost.confirmed={name(base)}' /boot/grub/nixhost/boot.cfg", "grep -q 'source \"$nixhost_dir/boot.cfg\"' /boot/grub/grub.cfg")
          machine.succeed("grep -q -- '--id nixhost-confirmed' /boot/grub/nixhost/boot.cfg")
          machine.fail("grep -q nixhost-trial /boot/grub/nixhost/boot.cfg")
          assert metric("nixhost_boot_fallback_ready") == "1"
          assert metric("nixhost_boot_trial_supported") == "1"
          assert metric("nixhost_boot_trial") == "0"
          assert metric("nixhost_boot_watchdog_present") == "0"
          s = status()
          assert s["bootId"] == boot_id() and s["trial"] == "none" and s["check"] == "ok" and s["supported"] is True, s
          assert metric(f'nixhost_boot_status{{boot_id="{boot_id()}",trial="none",check="ok"}}') == "1"
          machine.succeed("systemctl start nixhost-boot-confirm.service")
          assert notices("No hardware watchdog") == 1

      userspace = system("userspace")

      with subtest("the boot check runs once per boot, though a switch starts multi-user.target again"):
          before = sh("systemctl show -p InvocationID --value nixhost-boot-check")
          switched = machine.succeed(f"STC_DISPLAY_ALL_UNITS=1 {userspace}/bin/switch-to-configuration switch 2>&1")
          assert re.search(r"starting the following units: .*multi-user\.target", switched), switched
          assert sh("systemctl show -p InvocationID --value nixhost-boot-check") == before

      with subtest("a switch that passes the deploy check and needs no reboot is confirmed, so a crash boots it"):
          machine.succeed("systemctl start nixhost-health-check.service")
          machine.wait_until_succeeds(f"[ $(readlink -f /var/lib/nixhost-boot/confirmed) = {userspace} ]")
          machine.succeed(f"grep -q 'nixhost.confirmed={name(userspace)}' /boot/grub/nixhost/boot.cfg")
          machine.crash()
          # From here on the VM has a hardware watchdog for systemd to arm.
          machine.start_command._cmd += " -device i6300esb"
          assert boot() == userspace
          machine.succeed(f"grep -q 'nixhost.confirmed={name(userspace)}' /proc/cmdline")
          machine.succeed("journalctl -b -o cat | grep -q 'Using hardware watchdog /dev/watchdog0'")
          assert metric("nixhost_boot_watchdog_present") == "1"

      with subtest("a crash with a new system deployed boots the confirmed one, and the admins hear"):
          good = deploy("good")
          machine.crash()
          assert boot() == userspace
          machine.fail("grep -q nixhost.trial /proc/cmdline")
          machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'Booted the confirmed system: The box booted {name(userspace)}, the last confirmed system, though {name(good)} is deployed'")
          machine.succeed("systemctl start nixhost-reboot-detect.service", "test -e /run/reboot-required")

      with subtest("a good system boots once as a trial, passes its boot check and becomes the default"):
          reboot()
          assert boot() == good
          machine.succeed(f"grep -q 'nixhost.trial={name(good)} panic=60 softlockup_panic=1 hardlockup_panic=1 boot.panic_on_fail' /proc/cmdline")
          t = trial()
          assert t["system"] == good and t["confirmed"] == userspace and t["outcome"] == "confirmed", t
          assert sh("readlink -f /var/lib/nixhost-boot/confirmed") == good
          machine.succeed(f"grep -q 'NixOS - confirmed: {name(good)}' /boot/grub/nixhost/boot.cfg")
          machine.wait_until_succeeds("journalctl -t nixhost-notify | grep -q 'Trial boot confirmed'")
          # The lockup panics are for the trial only.
          assert sh("cat /proc/sys/kernel/softlockup_panic") == "0"
          s = status()
          assert s["trial"] == "confirmed" and s["check"] == "ok", s
          assert metric(f'nixhost_boot_status{{boot_id="{boot_id()}",trial="confirmed",check="ok"}}') == "1"
          assert metric("nixhost_boot_reverts_total") == "0"
          machine.succeed("systemctl start nixhost-reboot-detect.service", "test ! -e /run/reboot-required")

      with subtest("GRUB cleared the flag in both disks' copies, past md, and the mirror is consistent"):
          assert env_copies() == ["", ""], env_copies()
          a, b = esp_members()
          machine.succeed(f"cmp <(MTOOLS_SKIP_CHECK=1 mtype -i /dev/{a} ::/grub/nixhost/env) <(MTOOLS_SKIP_CHECK=1 mtype -i /dev/{b} ::/grub/nixhost/env)")
          # No sector of nixhost's files differs between the members. (UEFI
          # firmware may write to the ESP it booted from, past md.)
          md = sh("basename $(readlink -f /dev/md/esp)")
          # After the crashes above md may still be resyncing.
          machine.wait_until_succeeds(f"[ $(cat /sys/block/{md}/md/sync_action) = idle ]", timeout=300)
          machine.succeed(f"echo check > /sys/block/{md}/md/sync_action")
          machine.wait_until_succeeds(f"[ $(cat /sys/block/{md}/md/sync_action) = idle ]")
          differences = mirror_differences()
          print(f"mismatch_cnt {sh(f'cat /sys/block/{md}/md/mismatch_cnt')}; sectors that differ: {differences}")
          assert not any("/nixhost/" in owner for owner in differences.values()), differences

      with subtest("an invalid GRUB environment block is made afresh"):
          machine.succeed("printf garbage > /boot/grub/nixhost/env", "systemctl restart nixhost-boot.service")
          machine.succeed("head -c 24 /boot/grub/nixhost/env | grep -qx '# GRUB Environment Block'")
          s = status()
          assert s["trial"] == "confirmed" and s["check"] == "ok", s

      with subtest("on a trial, an unreachable git remote is retried past the health check's timeout, and the trial confirms"):
          slowremote = deploy("slowremote")
          reboot()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          s = status()
          assert s["bootId"] == boot_id() and s["trial"] == "pending" and s["check"] == "pending", s
          assert metric("nixhost_boot_trial") == "1"
          assert settle() == slowremote
          assert trial()["outcome"] == "confirmed", trial()
          # 5 s apart: past healthCheck.timeout's 20 s.
          retries = int(sh("journalctl -b -o cat -u nixhost-boot-check | grep -c 'checks failing: git-remote; retrying'"))
          assert retries >= 6, retries

      with subtest("a system that comes up but fails its boot check reboots into the confirmed one, through logind"):
          unhealthy = deploy("unhealthy")
          reboot()
          machine.start()
          wait_reset(within=300)
          assert boot() == slowremote
          machine.fail("grep -q nixhost.trial /proc/cmdline")
          t = trial()
          assert t["system"] == unhealthy and t["outcome"] == "failed-check" and "(extra)" in t["detail"], t
          machine.succeed(f"journalctl -b -1 -k -o cat | grep -q 'Command line:.*nixhost.trial={name(unhealthy)}'")
          machine.succeed("journalctl -b -1 -o cat -u nixhost-boot-check | grep -qx 'checks failed after boot: extra'")
          # Through logind, so the kubelet's graceful shutdown would run.
          machine.succeed("journalctl -b -1 -o cat -u nixhost-test-shutdown-signal | grep -A1 'member=PrepareForShutdown' | grep -q 'boolean true'")
          machine.fail("journalctl -b -1 -o cat -u nixhost-boot-revert | grep -q 'logind refused'")
          assert metric("nixhost_boot_reverts_total") == "1"
          machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'Trial boot reverted: The trial boot of {name(unhealthy)} ended failed-check'")
          # The revert opened the rollback breaker.
          assert breaker()["open"] is True and breaker()["reason"] == f"trial of {name(unhealthy)} reverted", breaker()
          assert metric("nixhost_rollback_breaker_open") == "1"

      with subtest("its reboot is held: no sentinel for kured, no reboot in the window or at the deadline"):
          machine.succeed("systemctl stop nixhost-reboot-policy.timer", "systemctl start nixhost-reboot-detect.service")
          required = json.loads(sh("cat /run/nixhost/reboot/required.json"))
          assert required["required"] and required["held"] == "trial-reverted", required
          machine.fail("test -e /run/reboot-required")
          machine.fail("test -e /run/nixhost/reboot/reboot-required")
          assert metric('nixhost_reboot_pending_held{reason="trial-reverted"}') == "1"
          assert metric("nixhost_reboot_pending") == "1"
          # 03:00 UTC eight days on: in the window, past the 7-day deadline.
          clock = sh("date +%s")
          machine.succeed("date -u -s \"$(date -u -d '+8 days' +%F) 03:00:00\"", "systemctl start nixhost-reboot-policy.service")
          machine.fail("systemctl is-active -q nixhost-deadline-reboot.service")
          # The policy records every reboot it starts before starting it. Not
          # its "waiting:" line: after the clock jump every overdue timer fires,
          # and journald can take the line in after the run has ended, without
          # the run's invocation ID.
          machine.fail("test -e /var/lib/nixhost-reboot/rebooting.json")
          assert "failed its trial boot" in sh("reboot-status")
          machine.succeed(f"date -u -s @{clock}")

      with subtest("another reboot boots the confirmed system and doesn't try the failed one"):
          reboot()
          assert boot() == slowremote
          machine.fail("grep -q nixhost.trial /proc/cmdline")
          assert trial()["outcome"] == "failed-check"
          machine.succeed("nixhost-boot retry", "test -e /run/reboot-required")

      with subtest("a block inhibitor doesn't stop a revert: logind refuses, so it starts reboot.target itself"):
          # With the rollback breaker open, a failing trial would stay up.
          machine.succeed("nixhost-breaker reset")
          blocked = deploy("blocked")
          reboot()
          machine.start()
          wait_reset(within=300)
          assert boot() == slowremote
          t = trial()
          assert t["system"] == blocked and t["outcome"] == "failed-check", t
          machine.succeed("journalctl -b -1 -o cat -u nixhost-test-block | grep -q .", "journalctl -b -1 -o cat -u nixhost-boot-revert | grep -q 'logind refused the reboot; starting reboot.target directly'")
          assert metric("nixhost_boot_reverts_total") == "2"

      with subtest("a power loss while arming: the trial isn't armed, isn't counted, and its reboot is held"):
          again = deploy("unhealthy")
          # What a shutdown records before it touches /boot; then the power goes.
          record = {"system": again, "confirmed": slowremote, "outcome": "not-armed", "detail": "the shutdown was cut off while arming it"}
          machine.succeed(f"echo {shlex.quote(json.dumps(record))} > /var/lib/nixhost-boot/trial.json", "sync")
          machine.crash()
          assert boot() == slowremote
          assert trial()["outcome"] == "not-armed", trial()
          assert metric("nixhost_boot_reverts_total") == "2"
          machine.succeed("systemctl start nixhost-reboot-detect.service")
          assert json.loads(sh("cat /run/nixhost/reboot/required.json"))["held"] == "trial-not-armed"
          machine.fail("test -e /run/reboot-required")
          machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'Trial boot not armed: A shutdown couldn.t set up the trial boot of {name(again)}'")

      with subtest("a full ESP at shutdown: nothing partial is left behind GRUB's default, no trial is armed, and its reboot is held"):
          freeze = deploy("freeze")
          freeze_initrd = sh(f"readlink -f {freeze}/initrd").removeprefix("/nix/store/").replace("/", "-")
          machine.succeed("dd if=/dev/zero of=/boot/nixhost-test-fill bs=1M 2>/dev/null || true", "truncate -s -4M /boot/nixhost-test-fill", "sync")
          reboot()
          assert boot() == slowremote
          t = trial()
          assert t["system"] == freeze and t["outcome"] == "not-armed" and "couldn't copy" in t["detail"], t
          machine.fail("ls /boot/grub/nixhost/kernels | grep -e '[.]tmp$'")
          machine.fail(f"test -e /boot/grub/nixhost/kernels/{freeze_initrd}")
          machine.fail("grep -q nixhost-trial /boot/grub/nixhost/boot.cfg")
          assert metric("nixhost_boot_reverts_total") == "2"
          machine.succeed("systemctl start nixhost-reboot-detect.service", "test ! -e /run/reboot-required")
          assert json.loads(sh("cat /run/nixhost/reboot/required.json"))["held"] == "trial-not-armed"
          machine.wait_until_succeeds("[ $(journalctl -t nixhost-notify | grep -c 'Trial boot not armed') = 2 ]")
          machine.succeed("rm /boot/nixhost-test-fill", "nixhost-boot retry", "test -e /run/reboot-required")

      with subtest("a kernel that stops in the initrd is reset by the watchdog, well before the deadline"):
          reboot()
          machine.start()
          took = wait_reset(within=${toString deadline} - 20)
          print(f"the watchdog reset the frozen trial {took:.0f} s after it started")
          assert boot() == slowremote
          t = trial()
          assert t["system"] == freeze and t["outcome"] == "hung", t
          assert metric("nixhost_boot_reverts_total") == "3"
    '';

    hangs = ''
      with subtest("a system whose initrd never finishes is reset at the deadline"):
          hang = deploy("hang")
          reboot()
          machine.start()
          took = wait_reset(within=${toString deadline} + 180)
          assert took >= ${toString deadline}, took
          assert boot() == base
          t = trial()
          assert t["system"] == hang and t["outcome"] == "hung", t
          assert metric("nixhost_boot_reverts_total") == "1"

      with subtest("a NixOS activation that hangs in the initrd is reset at the deadline"):
          activationhang = deploy("activationhang")
          reboot()
          machine.start()
          took = wait_reset(within=${toString deadline} + 180)
          assert took >= ${toString deadline}, took
          assert boot() == base
          t = trial()
          assert t["system"] == activationhang and t["outcome"] == "hung", t
          assert metric("nixhost_boot_reverts_total") == "2"

      with subtest("a trial shut down before its check passes ends unconfirmed: not counted, but held"):
          stuck = deploy("stuck")
          reboot()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.succeed(f"grep -q 'nixhost.trial={name(stuck)}' /proc/cmdline")
          s = status()
          assert s["trial"] == "pending" and s["check"] == "pending", s
          machine.shutdown()
          assert boot() == base
          t = trial()
          assert t["system"] == stuck and t["outcome"] == "unconfirmed", t
          assert metric("nixhost_boot_reverts_total") == "2"
          machine.succeed("systemctl start nixhost-reboot-detect.service")
          assert json.loads(sh("cat /run/nixhost/reboot/required.json"))["held"] == "trial-reverted"
          machine.succeed("nixhost-boot retry")

      with subtest("a trial whose boot check never finishes is reset by the stage-2 deadline, through logind"):
          # The hung trials above opened the rollback breaker (a hang still
          # reverts); with it open the deadline would leave the trial up.
          assert breaker()["open"] is True and breaker()["reason"] == f"trial of {name(activationhang)} reverted", breaker()
          machine.succeed("nixhost-breaker reset")
          reboot()
          machine.start()
          took = wait_reset(within=${toString deadline} + 120)
          assert took >= ${toString deadline}, took
          assert boot() == base
          t = trial()
          assert t["system"] == stuck and t["outcome"] == "deadline", t
          assert metric("nixhost_boot_reverts_total") == "3"
          machine.succeed("journalctl -b -1 -o cat -u nixhost-boot-deadline | grep -q 'rebooting into the confirmed system'")
          machine.fail("journalctl -b -1 -o cat -u nixhost-boot-deadline | grep -q 'logind refused'")
    '';

    md12 = ''
      with subtest("trials are off with /boot on md metadata 1.2, GRUB's default is left alone, and the admins hear once"):
          s = status()
          assert s["supported"] is False and s["trial"] == "none", s
          assert metric("nixhost_boot_trial_supported") == "0"
          assert metric("nixhost_boot_fallback_ready") == "0"
          machine.fail("test -e /boot/grub/nixhost/boot.cfg")
          machine.wait_until_succeeds("journalctl -t nixhost-notify | grep -q 'Trial boots are off: Trial boots can.t work on this box: /boot/grub is on md raid1 with metadata 1.2'")

      with subtest("a reboot boots the deployed system directly: no trial, no revert, no hold"):
          good = deploy("good")
          assert json.loads(sh("cat /run/nixhost/reboot/required.json")).get("held") is None
          machine.succeed("test -e /run/reboot-required")
          reboot()
          assert boot() == good
          machine.fail("grep -qE 'nixhost[.](trial|confirmed)=' /proc/cmdline")
          machine.fail("test -e /var/lib/nixhost-boot/trial.json")
          assert metric("nixhost_boot_reverts_total") == "0"
          machine.succeed("systemctl start nixhost-reboot-detect.service", "test ! -e /run/reboot-required")
          assert notices("Trial boots are off") == 1
    '';

    md10 = ''
      with subtest("trials run with /boot on md metadata 1.0 and ext4"):
          assert status()["supported"] is True
          assert metric("nixhost_boot_trial_supported") == "1"
          machine.succeed(f"grep -q 'nixhost.confirmed={name(base)}' /boot/grub/nixhost/boot.cfg")

      with subtest("a good trial confirms: GRUB cleared the flag on the ext4 members"):
          good = deploy("good")
          reboot()
          assert boot() == good
          machine.succeed(f"grep -q 'nixhost.trial={name(good)}' /proc/cmdline")
          assert trial()["outcome"] == "confirmed", trial()
          members = sh("ls /sys/block/$(basename $(readlink -f /dev/md/boot))/slaves").split()
          copies = [sh(f"debugfs -R 'cat /grub/nixhost/env' /dev/{m} 2>/dev/null | sed -n 's/^nixhost_trial=//p'") for m in members]
          assert copies == ["", ""], copies

      with subtest("a failing trial reverts to the confirmed one"):
          unhealthy = deploy("unhealthy")
          reboot()
          machine.start()
          wait_reset(within=300)
          assert boot() == good
          t = trial()
          assert t["system"] == unhealthy and t["outcome"] == "failed-check", t
          assert metric("nixhost_boot_reverts_total") == "1"
          assert breaker()["open"] is True

      with subtest("with the rollback breaker open, a failing trial stays up, held, and the admins hear"):
          machine.succeed("nixhost-boot retry")
          reboot()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_until_succeeds("[ $(systemctl show -p ExecMainExitTimestampMonotonic --value nixhost-boot-revert) != 0 ]", timeout=300)
          assert sh("readlink -f /run/booted-system") == unhealthy
          machine.succeed(f"grep -q 'nixhost.trial={name(unhealthy)}' /proc/cmdline")
          t = trial()
          assert t["system"] == unhealthy and t["outcome"] == "held" and "rollback breaker is open" in t["detail"], t
          s = status()
          assert s["trial"] == "held" and s["check"] == "failed", s
          assert metric("nixhost_boot_reverts_total") == "1"
          assert metric("nixhost_rollback_breaker_blocked_total") == "1"
          machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'critical: Trial boot held: The trial boot of {name(unhealthy)} would revert'")
          # The stage-2 deadline doesn't reboot a held trial either.
          machine.succeed("systemctl start nixhost-boot-deadline.service")
          assert trial()["outcome"] == "held"

      # The pre-arm hook (preArm) exits with the code in this file.
      with subtest("a pre-arm hook that exits 10 boots the next system without a trial, as the confirmed one"):
          skip = deploy("skip")
          machine.succeed("echo 10 > /var/lib/nixhost-test-pre-arm")
          reboot()
          assert boot() == skip
          machine.fail("grep -q nixhost.trial /proc/cmdline")
          machine.succeed(f"grep -q 'nixhost.confirmed={name(skip)}' /proc/cmdline")
          assert sh("cat /var/lib/nixhost-test-pre-arm.args") == f"{skip} {good}"
          t = trial()
          assert t["system"] == skip and t["confirmed"] == good and t["outcome"] == "skipped" and t["detail"] == "the pre-arm hook skipped its trial", t
          assert sh("readlink -f /var/lib/nixhost-boot/confirmed") == skip
          s = status()
          assert s["trial"] == "none" and s["check"] == "ok", s
          assert metric("nixhost_boot_reverts_total") == "1"
          machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'Booted without a trial: {name(skip)} booted without a trial'")
          machine.succeed("systemctl start nixhost-reboot-detect.service", "test ! -e /run/reboot-required")

      with subtest("a pre-arm hook that fails arms nothing: the confirmed system boots, and the reboot is held"):
          again = deploy("good")
          machine.succeed("echo 1 > /var/lib/nixhost-test-pre-arm")
          reboot()
          assert boot() == skip
          machine.fail("grep -q nixhost.trial /proc/cmdline")
          t = trial()
          assert t["system"] == again and t["outcome"] == "not-armed" and t["detail"] == "the pre-arm hook exited 1", t
          assert metric("nixhost_boot_reverts_total") == "1"
          machine.succeed("systemctl start nixhost-reboot-detect.service", "test ! -e /run/reboot-required")
          assert json.loads(sh("cat /run/nixhost/reboot/required.json"))["held"] == "trial-not-armed"
          machine.wait_until_succeeds(f"journalctl -t nixhost-notify | grep -q 'Trial boot not armed: A shutdown couldn.t set up the trial boot of {name(again)}: the pre-arm hook exited 1'")

      with subtest("a system whose rollback guard differs boots without a trial, as the confirmed one"):
          guarded = deploy("guarded")
          machine.succeed("echo 0 > /var/lib/nixhost-test-pre-arm")
          reboot()
          assert boot() == guarded
          machine.fail("grep -q nixhost.trial /proc/cmdline")
          assert sh("cat /var/lib/nixhost-test-pre-arm.args") == f"{guarded} {skip}"
          t = trial()
          assert t["system"] == guarded and t["outcome"] == "skipped" and t["detail"] == "the rollback guard differs: k3s", t
          assert sh("readlink -f /var/lib/nixhost-boot/confirmed") == guarded
    '';
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs efi;
  name = "reboot-trial-${scenario}-${if efi then "uefi" else "bios"}";
  disko-config = if mdBoot then mdBootLayout else import ../../modules/raid1-layout.nix disks;
  extraInstallerConfig.boot.kernelPackages = pkgs.linuxPackages_latest;
  extraSystemConfig =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.base
        self.nixosModules.deploy
        self.nixosModules.reboot-interactive
      ]
      ++ (
        if mdBoot then
          [
            {
              boot.loader.grub.enable = true;
              boot.swraid.enable = true;
              # The installer's kernel made the arrays (see raid1-disks).
              boot.kernelPackages = pkgs.linuxPackages_latest;
            }
          ]
        else
          [
            self.nixosModules.raid1-disks
            {
              boot.loader.grub.efiSupport = lib.mkForce true;
              boot.loader.grub.efiInstallAsRemovable = lib.mkForce true;
              ethpandaops.raid1.disks = disks;
            }
          ]
      );
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
        # Exits with the code in /var/lib/nixhost-test-pre-arm (0 without
        # it), and records what it was given.
        preArm = ''
          echo "$1 $2" >/var/lib/nixhost-test-pre-arm.args
          exit "$(cat /var/lib/nixhost-test-pre-arm 2>/dev/null || echo 0)"
        '';
      };
      # Reset soon after the watchdog stops being fed.
      boot.initrd.systemd.settings.Manager.RuntimeWatchdogSec = "10s";
      environment.systemPackages = [
        pkgs.mtools
        pkgs.e2fsprogs
      ];
      specialisation = specialisations.${scenario};
    };
  extraTestScript = ''
    import json
    import time

    def sh(command):
        return machine.succeed(command).strip()

    def name(system):
        return system.split("/")[-1]

    def settle():
        # This boot's checks have passed and nixhost-boot-confirm has run.
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds("[ $(systemctl show -p ExecMainExitTimestampMonotonic --value nixhost-boot-confirm) != 0 ]", timeout=300)
        return sh("readlink -f /run/booted-system")

    def boot():
        machine.start()
        return settle()

    def system(spec):
        return sh(f"readlink -f {base}/specialisation/{spec}")

    def deploy(spec):
        # What comin's switch leaves the bootloader with: the new system as its default.
        new = system(spec)
        machine.succeed(f"{new}/bin/switch-to-configuration boot", "sync", "systemctl start nixhost-reboot-detect.service")
        return new

    def reboot():
        # Without waiting for an answer: execute() otherwise reads the output
        # and then asks the shell for the exit status, and the guest can be
        # gone by then (BrokenPipeError).
        machine.execute("systemctl --no-block reboot", check_output=False)
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

    def status():
        return json.loads(sh("cat /run/nixhost/boot/status.json"))

    def breaker():
        return json.loads(sh("cat /var/lib/nixhost-deploy/breaker.json"))

    def boot_id():
        return sh("cat /proc/sys/kernel/random/boot_id")

    def metric(series):
        # The value of the line that starts with this series.
        return sh(f"awk -v s={shlex.quote(series + ' ')} 'index($0, s) == 1 {{ print $NF; exit }}' /var/lib/node-exporter/*.prom")

    def notices(title):
        return int(sh(f"journalctl -t nixhost-notify -o cat | grep -cF '{title}: ' || true"))

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

    ${scripts.${scenario}}
  '';
}
