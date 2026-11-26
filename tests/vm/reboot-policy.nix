# The reboot policy end to end, driving the clock by hand:
# - a system set to boot that isn't running yet (a `boot` deploy) needs one;
# - a pause moves the planned reboot to the first window after it;
# - a kernel change shows up in notices and in the panda an SSH login with a
#   terminal gets, worked out at login; a held reboot shows there too, and
#   nothing does when no reboot is pending or the session has no terminal;
# - in the window, a login, an inhibitor or a hold each stop the reboot;
# - with nothing in the way the box reboots, and says so when it's back;
# - a new kernel series waits for an admin, who reboots with reboot-at;
# - at the deadline it reboots despite a login and an inhibitor.
{ self, pkgs, ... }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
{
  name = "reboot-policy";

  nodes.machine = {
    imports = [
      self.nixosModules.base
      self.nixosModules.reboot-interactive
      ./notify-sink.nix
    ];
    ethpandaops.users.alice = {
      uid = 1001;
      sudo = true;
      keys = [ keys.snakeOilPublicKey ];
      notify = [
        {
          type = "webhook";
          url = "http://127.0.0.1:8000/";
        }
      ];
    };
    ethpandaops.reboot = {
      window = {
        start = "02:00";
        end = "05:00";
      };
      minDelay = "1h";
      maxDelay = "2d";
      deadlineWarningMinutes = 1;
      # Before the clock the test sets for everything else.
      pauseUntil = "2029-12-31";
    };
    # The test sets the clock itself.
    services.timesyncd.enable = false;
    # A system to name as the boot default.
    specialisation.params.configuration.boot.kernelParams = [ "nixhost.test=1" ];
  };

  testScript = ''
    import re

    def policy():
        machine.succeed("systemctl start nixhost-reboot-policy.service")

    def assert_still_up(blocker):
        policy()
        machine.succeed("true")
        machine.fail("systemctl is-active -q nixhost-deadline-reboot.service")
        # The policy records every reboot it starts before starting it. Not its
        # "waiting:" line: journald can take that in after the run has ended,
        # such as while it rotates after the clock is set back, and then
        # without the run's invocation ID.
        machine.fail("test -e /var/lib/nixhost-reboot/rebooting.json")

    def boot():
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("notify-sink.service")
        # Policy runs are driven by the test, not the timers.
        machine.succeed("systemctl stop nixhost-reboot-policy.timer nixhost-reboot-detect.timer")
        machine.succeed("install -m 600 ${keys.snakeOilPrivateKey} /root/key")

    def fake_kernel_update(version):
        # /run/current-system becomes a copy of the booted system with another kernel.
        machine.succeed(
            f"mkdir -p /tmp/store/x-linux-{version}/lib/modules/{version} /tmp/new-system",
            "for f in /run/booted-system/*; do ln -sfn $(readlink -f $f) /tmp/new-system/$(basename $f); done",
            f"ln -sfn /tmp/store/x-linux-{version}/bzImage /tmp/new-system/kernel",
            f"ln -sfn /tmp/store/x-linux-{version} /tmp/new-system/kernel-modules",
            "ln -sfn /tmp/new-system /run/current-system",
        )

    def login(name):
        machine.succeed(f"systemd-run --unit={name} ssh -i /root/key -o StrictHostKeyChecking=no -o BatchMode=yes alice@localhost sleep 600")
        machine.wait_until_succeeds("loginctl list-sessions --json=short | jq -e 'any(.[]; .user == \"alice\")'")

    def logout(name):
        machine.succeed(f"systemctl stop {name}")
        machine.wait_until_succeeds("nixhost-reboot status > /tmp/status && ! grep -q 'logged in now: alice' /tmp/status")

    def ssh(args):
        return machine.succeed(f"ssh -q -i /root/key -o StrictHostKeyChecking=no {args} 2>&1")

    def interactive_login():
        # What a person sees: a shell on a terminal.
        return machine.succeed("echo exit | ssh -tt -i /root/key -o StrictHostKeyChecking=no alice@localhost 2>&1")

    boot()
    # A patch release of the booted kernel's series, and a kernel of another series.
    booted_kernel = machine.succeed("ls /run/booted-system/kernel-modules/lib/modules").strip()
    patch_kernel = ".".join(booted_kernel.split(".")[:2]) + ".999"
    series_kernel = "9.9.9"

    with subtest("nothing pending on a fresh boot, and nothing at login"):
        policy()
        machine.succeed("test ! -e /run/reboot-required")
        assert "No reboot pending" in machine.succeed("reboot-status")
        assert machine.succeed("nixhost-reboot login") == ""
        login_output = interactive_login()
        assert "REBOOT" not in login_output and "reboot-status" not in login_output, login_output

    with subtest("a kernel parameter change needs a reboot"):
        machine.succeed(
            "mkdir -p /tmp/params-system",
            "for f in /run/booted-system/*; do ln -sfn $(readlink -f $f) /tmp/params-system/$(basename $f); done",
            "rm /tmp/params-system/kernel-params",
            "echo \"$(cat /run/booted-system/kernel-params) audit=1\" > /tmp/params-system/kernel-params",
            "ln -sfn /tmp/params-system /run/current-system",
            "systemctl start nixhost-reboot-detect.service",
        )
        assert machine.succeed("cat /run/reboot-required.components").split() == ["kernel-params"]
        # A system with the same parameters in its own file needs none.
        machine.succeed(
            "cp --remove-destination /run/booted-system/kernel-params /tmp/params-system/kernel-params",
            "systemctl start nixhost-reboot-detect.service",
            "test ! -e /run/reboot-required",
            "ln -sfn $(readlink -f /run/booted-system) /run/current-system",
        )

    with subtest("a system set to boot that isn't running yet needs a reboot"):
        # What comin's `boot` deploy leaves: the bootloader's default entry
        # names a system that neither runs nor booted.
        params = machine.succeed("readlink -f /run/booted-system/specialisation/params").strip()
        machine.succeed(
            "mkdir -p /boot/grub",
            f"printf '%s\\n' 'menuentry \"NixOS\" {{' '  linux /kernels/bzImage init={params}/init' '}}' > /boot/grub/grub.cfg",
            "systemctl start nixhost-reboot-detect.service",
        )
        assert machine.succeed("cat /run/reboot-required.components").split() == ["boot-default", "kernel-params"]
        machine.succeed("test -e /run/nixhost/reboot/reboot-required")
        # The booted system as the boot default: nothing waits.
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        machine.succeed(
            f"printf '%s\\n' 'menuentry \"NixOS\" {{' '  linux /kernels/bzImage init={booted}/init' '}}' > /boot/grub/grub.cfg",
            "systemctl start nixhost-reboot-detect.service",
            "test ! -e /run/reboot-required",
            "test ! -e /run/nixhost/reboot/reboot-required",
            "rm /boot/grub/grub.cfg",
        )

    with subtest("a pause moves the planned reboot to the first window after it"):
        # Sun 30 Dec, paused until Mon 31 Dec 00:00: not tonight's 02:00 window, but Monday's.
        machine.succeed("date -u -s '2029-12-30 00:00:00'")
        fake_kernel_update(patch_kernel)
        policy()
        machine.succeed("date -u -s '2029-12-30 00:00:00'")
        status = machine.succeed("reboot-status")
        print(status)
        assert "Mon 31 Dec 02:00 UTC" in status and "in 1d 2h, if nobody is logged in" in status, status
        assert "Paused     by the admins until Mon 31 Dec 00:00 UTC (in 1d 0h)" in status, status
        assert "planned Mon 31 Dec 02:00 UTC" in machine.succeed("cat /run/nixhost/reboot/status-line")
        machine.succeed("grep -qx 'nixhost_reboot_planned_timestamp_seconds 1893376800' /var/lib/node-exporter/nixhost_reboot_policy.prom")
        # In tonight's window it waits, and still plans Monday, not "now".
        machine.succeed("date -u -s '2029-12-30 02:30:00'")
        assert_still_up("the pause")
        assert "Mon 31 Dec 02:00 UTC" in machine.succeed("reboot-status")
        # Back on the booted system, nothing is pending.
        machine.succeed("ln -sfn $(readlink -f /run/booted-system) /run/current-system")
        policy()
        machine.succeed("test ! -e /run/reboot-required")

    with subtest("a kernel change is detected and announced"):
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        fake_kernel_update(patch_kernel)
        policy()
        machine.succeed("test -e /run/reboot-required")
        machine.succeed("grep -qx 'nixhost_reboot_pending 1' /var/lib/node-exporter/nixhost_reboot_detect.prom")
        machine.succeed("grep -qx 'nixhost_reboot_supervised 0' /var/lib/node-exporter/nixhost_reboot_policy.prom")
        machine.succeed("grep -q 'A reboot is pending' /var/lib/notify-sink.log")
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        login_output = interactive_login()
        print(login_output)
        assert "(###)._______.(###)" in login_output and "REBOOT COMING!" in login_output, login_output
        assert f"Why        kernel {booted_kernel} -> {patch_kernel}" in login_output, login_output
        assert "a new kernel series" not in login_output, login_output
        assert "Since      Tue 01 Jan 00:00 UTC" in login_output, login_output
        # minDelay is 1h, so the first window is 02:00 that night.
        assert "Tue 01 Jan 02:00 UTC" in login_output and re.search(r"in (2h 0m|1h 59m), if nobody is logged in", login_output), login_output
        assert re.search(r"Deadline   Thu 03 Jan 00:00 UTC \(in (2d 0h|1d 23h)\): reboots even if you're busy", login_output), login_output
        assert "everyone to log out (logged in now: alice)" in login_output, login_output
        assert "reboot-hold 3d" in login_output and "systemd-inhibit" not in login_output, login_output
        # Worked out at login: half an hour on, with no policy run since, the ETA has moved.
        machine.succeed("date -u -s '2030-01-01 00:30:00'")
        login_output = interactive_login()
        assert re.search(r"in 1h (30|29)m, if nobody is logged in", login_output), login_output

    with subtest("sessions without a shell on a terminal get nothing: commands and scp work as before"):
        assert ssh("alice@localhost echo hello") == "hello\n"
        assert ssh("-tt alice@localhost echo hello").replace("\r", "") == "hello\n"
        machine.succeed(
            "head -c 100000 /dev/urandom > /tmp/blob",
            "scp -q -i /root/key -o StrictHostKeyChecking=no /tmp/blob alice@localhost:blob",
            "scp -q -i /root/key -o StrictHostKeyChecking=no alice@localhost:blob /tmp/blob.back",
            "cmp /tmp/blob /tmp/blob.back",
        )

    with subtest("open shells show the status line when it changes, not again at a login"):
        prompt = machine.succeed("su - alice -c 'bash -i </dev/null' 2>&1")
        assert "Reboot pending" not in prompt, prompt
        prompt = machine.succeed("echo 'echo A changed line > /run/nixhost/reboot/status-line' | su - root -c 'bash -i' 2>&1")
        assert prompt.count("*** A changed line") == 1 and "Reboot pending" not in prompt, prompt
        policy()

    with subtest("a reboot held after a failed trial says so at login, with no deadline"):
        machine.succeed(
            "cp /run/nixhost/reboot/required.json /tmp/required.json",
            "jq '.held = \"trial-reverted\"' /tmp/required.json > /run/nixhost/reboot/required.json",
        )
        login_output = interactive_login()
        print(login_output)
        assert "REBOOT PENDING, BUT HELD" in login_output and "failed its trial boot" in login_output, login_output
        assert "sudo nixhost-boot retry" in login_output, login_output
        assert "Deadline" not in login_output and "REBOOT COMING" not in login_output, login_output
        machine.succeed("cp /tmp/required.json /run/nixhost/reboot/required.json")

    with subtest("outside the window it waits"):
        assert_still_up("being outside the window")

    machine.succeed("date -u -s '2030-01-01 02:30:00'")

    with subtest("in the window, a logged-in user stops it"):
        login("session1")
        assert_still_up("a login")
        # The next policy run, on the quarter hour: 02:30 itself if the clock hasn't moved on.
        status = machine.succeed("reboot-status")
        assert re.search(r"Tue 01 Jan 02:(30|45) UTC", status) and "everyone to log out (logged in now: alice)" in status, status

    with subtest("an inhibitor stops it"):
        machine.succeed("systemd-run --unit=longjob systemd-inhibit --what=shutdown --why=longjob /run/current-system/sw/bin/sleep 600")
        logout("session1")
        assert_still_up("an inhibitor")
        assert "longjob" in machine.succeed("reboot-status")

    with subtest("a hold stops it"):
        machine.succeed("reboot-hold 1h")
        machine.succeed("systemctl stop longjob")
        assert_still_up("a hold")
        status = machine.succeed("reboot-status")
        assert "On hold    by root (reboot-hold) until Tue 01 Jan 03:3" in status, status
        machine.succeed("grep -q 'held the reboot' /var/lib/notify-sink.log")

    with subtest("with nothing in the way it reboots"):
        machine.succeed("rm /run/nixhost/reboot/hold-until")
        machine.execute("systemctl start --no-block nixhost-reboot-policy.service")
        machine.wait_for_shutdown()

    boot()

    with subtest("after the reboot nothing is pending and users hear it's back"):
        policy()
        machine.succeed("test ! -e /run/reboot-required")
        machine.succeed("grep -q 'is back after its reboot (nightly window' /var/lib/notify-sink.log")

    with subtest("a new kernel series waits for an admin, in the window and past the deadline"):
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        fake_kernel_update(series_kernel)
        policy()
        status = machine.succeed("reboot-status")
        print(status)
        assert f"kernel {booted_kernel} -> {series_kernel}" in status, status
        assert "REBOOT PENDING" in status and "a new kernel series, so an admin" in status, status
        assert "Thu 03 Jan 00:00 UTC" in status and "the admins', not a reboot" in status, status
        assert "REBOOT COMING" not in status, status
        machine.succeed("grep -q 'an admin will schedule it' /var/lib/notify-sink.log")
        machine.succeed("journalctl -t nixhost-notify | grep -q '(admins) .*it needs a supervised reboot'")
        # In the window, past the deadline, nobody logged in: it still waits.
        machine.succeed("date -u -s '2030-01-04 03:00:00'")
        assert_still_up("a new kernel series")
        machine.succeed("grep -qx 'nixhost_reboot_supervised 1' /var/lib/node-exporter/nixhost_reboot_policy.prom")

    with subtest("an admin's reboot-at reboots it, even after the deadline"):
        status = machine.succeed("reboot-at '2030-01-04 03:30'")
        assert "Fri 04 Jan 03:30 UTC" in status and "set by root with reboot-at" in status, status
        machine.succeed("date -u -s '2030-01-04 03:31:00'")
        machine.execute("systemctl start --no-block nixhost-reboot-policy.service")
        machine.wait_for_shutdown()

    boot()

    with subtest("at the deadline it reboots despite a login and an inhibitor"):
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        fake_kernel_update(patch_kernel)
        policy()
        machine.succeed("date -u -s '2030-01-03 00:30:00'")
        login("session2")
        machine.succeed("systemd-run --unit=longjob2 systemd-inhibit --what=shutdown --why=longjob /run/current-system/sw/bin/sleep 600")
        policy()
        status = machine.succeed("reboot-status")
        assert "REBOOTING SOON! SAVE YOUR WORK!" in status and "the deadline has passed" in status, status
        machine.succeed("grep -q 'Deadline reached' /var/lib/notify-sink.log")
        machine.wait_for_shutdown()
  '';
}
