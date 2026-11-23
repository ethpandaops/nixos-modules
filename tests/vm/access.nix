# Who can log in: ethpandaops.users accounts with keys, sudo only for sudo
# users, nobody after their expiry date, and never root or accounts outside
# ethpandaops.users.
{ self, pkgs, ... }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
{
  name = "access";

  nodes.server = {
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
  };

  nodes.client = { };

  testScript = ''
    start_all()
    server.wait_for_unit("sshd.service")
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
  '';
}
