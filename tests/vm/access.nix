# Who can log in: ethpandaops.users accounts with keys, sudo only for sudo
# users, nobody after their expiry date, and never root or accounts outside
# ethpandaops.users. A source that names a user who can't log in is refused
# for a while, unless it's on the exempt list.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
{
  name = "access";

  nodes.server =
    { nodes, ... }:
    {
      imports = [
        self.nixosModules.base
        self.nixosModules.users
      ];
      ethpandaops.users = {
        alice = {
          uid = 1001;
          sudo = true;
          keys = [ keys.snakeOilPublicKey ];
          comment = "sudo user";
        };
        bob = {
          uid = 1002;
          keys = [ keys.snakeOilPublicKey ];
        };
        carol = {
          uid = 1003;
          keys = [ keys.snakeOilPublicKey ];
          expires = "2000-01-01";
        };
      };
      users.users.dave = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
      };
      users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
      # The client tries users who can't log in, then must still get in.
      services.openssh.settings.PerSourcePenaltyExemptList = lib.concatStringsSep "," [
        "100.64.0.0/10"
        "fd7a:115c:a1e0::/48"
        nodes.client.networking.primaryIPAddress
        nodes.client.networking.primaryIPv6Address
      ];
    };

  nodes.client = { };
  nodes.scanner = { };

  testScript =
    { nodes, ... }:
    ''
      start_all()
      server.wait_for_unit("sshd.service")
      # The client's network too: an early ssh finds it unreachable.
      client.wait_for_unit("multi-user.target")
      client.succeed("install -m 600 ${keys.snakeOilPrivateKey} /root/key")
      # -n: never read the test driver's console as stdin.
      ssh = "ssh -n -i /root/key -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"

      with subtest("a user with a key logs in; sudo works only for sudo users"):
          client.succeed(f"{ssh} alice@server true")
          client.succeed(f"{ssh} alice@server sudo -n true")
          client.succeed(f"{ssh} bob@server true")
          client.fail(f"{ssh} bob@server sudo -n true")

      with subtest("an expired account can't log in"):
          server.succeed("getent shadow carol | cut -d: -f8 | grep -qx 10957")
          client.fail(f"{ssh} carol@server true")

      with subtest("accounts outside ethpandaops.users and root can't log in"):
          client.fail(f"{ssh} dave@server true")
          client.fail(f"{ssh} root@server true")

      with subtest("only public keys are offered, and keys in home directories are ignored"):
          out = client.fail(f"{ssh} -o PubkeyAuthentication=no alice@server true 2>&1")
          assert "Permission denied (publickey)" in out, out
          client.succeed('ssh-keygen -q -t ed25519 -N "" -f /root/other')
          server.succeed("install -d -o bob ~bob/.ssh")
          pub = client.succeed("cat /root/other.pub").strip()
          server.succeed(f"echo '{pub}' > ~bob/.ssh/authorized_keys && chown bob ~bob/.ssh/authorized_keys")
          client.fail("ssh -n -i /root/other -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 bob@server true")

      with subtest("a source that names a user who can't log in is refused for 5 minutes; an exempt one isn't"):
          # Over IPv6, so sshd penalises the scanner's whole /64, which the
          # client shares.
          scanner_ip = "${nodes.scanner.networking.primaryIPv6Address}"
          # As the scanners do: user root, and no key the server would check.
          scan = "ssh -6 -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -o PubkeyAuthentication=no root@server true 2>&1"
          scanner.wait_for_unit("multi-user.target")
          out = scanner.fail(scan)
          assert "Permission denied" in out, out
          # sshd penalises the source once the refused connection's process has exited.
          server.wait_until_succeeds(f"journalctl -u sshd.service | grep -qF 'new {scanner_ip}/64 active penalty of 300.000 seconds'")
          out = scanner.fail(scan)
          assert "Permission denied" not in out, out
          server.wait_until_succeeds(f"journalctl -u sshd.service | grep -q 'drop connection #[0-9]* from \\[{scanner_ip}\\]:[0-9]* on .* penalty: attempted authentication by invalid user'")
          # The client named carol, dave and root above and is in the scanner's
          # /64, but it's on the exempt list.
          client.succeed(f"{ssh} alice@server true")
    '';
}
