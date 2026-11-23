# The post-deploy health check, with its real sshd, route, DNS and git
# checks: a healthy deployment becomes the last good system; a deployment
# that breaks SSH is rolled back to it; when the checks fail on both, the
# deployed system stays. The admins hear about each through Discord-style
# webhooks.
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
      specialisation.broken.configuration.services.openssh.enable = lib.mkForce false;
      specialisation.other.configuration.environment.etc."health-check-test".text = "other";
      # Flake-built systems carry the nixpkgs commit date in their version
      # (the test framework forces "test", so override at a higher priority).
      system.nixos.versionSuffix = lib.mkOverride 10 ".20300101.0000000";
    };

  testScript =
    { nodes, ... }:
    ''
      post_deploy = "${nodes.machine.services.comin.postDeploymentCommand}"

      def deployed(status, sha):
          # What comin runs after each deployment; it starts the check without waiting.
          machine.succeed(f"COMIN_STATUS={status} COMIN_GIT_SHA={sha} COMIN_GIT_REF=origin/deploy {post_deploy}")

      def check_finished(result="success"):
          # Polled rather than `systemctl start`, whose bus connection drops
          # when a rollback re-executes systemd.
          machine.wait_until_succeeds("systemctl show -p ActiveState --value nixhost-health-check | grep -qxE 'inactive|failed'", timeout=120)
          assert machine.succeed("systemctl show -p Result --value nixhost-health-check").strip() == result

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("notify-sink.service")
      machine.succeed(
          "git init -q -b deploy /tmp/work",
          "git -C /tmp/work -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init",
          "git clone -q --bare /tmp/work /var/lib/remote.git",
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
          machine.succeed("grep -q 'sshd-not-listening-on-22) after deploying 222222222222; rolling back' /var/lib/notify-sink.log")
          machine.succeed("grep -q 'checks pass again' /var/lib/notify-sink.log")

      with subtest("Discord gets the body each endpoint wants, and a rejection is logged with its reason"):
          machine.succeed("grep -q '^/api/webhooks/1/native {\"content\":\"\\[machine\\] health check failed' /var/lib/notify-sink.log")
          machine.succeed("grep -q '^/api/webhooks/2/compat/slack {\"text\":\"\\[machine\\] health check failed' /var/lib/notify-sink.log")
          machine.fail("journalctl -t nixhost-notify | grep -q 'delivery to a discord target failed'")
          machine.succeed("journalctl -t nixhost-notify | grep -q 'delivery to a webhook target failed: .*Cannot send an empty message'")

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

      with subtest("the lag check sees the remote branch ahead of the deployed commit"):
          machine.succeed("systemctl start nixhost-deploy-lag.service")
          machine.succeed("grep -qx 'nixhost_deploy_upstream_check_ok 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_deploy_upstream_ahead 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_nixpkgs_last_modified_timestamp_seconds 1893456000' /var/lib/node-exporter/nixhost_deploy.prom")
    '';
}
