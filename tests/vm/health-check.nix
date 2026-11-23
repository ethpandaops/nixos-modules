# The post-deploy health check: a healthy deployment becomes the last good
# system; a deployment that breaks SSH is rolled back to it, and the admins
# are told.
{ self, lib, ... }:
{
  name = "health-check";

  nodes.machine = {
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
        dnsName = null;
        checkDefaultRoute = false;
      };
    };
    services.comin.enable = lib.mkForce false;
    ethpandaops.notify.admins = [
      {
        type = "webhook";
        url = "http://127.0.0.1:8000/";
      }
    ];
    specialisation.broken.configuration.services.openssh.enable = lib.mkForce false;
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

      def check_finished():
          # Polled rather than `systemctl start`, whose bus connection drops
          # when a rollback re-executes systemd.
          machine.wait_until_succeeds("systemctl show -p ActiveState --value nixhost-health-check | grep -qxE 'inactive|failed'", timeout=120)
          assert machine.succeed("systemctl show -p Result --value nixhost-health-check").strip() == "success"

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("notify-sink.service")
      machine.succeed(
          "git init -q -b deploy /tmp/work",
          "git -C /tmp/work -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init",
          "git clone -q --bare /tmp/work /var/lib/remote.git",
      )
      good = machine.succeed("readlink -f /run/current-system").strip()

      with subtest("a healthy deployment is recorded as the last good system"):
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

      with subtest("the lag check sees the remote branch ahead of the deployed commit"):
          machine.succeed("systemctl start nixhost-deploy-lag.service")
          machine.succeed("grep -qx 'nixhost_deploy_upstream_check_ok 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_deploy_upstream_ahead 1' /var/lib/node-exporter/nixhost_deploy.prom")
          machine.succeed("grep -qx 'nixhost_nixpkgs_last_modified_timestamp_seconds 1893456000' /var/lib/node-exporter/nixhost_deploy.prom")
    '';
}
