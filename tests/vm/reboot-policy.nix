# The reboot policy end to end, driving the clock by hand:
# - a kernel change shows up in the login message, the prompt and notices;
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
    };
    # The test sets the clock itself.
    services.timesyncd.enable = false;
  };

  testScript = ''
    def policy():
        machine.succeed("systemctl start nixhost-reboot-policy.service")

    def assert_still_up(blocker):
        policy()
        machine.succeed("true")
        machine.fail("systemctl is-active -q nixhost-deadline-reboot.service")
        last_run = machine.succeed("journalctl -o cat _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value nixhost-reboot-policy)")
        assert "waiting:" in last_run, last_run

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
        machine.wait_until_succeeds("nixhost-reboot status > /tmp/status && ! grep -q 'Logged in now: alice' /tmp/status")

    boot()
    # A patch release of the booted kernel's series, and a kernel of another series.
    booted_kernel = machine.succeed("ls /run/booted-system/kernel-modules/lib/modules").strip()
    patch_kernel = ".".join(booted_kernel.split(".")[:2]) + ".999"
    series_kernel = "9.9.9"

    with subtest("nothing pending on a fresh boot"):
        policy()
        machine.succeed("test ! -e /run/reboot-required")
        assert "No reboot pending" in machine.succeed("reboot-status")

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

    with subtest("a kernel change is detected and announced"):
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        fake_kernel_update(patch_kernel)
        policy()
        machine.succeed("test -e /run/reboot-required")
        machine.succeed("grep -qx 'nixhost_reboot_pending 1' /var/lib/node-exporter/nixhost_reboot_detect.prom")
        machine.succeed("grep -qx 'nixhost_reboot_supervised 0' /var/lib/node-exporter/nixhost_reboot_policy.prom")
        motd = machine.succeed("cat /run/nixhost/reboot/motd")
        print(motd)
        assert f"Kernel security update waiting: {booted_kernel} -> {patch_kernel}" in motd, motd
        assert "a new kernel series" not in motd, motd
        assert "reboot-hold 3d" in motd and "systemd-inhibit" not in motd, motd
        assert "since Tue 01 Jan 00:00 UTC" in motd
        # minDelay is 1h, so the first window is 02:00 that night.
        assert "Planned reboot: Tue 01 Jan 02:00 UTC" in motd
        assert "Hard deadline:  Thu 03 Jan 00:00 UTC" in motd
        machine.succeed("grep -q 'A reboot is pending' /var/lib/notify-sink.log")
        # sshd shows the login message to interactive logins only.
        login_output = machine.succeed("echo exit | ssh -tt -i /root/key -o StrictHostKeyChecking=no alice@localhost 2>&1")
        assert "Kernel security update waiting" in login_output, login_output
        prompt = machine.succeed("su - alice -c 'bash -i </dev/null' 2>&1")
        assert "*** Reboot pending for an update: planned Tue 01 Jan 02:00 UTC" in prompt, prompt

    with subtest("outside the window it waits"):
        assert_still_up("being outside the window")

    machine.succeed("date -u -s '2030-01-01 02:30:00'")

    with subtest("in the window, a logged-in user stops it"):
        login("session1")
        assert_still_up("a login")

    with subtest("an inhibitor stops it"):
        machine.succeed("systemd-run --unit=longjob systemd-inhibit --what=shutdown --why=longjob /run/current-system/sw/bin/sleep 600")
        logout("session1")
        assert_still_up("an inhibitor")
        assert "longjob" in machine.succeed("reboot-status")

    with subtest("a hold stops it"):
        machine.succeed("reboot-hold 1h")
        machine.succeed("systemctl stop longjob")
        assert_still_up("a hold")
        assert "Held by root until Tue 01 Jan 03:30 UTC" in machine.succeed("cat /run/nixhost/reboot/motd")
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
        motd = machine.succeed("cat /run/nixhost/reboot/motd")
        print(motd)
        assert f"{booted_kernel} -> {series_kernel}, a new kernel series" in motd, motd
        assert "doesn't reboot by itself" in motd, motd
        assert "Admins' deadline: Thu 03 Jan 00:00 UTC" in motd, motd
        assert "Planned reboot" not in motd, motd
        machine.succeed("grep -q 'an admin will schedule it' /var/lib/notify-sink.log")
        machine.succeed("journalctl -t nixhost-notify | grep -q '(admins) .*it needs a supervised reboot'")
        # In the window, past the deadline, nobody logged in: it still waits.
        machine.succeed("date -u -s '2030-01-04 03:00:00'")
        assert_still_up("a new kernel series")
        machine.succeed("grep -qx 'nixhost_reboot_supervised 1' /var/lib/node-exporter/nixhost_reboot_policy.prom")

    with subtest("an admin's reboot-at reboots it, even after the deadline"):
        machine.succeed("reboot-at '2030-01-04 03:30'")
        assert "Planned reboot: Fri 04 Jan 03:30 UTC, as root asked with reboot-at" in machine.succeed("cat /run/nixhost/reboot/motd")
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
        assert "REBOOTING at" in machine.succeed("cat /run/nixhost/reboot/motd")
        machine.succeed("grep -q 'Deadline reached' /var/lib/notify-sink.log")
        machine.wait_for_shutdown()
  '';
}
