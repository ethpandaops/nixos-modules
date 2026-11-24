# node-exporter answers only on the tailnet interface. eth2 stands in for
# tailscale0 here; SSH stays reachable on the public side.
{ self, ... }:
{
  name = "monitoring";

  nodes = {
    server = {
      imports = [
        self.nixosModules.base
        self.nixosModules.monitoring
      ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.hostName = "monbox";
      ethpandaops.monitoring = {
        interface = "eth2";
        tailscale.enable = false;
      };
      ethpandaops.host.environment = "staging";
    };
    public.virtualisation.vlans = [ 1 ];
    tailnet.virtualisation.vlans = [ 2 ];
  };

  testScript =
    { nodes, ... }:
    let
      ip =
        vlan:
        (builtins.head nodes.server.networking.interfaces."eth${toString vlan}".ipv4.addresses).address;
    in
    ''
      start_all()
      server.wait_for_open_port(9100)
      server.wait_for_unit("nixhost-info.service")
      server.wait_for_unit("sshd.service")
      server.succeed("mkdir -p /var/lib/node-exporter && echo 'nixhost_test 1' > /var/lib/node-exporter/test.prom")

      tailnet.wait_until_succeeds("curl -sf --max-time 5 -o /tmp/metrics http://${ip 2}:9100/metrics")
      tailnet.succeed("grep -qx 'nixhost_test 1' /tmp/metrics")
      # The fleet defaults to the host name.
      tailnet.succeed("grep -qxF 'nixhost_info{configured_environment=\"staging\",configured_fleet=\"monbox\",configured_nixhost=\"monbox\"} 1' /tmp/metrics")
      public.fail("curl -sf --max-time 5 http://${ip 1}:9100/metrics")
      public.wait_for_open_port(22, "${ip 1}")
    '';
}
