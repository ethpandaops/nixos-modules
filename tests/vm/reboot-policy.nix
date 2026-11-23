# The reboot policy end to end, driving the clock by hand:
# - a kernel change shows up in the login message, the prompt and notices;
# - in the window, a login, an inhibitor or a hold each stop the reboot;
# - with nothing in the way the box reboots, and says so when it's back;
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

    def fake_kernel_update():
        # /run/current-system becomes a copy of the booted system with another kernel.
        machine.succeed(
            "mkdir -p /tmp/store/x-linux-9.9.9/lib/modules/9.9.9 /tmp/new-system",
            "for f in /run/booted-system/*; do ln -sfn $(readlink -f $f) /tmp/new-system/$(basename $f); done",
            "ln -sfn /tmp/store/x-linux-9.9.9/bzImage /tmp/new-system/kernel",
            "ln -sfn /tmp/store/x-linux-9.9.9 /tmp/new-system/kernel-modules",
            "ln -sfn /tmp/new-system /run/current-system",
        )

    def login(name):
        machine.succeed(f"systemd-run --unit={name} ssh -i /root/key -o StrictHostKeyChecking=no -o BatchMode=yes alice@localhost sleep 600")
        machine.wait_until_succeeds("loginctl list-sessions --json=short | jq -e 'any(.[]; .user == \"alice\")'")

    def logout(name):
        machine.succeed(f"systemctl stop {name}")
        machine.wait_until_succeeds("nixhost-reboot status > /tmp/status && ! grep -q 'Logged in now: alice' /tmp/status")

    boot()

    with subtest("nothing pending on a fresh boot"):
        policy()
        machine.succeed("test ! -e /run/reboot-required")
        assert "No reboot pending" in machine.succeed("reboot-status")

    with subtest("a kernel change is detected and announced"):
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        fake_kernel_update()
        policy()
        machine.succeed("test -e /run/reboot-required")
        machine.succeed("grep -qx 'nixhost_reboot_pending 1' /var/lib/node-exporter/nixhost_reboot_detect.prom")
        motd = machine.succeed("cat /run/nixhost/reboot/motd")
        print(motd)
        assert "Kernel security update waiting: " in motd and "-> 9.9.9" in motd
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

    with subtest("at the deadline it reboots despite a login and an inhibitor"):
        machine.succeed("date -u -s '2030-01-01 00:00:00'")
        fake_kernel_update()
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
