# comin fetches the deploy branch over SSH with the deploy key, through its
# own git client (go-git), which picks the SSH user differently from OpenSSH.
# The repo here is no flake, so comin stops after the fetch.
{ self, pkgs, ... }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
{
  name = "comin-ssh";

  nodes = {
    gitserver = {
      users.users.git = {
        isNormalUser = true;
        shell = "${pkgs.git}/bin/git-shell";
        openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
      };
      services.openssh.enable = true;
      environment.systemPackages = [ pkgs.git ];
    };
    machine = {
      imports = [
        self.nixosModules.base
        self.nixosModules.deploy
      ];
      ethpandaops.deploy = {
        repository = "ssh://git@gitserver/srv/config.git";
        knownHostsFile = "/var/lib/test-known-hosts";
        pollInterval = 5;
        healthCheck.enable = false;
      };
    };
  };

  testScript = ''
    start_all()
    gitserver.wait_for_unit("sshd.service")
    gitserver.succeed(
        "git init -q -b deploy /tmp/work",
        "git -C /tmp/work -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m deployed",
        "git clone -q --bare /tmp/work /srv/config.git",
    )
    tip = gitserver.succeed("git -C /srv/config.git rev-parse deploy").strip()
    gitserver.succeed("chown -R git /srv/config.git")

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "install -D -m 400 ${keys.snakeOilPrivateKey} /var/lib/comin/deploy_key",
        "ssh-keyscan -t ed25519 gitserver > /var/lib/test-known-hosts",
    )

    with subtest("comin fetches the deploy branch over SSH"):
        machine.wait_until_succeeds(f"test \"$(git -C /var/lib/comin/repository rev-parse refs/remotes/origin/deploy)\" = {tip}", timeout=120)
        machine.fail("journalctl -u comin | grep -q 'unable to authenticate'")

    with subtest("the lag check reads the same remote with OpenSSH"):
        machine.succeed("systemctl start nixhost-deploy-lag.service")
        machine.succeed("grep -qx 'nixhost_deploy_upstream_check_ok 1' /var/lib/node-exporter/nixhost_deploy.prom")
  '';
}
