# The post-deploy health check, with its real sshd, route, firewall, DNS and
# git checks: a healthy deployment becomes the last good system; a deployment
# that breaks SSH is rolled back to it, which opens the rollback breaker; while
# it's open a failing deploy stays, until `nixhost-breaker reset`; a deploy
# across a rollback guard change isn't rolled back, and a passing deploy
# closes the breaker; when the checks fail on both, the deployed system
# stays; an outage outside the box that ends during the rollback doesn't
# undo the deploy, but a deploy that breaks DNS is rolled back. The admins
# hear about each through Discord-style webhooks.
{ self, lib, ... }:
{
  name = "health-check";

  nodes.machine =
    { config, ... }:
    {
      imports = [
        self.nixosModules.base
        self.nixosModules.deploy
        ./notify-sink.nix
      ];
      ethpandaops.deploy = {
        # A local repo stands in for GitHub; comin itself isn't run here.
        repository = "/var/lib/remote.git";
        sourceBranch = "master";
        deployKeyFile = null;
        healthCheck = {
          timeout = 15;
          # Fails while /run/fail-health exists, on every system.
          extraScript = "[ ! -e /run/fail-health ]";
        };
      };
      # The default dnsName, without internet access.
      networking.hosts."192.0.2.1" = [ "github.com" ];
      services.comin.enable = lib.mkForce false;
      # comin's config keeps the hook in the system closure on a server; without
      # comin, keep it here, or Nix's auto-GC on the small VM disk deletes it.
      environment.etc."test-post-deploy".source = config.services.comin.postDeploymentCommand;
      ethpandaops.notify.admins = [
        {
          type = "discord";
          url = "http://127.0.0.1:8000/api/webhooks/1/native";
        }
        {
          type = "discord";
          url = "http://127.0.0.1:8000/api/webhooks/2/compat/slack";
        }
        {
          # Misconfigured on purpose: Discord rejects this body.
          type = "webhook";
          url = "http://127.0.0.1:8000/api/webhooks/3/wrong";
        }
      ];
      ethpandaops.rollback.guard.k3s = "1.33";
      specialisation.guarded.configuration.ethpandaops.rollback.guard.k3s = lib.mkForce "1.34";
      specialisation.broken.configuration.services.openssh.enable = lib.mkForce false;
      specialisation.other.configuration.environment.etc."health-check-test".text = "other";
      specialisation.nodns.configuration.networking.hosts."192.0.2.1" = lib.mkForce [ ];
      # Flake-built systems carry the nixpkgs commit date in their version
      # (the test framework forces "test", so override at a higher priority).
      system.nixos.versionSuffix = lib.mkOverride 10 ".20300101.0000000";
    };

  testScript =
    { nodes, ... }:
    ''
      import json

      post_deploy = "${nodes.machine.services.comin.postDeploymentCommand}"

      def deployed(status, sha):
          # What comin runs after each deployment; it starts the check without waiting.
          machine.succeed(f"COMIN_STATUS={status} COMIN_GIT_SHA={sha} COMIN_GIT_REF=origin/deploy {post_deploy}")

      def check_finished(result="success"):
          # Polled rather than `systemctl start`, whose bus connection drops
          # when a rollback re-executes systemd.
          machine.wait_until_succeeds("systemctl show -p ActiveState --value nixhost-health-check | grep -qxE 'inactive|failed'", timeout=120)
          assert machine.succeed("systemctl show -p Result --value nixhost-health-check").strip() == result

      def breaker():
          return json.loads(machine.succeed("cat /var/lib/nixhost-deploy/breaker.json"))

      def embeds(title):
          # The Discord embeds sent to the first webhook with this title.
          lines = [line.split(" ", 1) for line in machine.succeed("cat /var/lib/notify-sink.log").splitlines()]
          return [e for p, body in lines if p == "/api/webhooks/1/native" for e in json.loads(body)["embeds"] if e["title"] == title]

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("notify-sink.service")
      # Every minute nixhost-checks rewrites the status file; only the deploy runs here do.
      machine.succeed("systemctl stop nixhost-checks.timer nixhost-checks.service")
      machine.succeed(
          "git init -q -b deploy /tmp/work",
          "git -C /tmp/work -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init",
          "git clone -q --bare /tmp/work /var/lib/remote.git",
          # master, the source branch, has a commit deploy doesn't.
          "git -C /tmp/work checkout -q -b master",
          "git -C /tmp/work -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m next",
          "git -C /tmp/work push -q /var/lib/remote.git master",
      )
      good = machine.succeed("readlink -f /run/current-system").strip()

      with subtest("a healthy deployment, with the real route and DNS checks, is recorded as the last good system"):
          machine.succeed("ip route show default | grep -q .")
          deployed("done", "1111111111111111")
          machine.wait_until_succeeds("test -L /var/lib/nixhost-deploy/last-good")
          check_finished()
          assert machine.succeed("readlink /var/lib/nixhost-deploy/last-good").strip() == good
          machine.succeed("test -L /nix/var/nix/gcroots/nixhost-last-good")
          machine.succeed("grep -qx 'nixhost_healthcheck_ok 1' /var/lib/node-exporter/nixhost_healthcheck.prom")
          status = json.loads(machine.succeed("cat /run/nixhost/checks/status.json"))
          assert status["phase"] == "deploy" and status["health"] == "ok" and status["system"] == good, status
          assert sorted(status["checks"]) == ["default-route", "dns", "extra", "firewall", "git-remote", "sshd"], status
          assert status["checks"]["dns"]["outside"] and not status["checks"]["sshd"]["outside"], status

      with subtest("a deployment that breaks SSH is rolled back"):
          machine.succeed(f"{good}/specialisation/broken/bin/switch-to-configuration test")
          machine.succeed("test -z \"$(ss -Hltn 'sport = :22')\"")
          deployed("done", "2222222222222222")
          machine.wait_until_succeeds("grep -q 'checks pass again' /var/lib/notify-sink.log", timeout=180)
          check_finished()
          machine.wait_for_unit("sshd.service")
          machine.wait_for_open_port(22)
          assert machine.succeed("readlink -f /run/current-system").strip() == good
          machine.succeed("grep -qx 'nixhost_healthcheck_rollbacks_total 1' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("grep -qx 'nixhost_healthcheck_ok 1' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("grep -q 'sshd) after deploying 222222222222; rolling back' /var/lib/notify-sink.log")
          machine.succeed("grep -q 'checks pass again' /var/lib/notify-sink.log")

      with subtest("Discord gets an embed, or a Slack attachment on /slack, under the host's name; a rejection is logged with its reason"):
          sent = [line.split(" ", 1) for line in machine.succeed("cat /var/lib/notify-sink.log").splitlines()]
          def notice(path, title):
              bodies = [json.loads(body) for p, body in sent if p == path]
              key = "embeds" if "embeds" in bodies[0] else "attachments"
              return next(b for b in bodies if b[key][0]["title"] == title)
          native = notice("/api/webhooks/1/native", "Health check failed: rolling back")
          assert native["username"] == "machine", native
          assert native["allowed_mentions"] == {"parse": []}, native
          embed = native["embeds"][0]
          assert embed["description"].startswith("Health check failed (sshd) after deploying 222222222222; rolling back to /nix/store/"), embed
          assert embed["color"] == 15770634, embed
          assert {"name": "Host", "value": "machine", "inline": True} in embed["fields"], embed
          assert {"name": "Severity", "value": "warning", "inline": True} in embed["fields"], embed
          slack = notice("/api/webhooks/2/compat/slack", "Deploy rolled back")
          assert slack["username"] == "machine", slack
          attachment = slack["attachments"][0]
          assert attachment["color"] == "#F0A30A" and attachment["text"].startswith("Rolled back to /nix/store/"), attachment
          assert {"title": "Host", "value": "machine", "short": True} in attachment["fields"], attachment
          machine.fail("journalctl -t nixhost-notify | grep -q 'delivery to a discord target failed'")
          machine.succeed("journalctl -t nixhost-notify | grep -q 'delivery to a webhook target failed: .*Cannot send an empty message'")

      with subtest("the kept rollback opened the rollback breaker"):
          b = breaker()
          assert b["open"] is True and b["reason"] == "rolled back 222222222222", b
          machine.succeed("grep -qx 'nixhost_rollback_breaker_open 1' /var/lib/node-exporter/nixhost_breaker.prom")
          machine.succeed("grep -qx 'nixhost_rollback_breaker_blocked_total 0' /var/lib/node-exporter/nixhost_breaker.prom")
          assert "The rollback breaker is open" in machine.succeed("nixhost-breaker status")

      with subtest("while it's open, a failing deploy isn't rolled back: it stays, and the admins hear"):
          broken = machine.succeed(f"readlink -f {good}/specialisation/broken").strip()
          machine.succeed(f"{broken}/bin/switch-to-configuration test")
          deployed("done", "7777777777777777")
          machine.wait_until_succeeds("grep -q 'after deploying 777777777777; not rolling back: the rollback breaker has been open since' /var/lib/notify-sink.log", timeout=120)
          check_finished("exit-code")
          assert machine.succeed("readlink -f /run/current-system").strip() == broken
          [embed] = embeds("Health check failed: not rolling back")
          assert {"name": "Severity", "value": "critical", "inline": True} in embed["fields"], embed
          assert "(rolled back 222222222222). Reset it with `sudo nixhost-breaker reset`" in embed["description"], embed
          machine.succeed("grep -qx 'nixhost_rollback_breaker_blocked_total 1' /var/lib/node-exporter/nixhost_breaker.prom")
          machine.succeed("grep -qx 'nixhost_healthcheck_ok 0' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("grep -qx 'nixhost_healthcheck_rollbacks_total 1' /var/lib/node-exporter/nixhost_healthcheck.prom")
          assert json.loads(machine.succeed("cat /run/nixhost/checks/status.json"))["health"] == "failed"
          assert breaker()["open"] is True

      with subtest("nixhost-breaker reset closes it"):
          machine.succeed(f"{good}/bin/switch-to-configuration test")
          machine.wait_for_unit("sshd.service")
          machine.succeed("nixhost-breaker reset")
          b = breaker()
          assert b["open"] is False and b["reason"] == "reset by root", b
          machine.succeed("grep -qx 'nixhost_rollback_breaker_open 0' /var/lib/node-exporter/nixhost_breaker.prom")
          machine.wait_until_succeeds("grep -q 'root reset the rollback breaker' /var/lib/notify-sink.log")
          assert "The rollback breaker is closed" in machine.succeed("nixhost-breaker status")

      with subtest("a failing deploy across a rollback guard change isn't rolled back, and opens the breaker"):
          guarded = machine.succeed(f"readlink -f {good}/specialisation/guarded").strip()
          machine.succeed(f"{guarded}/bin/switch-to-configuration test", "touch /run/fail-health")
          assert json.loads(machine.succeed("cat /etc/nixhost/rollback-guard.json")) == {"k3s": "1.34"}
          deployed("done", "8888888888888888")
          machine.wait_until_succeeds("grep -q 'after deploying 888888888888; not rolling back, the deploy changed k3s, which an automatic rollback can.t cross. A person decides.' /var/lib/notify-sink.log", timeout=120)
          check_finished("exit-code")
          assert machine.succeed("readlink -f /run/current-system").strip() == guarded
          b = breaker()
          assert b["open"] is True and b["reason"] == "guard: k3s" and b["system"] == guarded, b
          machine.succeed("grep -qx 'nixhost_rollback_breaker_blocked_total 2' /var/lib/node-exporter/nixhost_breaker.prom")
          machine.succeed("grep -qx 'nixhost_healthcheck_rollbacks_total 1' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("rm /run/fail-health")

      with subtest("a deploy that passes its health checks closes the breaker"):
          machine.succeed(f"{good}/bin/switch-to-configuration test")
          machine.wait_for_unit("sshd.service")
          deployed("done", "9999999999999999")
          machine.wait_until_succeeds("grep -q 'The rollback breaker closed: 999999999999 passed its health checks' /var/lib/notify-sink.log", timeout=120)
          check_finished()
          b = breaker()
          assert b["open"] is False and b["reason"] == "999999999999 passed its health checks", b
          machine.succeed("grep -qx 'nixhost_rollback_breaker_open 0' /var/lib/node-exporter/nixhost_breaker.prom")
          assert machine.succeed("readlink /var/lib/nixhost-deploy/last-good").strip() == good

      with subtest("when the checks also fail on the older system, the deployed system stays"):
          other = machine.succeed(f"readlink -f {good}/specialisation/other").strip()
          machine.succeed(f"{other}/bin/switch-to-configuration test", "touch /run/fail-health")
          deployed("done", "3333333333333333")
          machine.wait_until_succeeds("grep -q 'so the deploy isn' /var/lib/notify-sink.log", timeout=180)
          check_finished("exit-code")
          assert machine.succeed("readlink -f /run/current-system").strip() == other
          machine.succeed("grep -qx 'nixhost_healthcheck_rollbacks_total 1' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("grep -qx 'nixhost_healthcheck_ok 0' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("rm /run/fail-health")

      with subtest("an outage outside the box that ends during the rollback doesn't undo the deploy"):
          # The git remote is gone while the deployed system is checked and back for the older one.
          machine.succeed("mv /var/lib/remote.git /var/lib/remote.git.away")
          deployed("done", "4444444444444444")
          machine.wait_until_succeeds("grep -q 'git-remote) after deploying 444444444444; rolling back' /var/lib/notify-sink.log", timeout=120)
          machine.succeed("mv /var/lib/remote.git.away /var/lib/remote.git")
          machine.wait_until_succeeds("grep -q 'passes on it again: something outside the box' /var/lib/notify-sink.log", timeout=180)
          check_finished()
          assert machine.succeed("readlink -f /run/current-system").strip() == other
          assert machine.succeed("readlink /var/lib/nixhost-deploy/last-good").strip() == other
          machine.succeed("grep -qx 'nixhost_healthcheck_rollbacks_total 1' /var/lib/node-exporter/nixhost_healthcheck.prom")

      with subtest("a deploy that breaks DNS is rolled back after a second try"):
          nodns = machine.succeed(f"readlink -f {good}/specialisation/nodns").strip()
          machine.succeed(f"{nodns}/bin/switch-to-configuration test")
          deployed("done", "5555555555555555")
          machine.wait_until_succeeds("grep -q 'dns) after deploying 555555555555; rolling back' /var/lib/notify-sink.log", timeout=120)
          machine.wait_until_succeeds("grep -qx 'nixhost_healthcheck_rollbacks_total 2' /var/lib/node-exporter/nixhost_healthcheck.prom", timeout=240)
          check_finished()
          assert machine.succeed("readlink -f /run/current-system").strip() == other
          machine.succeed(f"grep -q 'Rolled back to {other}; the checks pass again' /var/lib/notify-sink.log")

      with subtest("a firewall without its rules fails the check"):
          machine.succeed("iptables -w -D INPUT -j nixos-fw")
          deployed("done", "6666666666666666")
          machine.wait_until_succeeds("grep -q 'firewall) after deploying 666666666666' /var/lib/notify-sink.log", timeout=120)
          check_finished("exit-code")
          machine.succeed("systemctl reload firewall", "iptables -w -C INPUT -j nixos-fw")

      with subtest("boot mode only checks: it fails without rolling back, and passes"):
          current = machine.succeed("readlink -f /run/current-system").strip()
          notices = machine.succeed("wc -l < /var/lib/notify-sink.log").strip()
          machine.succeed("touch /run/fail-health")
          machine.fail("nixhost-health-check boot")
          assert machine.succeed("readlink -f /run/current-system").strip() == current
          assert machine.succeed("wc -l < /var/lib/notify-sink.log").strip() == notices
          machine.succeed("grep -qx 'nixhost_healthcheck_ok 0' /var/lib/node-exporter/nixhost_healthcheck.prom")
          machine.succeed("rm /run/fail-health", "nixhost-health-check boot")
          machine.succeed("grep -qx 'nixhost_healthcheck_ok 1' /var/lib/node-exporter/nixhost_healthcheck.prom")

      with subtest("the lag check sees the remote branch ahead of the deployed commit, and master ahead of deploy"):
          machine.succeed("systemctl start nixhost-deploy-lag.service")
          machine.succeed("grep -qx 'nixhost_deploy_upstream_check_ok 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_deploy_upstream_ahead 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_deploy_source_ahead 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -q '^nixhost_deploy_source_ahead_since_timestamp_seconds ' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("git -C /tmp/work push -q /var/lib/remote.git master:deploy", "systemctl start nixhost-deploy-lag.service")
          machine.succeed("grep -qx 'nixhost_deploy_source_ahead 0' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.fail("grep -q '^nixhost_deploy_source_ahead_since' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_nixpkgs_last_modified_timestamp_seconds 1893456000' /var/lib/node-exporter/nixhost_deploy.prom")
    '';
}
