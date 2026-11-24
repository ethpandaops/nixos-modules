# What base's hardening promises on a booted server: no interface accepts or
# sends ICMP redirects, including those that existed before sysctl ran; an
# ordinary user can't have the kernel load an unused protocol or tty line
# discipline; people's accounts can use the Nix daemon and service accounts
# can't.
{ self, pkgs, ... }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  # Each of these would make the kernel load a module for the caller: an
  # SCTP socket (sctp, by its alias) and the N_HDLC line discipline on a pty
  # (n_hdlc). Being refused is the point, so only report.
  probe = pkgs.writeText "autoload-probe.py" ''
    import fcntl, os, socket, struct

    try:
        socket.socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_SCTP)
        print("sctp socket opened")
    except OSError as e:
        print(f"sctp socket refused: {e}")

    _, terminal = os.openpty()
    try:
        fcntl.ioctl(terminal, 0x5423, struct.pack("i", 13))  # TIOCSETD, N_HDLC
        print("n_hdlc set")
    except OSError as e:
        print(f"n_hdlc refused: {e}")
  '';
in
{
  name = "hardening";

  nodes.server = {
    imports = [
      self.nixosModules.base
      self.nixosModules.users
    ];
    ethpandaops.users.bob = {
      uid = 1002;
      keys = [ keys.snakeOilPublicKey ];
    };
  };

  testScript = ''
    server.wait_for_unit("multi-user.target")

    with subtest("no interface accepts or sends ICMP redirects"):
        out = server.succeed(
            "grep . /proc/sys/net/ipv4/conf/*/accept_redirects"
            " /proc/sys/net/ipv6/conf/*/accept_redirects"
            " /proc/sys/net/ipv4/conf/*/send_redirects"
        )
        # Real interfaces, not only all and default; lo exists before
        # systemd-sysctl runs, as an uplink can.
        assert "/lo/" in out and "/eth1/" in out, out
        wrong = [line for line in out.splitlines() if not line.endswith(":0")]
        assert not wrong, wrong

    with subtest("an ordinary user can't have the kernel load an unused protocol or line discipline"):
        print(server.succeed("su - bob -c '${pkgs.python3.interpreter} ${probe}'"))
        loaded = server.succeed("cut -d' ' -f1 /proc/modules").split()
        for module in ["sctp", "n_hdlc"]:
            assert module not in loaded, f"{module} was loaded"

    with subtest("people's accounts can use the Nix daemon; service accounts can't"):
        server.succeed("su - bob -c 'nix-store --query --references /run/current-system'")
        server.fail(
            "systemd-run --wait --pipe -p DynamicUser=yes"
            " /run/current-system/sw/bin/nix-store --query --references /run/current-system"
        )
        server.succeed("journalctl -u nix-daemon.service | grep -q 'is not allowed to connect to the Nix daemon'")
  '';
}
