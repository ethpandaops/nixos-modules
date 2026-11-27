# A droplet booted from the image the digitalocean module builds, with GRUB
# from its own disk, next to a stand-in for DigitalOcean: DHCP and the
# metadata service on the public network (eth1), the VPC gateway and a
# peered network on the VPC (eth2). The image grows its root filesystem;
# the public NIC takes DHCP, the VPC NIC the metadata's address and routes;
# node-exporter answers on the VPC only; the droplet's SSH keys log in only
# to metadataKeysUser; NICs that don't match the metadata's MACs fail
# digitalocean-network; and a deployed system boots once as a trial and is
# confirmed, with no hardware watchdog.
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
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = public.gateway;
            prefixLength = 24;
          }
          {
            address = "169.254.169.254";
            prefixLength = 32;
          }
        ];
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
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

        services.dnsmasq = {
          enable = true;
          settings = {
            interface = "eth1";
            bind-interfaces = true;
            dhcp-range = "${public.address},static,255.255.255.0";
            dhcp-host = "${mac 1},${public.address}";
            dhcp-option = [
              "option:router,${public.gateway}"
              "option:dns-server,${public.gateway}"
            ];
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

    droplet =
      { config, ... }:
      {
        imports = [
          self.nixosModules.default
          self.nixosModules.digitalocean
          self.nixosModules.reboot-interactive
        ];
        virtualisation = {
          vlans = [
            1
            2
          ];
          memorySize = 2048;
          diskSize = 4096;
          directBoot.enable = false;
          mountHostNixStore = false;
          useDefaultFilesystems = false;
          fileSystems = lib.mkForce { };
          bootLoaderDevice = "/dev/vda";
        };
        boot.loader.grub.devices = lib.mkForce [ "/dev/vda" ];
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
          reboot.trial.enable = true;
        };
        services.comin.enable = lib.mkForce false;
        # srvos's closure diff can't read the image builder's Nix output.
        srvos.update-diff.enable = false;

        specialisation.good.configuration.boot.kernelParams = [ "nixhost.test=good" ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import glob
      import gzip
      import json
      import os
      import shlex
      import shutil
      import subprocess
      import tempfile

      cloud.start()
      cloud.wait_for_unit("metadata.service")
      cloud.wait_for_open_port(80, "169.254.169.254")

      image = tempfile.NamedTemporaryFile(suffix=".qcow2")
      with gzip.open(glob.glob("${nodes.droplet.system.build.digitalOceanImage}/*.qcow2.gz")[0]) as src:
          shutil.copyfileobj(src, image)
      image.flush()
      disk = tempfile.NamedTemporaryFile(suffix=".qcow2")
      subprocess.run(["${nodes.droplet.virtualisation.qemu.package}/bin/qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", image.name, disk.name, "8G"], check=True)
      os.environ["NIX_DISK_IMAGE"] = disk.name

      def sh(machine, command):
          return machine.succeed(command).strip()

      def settle():
          droplet.wait_for_unit("multi-user.target")
          droplet.wait_until_succeeds("[ $(systemctl show -p ExecMainExitTimestampMonotonic --value nixhost-boot-confirm) != 0 ]", timeout=300)
          return sh(droplet, "readlink -f /run/booted-system")

      def ssh(key, user, host="${public.address}"):
          return f"ssh -n -i /etc/test-keys/{key} -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 {user}@{host} true"

      def metric(series):
          return sh(droplet, f"awk -v s={shlex.quote(series + ' ')} 'index($0, s) == 1 {{ print $NF; exit }}' /var/lib/node-exporter/*.prom")

      droplet.start()
      base = settle()

      with subtest("the image boots with GRUB from its own disk and grows its root filesystem to the disk"):
          droplet.succeed("dd if=/dev/vda bs=512 count=1 2>/dev/null | grep -q GRUB")
          assert sh(droplet, "findmnt -no SOURCE /") == "/dev/vda1"
          size = int(sh(droplet, "df -B1 --output=size / | tail -n1"))
          assert size > 7 * 1024**3, size

      with subtest("the public NIC takes its address, default route and DNS from DHCP"):
          droplet.succeed("ip -4 -o addr show dev eth1 | grep -q ' ${public.address}/24 '")
          assert sh(droplet, "ip -4 route show default").startswith("default via ${public.gateway} dev eth1"), sh(droplet, "ip -4 route show default")
          droplet.succeed("resolvectl dns eth1 | grep -q ${public.gateway}")
          droplet.succeed("getent hosts metadata.test")

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

      with subtest("node-exporter answers on the VPC NIC only"):
          cloud.wait_until_succeeds("curl -sf --max-time 5 -o /dev/null http://${private.address}:9100/metrics")
          cloud.fail("curl -sf --max-time 5 http://${public.address}:9100/metrics")

      with subtest("the droplet's SSH keys log in only to metadataKeysUser, and nothing else of the metadata is used"):
          cloud.wait_until_succeeds(ssh("configured", "example"))
          cloud.succeed(ssh("metadata", "example"))
          cloud.fail(ssh("metadata", "root"))
          droplet.fail("test -e /root/.ssh/authorized_keys")
          for unit in ["digitalocean-init", "digitalocean-entropy-seed", "digitalocean-set-root-password", "do-agent"]:
              droplet.fail(f"systemctl cat {unit}.service")

      with subtest("NICs that aren't the metadata's fail digitalocean-network, naming the option"):
          cloud.succeed("jq '.interfaces.public[0].mac as $p | .interfaces.public[0].mac = .interfaces.private[0].mac | .interfaces.private[0].mac = $p' /var/lib/metadata/metadata/v1.json > /tmp/v1.json && cp /var/lib/metadata/metadata/v1.json /tmp/good.json && cp /tmp/v1.json /var/lib/metadata/metadata/v1.json")
          droplet.execute("rm /run/do-metadata/v1.json && systemctl restart digitalocean-metadata.service")
          droplet.fail("systemctl restart digitalocean-network.service")
          droplet.succeed("journalctl -b -o cat -u digitalocean-network | grep -q \"the droplet's public NIC is .*, but eth1 is .*: set ethpandaops.digitalocean.interfaces.public\"")
          cloud.succeed("cp /tmp/good.json /var/lib/metadata/metadata/v1.json")
          droplet.succeed("rm /run/do-metadata/v1.json", "systemctl restart digitalocean-metadata.service", "systemctl restart digitalocean-network.service")

      with subtest("a deployed system boots once as a trial on the droplet's disk and is confirmed, with no hardware watchdog"):
          assert metric("nixhost_boot_trial_supported") == "1"
          assert metric("nixhost_boot_watchdog_present") == "0"
          droplet.wait_until_succeeds("journalctl -t nixhost-notify -o cat | grep -q 'No hardware watchdog: '")
          good = sh(droplet, f"readlink -f {base}/specialisation/good")
          droplet.succeed(f"{good}/bin/switch-to-configuration boot", "sync")
          droplet.execute("systemctl --no-block reboot", check_output=False)
          droplet.wait_for_shutdown()
          droplet.start()
          assert settle() == good
          droplet.succeed(f"grep -q 'nixhost.trial={good.split('/')[-1]}' /proc/cmdline")
          trial = json.loads(sh(droplet, "cat /var/lib/nixhost-boot/trial.json"))
          assert trial["system"] == good and trial["confirmed"] == base and trial["outcome"] == "confirmed", trial
          droplet.succeed("ip -4 -o addr show dev eth2 | grep -q ' ${private.address}/20 '")
    '';
}
