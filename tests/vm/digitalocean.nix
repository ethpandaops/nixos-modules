# A droplet's network from its metadata, next to a stand-in for
# DigitalOcean: the metadata service on the public network's link-local
# range, a DNS server and the public gateway (eth1), and the VPC gateway and
# a peered network (eth2). There's no DHCP server. The public NIC gets its
# IPv4 and IPv6 addresses, anchor IP, default routes and DNS servers from
# the metadata, and the VPC NIC its address and routes, before
# network-online.target; node-exporter answers on the VPC only; the
# droplet's SSH keys log in only to metadataKeysUser; NICs that don't match
# the metadata's MACs fail digitalocean-network and its health check; and a
# boot while the metadata service is down uses the saved metadata.
{
  self,
  lib,
  pkgs,
  ...
}:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  public = {
    address = "192.0.2.10";
    gateway = "192.0.2.1";
    anchor = "10.18.0.5";
    ipv6 = "2001:db8::10";
    ipv6Gateway = "2001:db8::1";
  };
  private = {
    address = "10.110.16.5";
    gateway = "10.110.16.1";
    peered = "10.200.0.1";
  };
in
{
  name = "digitalocean";

  nodes = {
    cloud =
      { nodes, ... }:
      let
        mac =
          vlan: "52:54:00:12:0${toString vlan}:0${toString nodes.droplet.virtualisation.test.nodeNumber}";
        metadata = pkgs.writeText "v1.json" (
          builtins.toJSON {
            droplet_id = 1;
            hostname = "droplet";
            public_keys = [ keys.snakeOilEd25519PublicKey ];
            dns.nameservers = [ public.gateway ];
            interfaces = {
              public = [
                {
                  mac = mac 1;
                  type = "public";
                  ipv4 = {
                    ip_address = public.address;
                    netmask = "255.255.255.0";
                    inherit (public) gateway;
                  };
                  anchor_ipv4 = {
                    ip_address = public.anchor;
                    netmask = "255.255.0.0";
                    gateway = "10.18.0.1";
                  };
                  ipv6 = {
                    ip_address = public.ipv6;
                    cidr = 64;
                    gateway = public.ipv6Gateway;
                  };
                }
              ];
              private = [
                {
                  mac = mac 2;
                  type = "private";
                  ipv4 = {
                    ip_address = private.address;
                    netmask = "255.255.240.0";
                    inherit (private) gateway;
                  };
                }
              ];
            };
          }
        );
      in
      {
        virtualisation.vlans = [
          1
          2
        ];
        networking.firewall.enable = false;
        networking.interfaces.eth1 = {
          ipv4.addresses = lib.mkForce [
            {
              address = public.gateway;
              prefixLength = 24;
            }
            {
              address = "169.254.169.254";
              prefixLength = 16;
            }
          ];
          ipv6.addresses = [
            {
              address = public.ipv6Gateway;
              prefixLength = 64;
            }
          ];
        };
        networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
          {
            address = private.gateway;
            prefixLength = 20;
          }
          {
            address = private.peered;
            prefixLength = 24;
          }
        ];

        services.dnsmasq = {
          enable = true;
          settings = {
            interface = "eth1";
            bind-interfaces = true;
            address = "/metadata.test/${public.gateway}";
          };
        };

        systemd.services.metadata = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            StateDirectory = "metadata";
            ExecStartPre = "${pkgs.coreutils}/bin/install -D -m 0644 ${metadata} /var/lib/metadata/metadata/v1.json";
            ExecStart = "${lib.getExe pkgs.python3} -m http.server --bind 169.254.169.254 --directory /var/lib/metadata 80";
          };
        };

        environment.systemPackages = [ pkgs.jq ];
        environment.etc = {
          "test-keys/metadata" = {
            source = keys.snakeOilEd25519PrivateKey;
            mode = "0400";
          };
          "test-keys/configured" = {
            source = keys.snakeOilPrivateKey;
            mode = "0400";
          };
        };
      };

    droplet = {
      imports = [
        self.nixosModules.default
        self.nixosModules.digitalocean
      ];
      virtualisation = {
        vlans = [
          1
          2
        ];
        memorySize = 1536;
      };
      networking.interfaces = lib.mkForce { };
      networking.hostName = "droplet";

      ethpandaops = {
        digitalocean = {
          interfaces = {
            public = "eth1";
            private = "eth2";
          };
          metadataKeysUser = "example";
        };
        users.example = {
          uid = 1001;
          keys = [ keys.snakeOilPublicKey ];
        };
        host.environment = "staging";
        monitoring = {
          interface = "eth2";
          tailscale.enable = false;
        };
        deploy = {
          repository = "/var/lib/remote.git";
          deployKeyFile = null;
          healthCheck = {
            dnsName = null;
            checkRemote = false;
          };
        };
      };
      services.comin.enable = lib.mkForce false;
      systemd.services.needs-network = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
    };
  };

  testScript = ''
    import json

    def sh(machine, command):
        return machine.succeed(command).strip()

    def ssh(key, user, host="${public.address}"):
        return f"ssh -n -i /etc/test-keys/{key} -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 {user}@{host} true"

    cloud.start()
    cloud.wait_for_unit("metadata.service")
    cloud.wait_for_open_port(80, "169.254.169.254")
    droplet.start()
    droplet.wait_for_unit("digitalocean-network.service")

    with subtest("the public NIC takes its addresses, default routes and DNS servers from the metadata, without DHCP"):
        addresses = sh(droplet, "ip -o addr show dev eth1")
        for address in ["${public.address}/24", "${public.anchor}/16", "${public.ipv6}/64"]:
            assert f" {address} " in addresses, addresses
        assert sh(droplet, "ip -4 route show default").startswith("default via ${public.gateway} dev eth1")
        assert sh(droplet, "ip -6 route show default").startswith("default via ${public.ipv6Gateway} dev eth1")
        droplet.succeed("ping -c1 -W5 ${public.ipv6Gateway}")
        droplet.succeed("resolvectl dns eth1 | grep -q ${public.gateway}")
        droplet.succeed("getent hosts metadata.test")
        droplet.fail("journalctl -b -o cat -u systemd-networkd | grep -qi dhcp4")

    with subtest("the VPC NIC takes the metadata's address, and routes to other private networks through the VPC gateway, before network-online.target"):
        droplet.succeed("ip -4 -o addr show dev eth2 | grep -q ' ${private.address}/20 '")
        assert "via ${private.gateway} dev eth2" in sh(droplet, "ip -4 route get ${private.peered}")
        droplet.succeed("ping -c1 -W5 ${private.peered}")
        finished = int(sh(droplet, "systemctl show -p ExecMainExitTimestampMonotonic --value digitalocean-network"))
        online = int(sh(droplet, "systemctl show -p ActiveEnterTimestampMonotonic --value network-online.target"))
        assert 0 < finished <= online, (finished, online)
        assert "multi-user.target" in sh(droplet, "systemctl show -p WantedBy --value digitalocean-network")
        droplet.succeed("systemctl start nixhost-checks.service")
        check = json.loads(sh(droplet, "cat /run/nixhost/checks/status.json"))["checks"]["digitalocean-network"]
        assert check["ok"] and check["kind"] == "health" and check["outside"], check
        assert sh(droplet, "stat -c %a /run/digitalocean/metadata.json") == "600"

    with subtest("node-exporter answers on the VPC NIC only"):
        cloud.wait_until_succeeds("curl -sf --max-time 5 -o /dev/null http://${private.address}:9100/metrics")
        cloud.fail("curl -sf --max-time 5 http://${public.address}:9100/metrics")

    with subtest("the droplet's SSH keys log in only to metadataKeysUser, and nothing else of the metadata is used"):
        cloud.wait_until_succeeds(ssh("configured", "example"))
        cloud.succeed(ssh("metadata", "example"))
        cloud.fail(ssh("metadata", "root"))
        droplet.fail("test -e /root/.ssh/authorized_keys")

    with subtest("NICs that aren't the metadata's fail digitalocean-network and its check, naming the option"):
        cloud.succeed("cp /var/lib/metadata/metadata/v1.json /tmp/good.json")
        cloud.succeed("jq '.interfaces.public[0].mac as $p | .interfaces.public[0].mac = .interfaces.private[0].mac | .interfaces.private[0].mac = $p' /tmp/good.json > /var/lib/metadata/metadata/v1.json")
        droplet.fail("systemctl restart digitalocean-network.service")
        droplet.succeed("journalctl -b -o cat -u digitalocean-network | grep -q \"the droplet's public NIC is .*, but eth1 is .*: set ethpandaops.digitalocean.interfaces.public\"")
        droplet.succeed("systemctl start nixhost-checks.service")
        assert not json.loads(sh(droplet, "cat /run/nixhost/checks/status.json"))["checks"]["digitalocean-network"]["ok"]
        cloud.succeed("cp /tmp/good.json /var/lib/metadata/metadata/v1.json")
        droplet.wait_until_succeeds("systemctl is-active digitalocean-network.service", timeout=60)

    with subtest("a boot while the metadata service is down gets its network from the saved metadata, and retries until the service answers"):
        cloud.succeed("systemctl stop metadata.service")
        droplet.shutdown()
        droplet.start()
        droplet.wait_until_succeeds("ip -4 -o addr show dev eth2 | grep -q ' ${private.address}/20 '", timeout=180)
        droplet.succeed("ip -4 -o addr show dev eth1 | grep -q ' ${public.address}/24 '")
        droplet.succeed("journalctl -b -o cat -u digitalocean-network | grep -q 'using the copy saved'")
        droplet.fail("systemctl is-active digitalocean-network.service")
        cloud.wait_until_succeeds(ssh("metadata", "example"))
        cloud.succeed("systemctl start metadata.service")
        droplet.wait_until_succeeds("systemctl is-active digitalocean-network.service", timeout=120)
  '';
}
