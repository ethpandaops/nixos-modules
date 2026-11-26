# Named checks (ethpandaops.checks): unit, HTTP and script checks of both
# kinds next to the built-in ones; the status file and its verdicts
# (readiness pending after a deploy, failed past its timeout, then ok), the
# nixhost_check_ok metrics, checks running at once, and an outside check
# that fails alone giving the deployed system a second try rather than
# counting as a local failure.
{
  self,
  lib,
  pkgs,
  ...
}:
let
  revision = "0123456789abcdef0123456789abcdef01234567";
in
{
  name = "checks";

  nodes.machine =
    { config, ... }:
    {
      imports = [
        self.nixosModules.base
        self.nixosModules.deploy
      ];
      ethpandaops.deploy = {
        # comin isn't run here, nor the git remote checked.
        repository = "/var/lib/remote.git";
        deployKeyFile = null;
        healthCheck = {
          timeout = 10;
          checkRemote = false;
        };
      };
      # The default dnsName, without internet access.
      networking.hosts."192.0.2.1" = [ "github.com" ];
      services.comin.enable = lib.mkForce false;
      environment.etc."test-post-deploy".source = config.services.comin.postDeploymentCommand;
      system.configurationRevision = revision;

      systemd.services.nixhost-test-unit = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
      systemd.services.nixhost-test-web = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          RuntimeDirectory = "www";
          RuntimeDirectoryPreserve = true;
          ExecStart = "${pkgs.python3.interpreter} -m http.server --bind 127.0.0.1 --directory /run/www 8080";
        };
      };

      ethpandaops.checks = {
        test-unit.unit = "nixhost-test-unit.service";
        web.http = "http://127.0.0.1:8080/";
        file.script = ''
          if [ -e /run/fail-file ]; then
            echo "/run/fail-file is there"
            exit 1
          fi
          echo "no /run/fail-file"
        '';
        # Fails only on the system named in /run/outside-bad.
        upstream = {
          outside = true;
          script = ''
            if [ "$(readlink -f /run/current-system)" = "$(cat /run/outside-bad 2>/dev/null || true)" ]; then
              echo "unreachable from this system"
              exit 1
            fi
            echo "reachable"
          '';
        };
        ready-file = {
          kind = "readiness";
          timeout = 40;
          script = ''
            if [ ! -e /run/ready ]; then
              echo "no /run/ready"
              exit 1
            fi
            echo "/run/ready is there"
          '';
        };
        ready-web = {
          kind = "readiness";
          timeout = 40;
          http = "http://127.0.0.1:8080/ready";
        };
        # Each takes 20 s while /run/slow is there.
        slow-a = {
          kind = "readiness";
          script = "if [ -e /run/slow ]; then sleep 20; fi; echo finished";
        };
        slow-b = {
          kind = "readiness";
          script = "if [ -e /run/slow ]; then sleep 20; fi; echo finished";
        };
      };

      specialisation.other.configuration.environment.etc."checks-test".text = "other";
    };

  testScript =
    { nodes, ... }:
    ''
      import json
      import time

      post_deploy = "${nodes.machine.services.comin.postDeploymentCommand}"

      def sh(command):
          return machine.succeed(command).strip()

      def deployed(sha):
          machine.succeed(f"COMIN_STATUS=done COMIN_GIT_SHA={sha} COMIN_GIT_REF=origin/deploy {post_deploy}")

      def check_finished(result="success"):
          machine.wait_until_succeeds("systemctl show -p ActiveState --value nixhost-health-check | grep -qxE 'inactive|failed'", timeout=180)
          assert sh("systemctl show -p Result --value nixhost-health-check") == result

      def status():
          return json.loads(sh("cat /run/nixhost/checks/status.json"))

      def periodic():
          machine.succeed("systemctl start nixhost-checks.service")
          return status()

      def metric(series):
          # The sample's line only, not its # HELP and # TYPE lines.
          return sh(f"awk -v s='{series}' '$1 == s {{ print $2 }}' /var/lib/node-exporter/nixhost_checks.prom")

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_open_port(8080)
      # The periodic run is on a timer; the test runs it itself.
      machine.succeed("systemctl is-active nixhost-checks.timer", "systemctl stop nixhost-checks.timer nixhost-checks.service")
      good = sh("readlink -f /run/current-system")

      with subtest("a deploy records every check; readiness is pending while a readiness check fails within its timeout"):
          deployed("1111111111111111")
          machine.wait_until_succeeds("test -L /var/lib/nixhost-deploy/last-good")
          check_finished()
          s = status()
          deployment = json.loads(sh("cat /run/nixhost-deploy/deployment.json"))
          assert s["phase"] == "deploy" and s["system"] == good and s["revision"] == "${revision}", s
          assert s["since"] == deployment["at"], (s, deployment)
          assert s["health"] == "ok" and s["readiness"] == "pending", s
          assert sorted(s["checks"]) == ["default-route", "dns", "file", "firewall", "ready-file", "ready-web", "slow-a", "slow-b", "sshd", "test-unit", "upstream", "web"], s
          assert s["checks"]["test-unit"] == {"kind": "health", "outside": False, "ok": True, "since": s["checks"]["test-unit"]["since"], "message": "nixhost-test-unit.service is active", "timeout": 10}, s
          assert s["checks"]["web"]["message"] == "http://127.0.0.1:8080/ answered 200", s
          assert s["checks"]["dns"]["outside"] and s["checks"]["upstream"]["outside"], s
          ready = s["checks"]["ready-file"]
          assert ready["kind"] == "readiness" and not ready["ok"] and ready["message"] == "no /run/ready" and ready["timeout"] == 40, ready
          assert s["checks"]["ready-web"]["message"] == "http://127.0.0.1:8080/ready answered 404", s
          assert metric('nixhost_check_ok{check="test-unit",kind="health"}') == "1"
          assert metric('nixhost_check_ok{check="ready-file",kind="readiness"}') == "0"
          assert metric("nixhost_checks_health_ok") == "1"
          assert metric('nixhost_checks_readiness{verdict="pending"}') == "1"
          assert metric('nixhost_checks_readiness{verdict="ok"}') == "0"

      with subtest("readiness fails once a readiness check still fails past its timeout"):
          retry(lambda _: periodic()["readiness"] == "failed", timeout_seconds=90)
          s = status()
          assert s["phase"] == "periodic" and s["updatedAt"] >= s["since"] + 40, s
          assert metric('nixhost_checks_readiness{verdict="failed"}') == "1"

      with subtest("readiness is ok once every readiness check passes; a check's since moves when its result does"):
          before = status()["checks"]
          machine.succeed("touch /run/ready /run/www/ready")
          time.sleep(1)
          s = periodic()
          assert s["readiness"] == "ok" and s["health"] == "ok", s
          assert s["checks"]["ready-file"]["ok"] and s["checks"]["ready-file"]["since"] > before["ready-file"]["since"], (before, s)
          assert s["checks"]["sshd"]["since"] == before["sshd"]["since"], (before, s)
          assert metric('nixhost_check_ok{check="ready-file",kind="readiness"}') == "1"
          assert metric('nixhost_check_ok{check="ready-web",kind="readiness"}') == "1"
          assert metric('nixhost_checks_readiness{verdict="ok"}') == "1"

      with subtest("the periodic run reports a failing health check, once, without rolling anything back"):
          machine.succeed("systemctl stop nixhost-test-unit.service", "touch /run/fail-file")
          s = periodic()
          assert s["health"] == "failed", s
          assert s["checks"]["test-unit"]["message"] == "nixhost-test-unit.service is inactive", s
          assert s["checks"]["file"]["message"] == "/run/fail-file is there", s
          assert metric('nixhost_check_ok{check="test-unit",kind="health"}') == "0"
          assert metric("nixhost_checks_health_ok") == "0"
          assert sh("readlink -f /run/current-system") == good
          machine.succeed("systemctl start nixhost-test-unit.service", "rm /run/fail-file")
          assert periodic()["health"] == "ok"

      with subtest("the checks run at once: two that take 20 s each finish together"):
          machine.succeed("touch /run/slow")
          started = time.monotonic()
          machine.succeed("systemctl start nixhost-checks.service")
          took = time.monotonic() - started
          print(f"two 20 s checks took {took:.1f} s")
          assert 20 <= took < 32, took
          assert status()["checks"]["slow-a"]["message"] == "finished"
          machine.succeed("rm /run/slow")

      with subtest("an outside check failing alone isn't a local failure: the deployed system gets a second try"):
          other = sh(f"readlink -f {good}/specialisation/other")
          machine.succeed(f"{other}/bin/switch-to-configuration test", f"echo {other} > /run/outside-bad")
          deployed("2222222222222222")
          machine.wait_until_succeeds(f"journalctl -o cat -u nixhost-health-check | grep -q 'only checks that depend on the outside failed on {other}; trying it again'", timeout=180)
          check_finished()
          machine.succeed(f"journalctl -o cat -u nixhost-health-check | grep -q 'checks fail on {other} again: upstream; back to {good}'")
          machine.succeed("journalctl -t nixhost-notify | grep -q 'Health check failed (upstream) after deploying 222222222222; rolling back'")
          assert sh("readlink -f /run/current-system") == good
          s = status()
          assert s["health"] == "ok" and s["checks"]["upstream"]["ok"], s
    '';
}
