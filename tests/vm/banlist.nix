# The fleet ban list end to end: a dual-stack host fetches a signed list
# over IPv4 and IPv6 in turn and loads it, in shadow counts and drops
# nothing, enforcing drops new connections from the list's sources except
# allowed ones, refuses a list that's too wide, badly signed, stale,
# replayed, a flood, or whose generation is huge or far ahead, and keeps the
# last good one; a list signed by the standby key isn't held back by the
# active key's replay floor; it follows the list's own shadow and empty
# modes, and comes out with break-glass or mode off; the rules never change
# while lists load. A box whose module lock came on before the ban list's
# kernel modules loaded keeps its firewall and drops nothing. And sshd's
# "Invalid user" line ends with the real source, so a scorer reads the
# address from the end, not after the first " from ".
{
  self,
  pkgs,
  lib,
  ...
}:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  # The list's server: /srv, behind basic auth test:secret.
  listServer = pkgs.writeText "list-server.py" ''
    import base64, functools, http.server, socket

    AUTH = "Basic " + base64.b64encode(b"test:secret").decode()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get("Authorization") != AUTH:
                self.send_error(401)
                return
            super().do_GET()

    class Server(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6  # and IPv4, as ::ffff:a.b.c.d

    Server(("::", 8080), functools.partial(Handler, directory="/srv")).serve_forever()
  '';

  banlist = mode: {
    imports = [
      self.nixosModules.base
      self.nixosModules.banlist
    ];
    ethpandaops.banlist = {
      inherit mode;
      url = "http://client:8080/banlist/v1";
      user = "test";
      passwordFile = "${pkgs.writeText "banlist-password" "secret"}";
      # Active and standby.
      publicKeys = [
        keys.snakeOilEd25519PublicKey
        keys.snakeOilPublicKey
      ];
      # The default allows private ranges, the test network's among them.
      allow = [ "127.0.0.0/8" ];
      interval = 2;
    };
    system.switch.enable = true;
  };
in
{
  name = "banlist";

  nodes.server =
    { nodes, lib, ... }:
    {
      imports = [ (banlist "shadow") ];
      # The list's server: allowed here, whatever the list says.
      ethpandaops.banlist.allowFile = pkgs.writeText "banlist-allow" ''
        # the client
        ${nodes.client.networking.primaryIPAddress}
        ${nodes.client.networking.primaryIPv6Address}/128
      '';
      specialisation.enforce.configuration.ethpandaops.banlist.mode = lib.mkForce "enforce";
      specialisation.off.configuration.ethpandaops.banlist.mode = lib.mkForce "off";
      # What the scanner tries to reach.
      systemd.services.probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3.interpreter} -m http.server 8000 --bind :: --directory ${pkgs.writeTextDir "index.html" "ok"}";
      };
      networking.firewall.allowedTCPPorts = [ 8000 ];
    };

  # Under the module lock, as a box is when a deploy turns the list on:
  # ip_set and xt_set were loaded at boot (for something else), not
  # ip_set_hash_net.
  nodes.locked =
    { nodes, lib, ... }:
    {
      imports = [ (banlist "off") ];
      ethpandaops.kernelModules = {
        lock = true;
        allowlist = [
          "ip_set"
          "xt_set"
        ];
      };
      specialisation.on.configuration.ethpandaops.banlist.mode = lib.mkForce "enforce";
    };

  nodes.client = {
    systemd.services.list-server = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${listServer}";
    };
    systemd.tmpfiles.rules = [ "d /srv/banlist 0755 root root -" ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];
  };

  nodes.scanner = {
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript =
    { nodes, ... }:
    ''
      import base64, ipaddress, json, re

      scanner4 = "${nodes.scanner.networking.primaryIPAddress}"
      scanner6 = "${nodes.scanner.networking.primaryIPv6Address}"
      client4 = "${nodes.client.networking.primaryIPAddress}"
      # Single IPv6 sources are /64s; the client shares the scanner's.
      net6 = str(ipaddress.ip_network(scanner6 + "/64", strict=False))

      def publish(cidrs, generation, previous=0, mode="enforce", age=0, key="/root/key"):
          now = int(client.succeed("date +%s"))
          payload = {
              "version": 1,
              "generation": generation,
              "previous_generation": previous,
              "generated_at": now - age,
              "mode": mode,
              "entries": [{"cidr": c, "expires": now + 3600, "reason": "test", "points": 1} for c in cidrs],
              "unknown": "ignored",
          }
          data = base64.b64encode(json.dumps(payload).encode()).decode()
          client.succeed(f"echo {data} | base64 -d > /srv/payload")
          client.succeed(f"rm -f /srv/payload.sig && ssh-keygen -q -Y sign -f {key} -n nixhost-banlist /srv/payload")
          client.succeed(
              "jq -n --arg p \"$(base64 -w0 /srv/payload)\" --rawfile s /srv/payload.sig"
              " '{payload: $p, signature: $s}' > /srv/banlist/v1.new && mv /srv/banlist/v1.new /srv/banlist/v1"
          )

      def metrics(machine=server):
          return machine.succeed("cat /var/lib/node-exporter/nixhost_banlist.prom")

      def value(series, machine=server):
          m = re.search("^" + re.escape(series) + r" (\S+)$", metrics(machine), re.M)
          assert m, f"{series} missing from:\n{metrics(machine)}"
          return float(m.group(1))

      def wait_value(series, want, machine=server):
          retry(lambda _: value(series, machine) == want, timeout_seconds=60)

      def rejected(reason):
          return value(f'nixhost_banlist_rejected_total{{reason="{reason}"}}')

      def refused(reason, *args, **kwargs):
          before = rejected(reason)
          publish(*args, **kwargs)
          retry(lambda _: rejected(reason) > before, timeout_seconds=60)
          assert value("nixhost_banlist_generation") == loaded, metrics()

      def reaches(node, family):
          return node.execute(f"curl -{family} -sf --max-time 3 http://server:8000/")[0] == 0

      def mangle():
          return server.succeed("iptables-save -t mangle | grep -- '^-A'; ip6tables-save -t mangle | grep -- '^-A'")

      def switch(name):
          server.succeed(f"{base}/specialisation/{name}/bin/switch-to-configuration test")

      start_all()
      client.wait_for_unit("list-server.service")
      client.succeed("install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/key")
      client.succeed("install -m 600 ${keys.snakeOilPrivateKey} /root/standby")
      client.succeed("echo '${keys.snakeOilEd25519PublicKey}' > /root/key.pub; echo '${keys.snakeOilPublicKey}' > /root/standby.pub")
      active, standby = (client.succeed(f"ssh-keygen -lf {k}.pub | cut -d' ' -f2").strip() for k in ["/root/key", "/root/standby"])
      client.succeed('ssh-keygen -q -t ed25519 -N "" -f /root/other')
      server.wait_for_unit("probe.service")
      server.wait_for_unit("nixhost-banlist-pull.service")
      scanner.wait_for_unit("multi-user.target")
      base = server.succeed("readlink -f /run/current-system").strip()
      server.wait_for_file("/var/lib/node-exporter/nixhost_banlist.prom")

      with subtest("the chain is in place before there's a list, and nothing is dropped"):
          wait_value("nixhost_banlist_ready", 1)
          retry(lambda _: rejected("fetch") > 0, timeout_seconds=60)
          assert reaches(scanner, 4) and reaches(scanner, 6)
          rules = mangle()
          assert "-A PREROUTING -j nixos-ban" in rules, rules

      with subtest("a dual-stack host fetches over IPv4 and IPv6 in turn"):
          client.wait_until_succeeds("journalctl -u list-server.service | grep -qF '::ffff:${nodes.server.networking.primaryIPAddress} - '")
          client.wait_until_succeeds("journalctl -u list-server.service | grep -qF ' ${nodes.server.networking.primaryIPv6Address} - '")

      with subtest("in shadow, the list's sources are counted, not dropped"):
          publish([scanner4 + "/32", client4 + "/32", net6], 1001)
          wait_value("nixhost_banlist_generation", 1001)
          loaded = 1001
          assert reaches(scanner, 4) and reaches(scanner, 6)
          wait_value('nixhost_banlist_entries{family="ipv4",set="shadow"}', 2)
          wait_value('nixhost_banlist_entries{family="ipv6",set="shadow"}', 1)
          wait_value('nixhost_banlist_entries{family="ipv4",set="ban"}', 0)
          retry(lambda _: value('nixhost_banlist_matched_packets_total{family="ipv4",set="shadow"}') > 0, timeout_seconds=60)
          assert f'nixhost_banlist_info{{mode="shadow",list_mode="enforce",effective="shadow",key="{active}"}} 1' in metrics()

      with subtest("enforcing drops new connections from the list's sources, never from allowed ones"):
          publish([scanner4 + "/32", client4 + "/32", net6], 1001)
          switch("enforce")
          wait_value('nixhost_banlist_entries{family="ipv4",set="ban"}', 2)
          wait_value('nixhost_banlist_entries{family="ipv6",set="ban"}', 1)
          assert not reaches(scanner, 4) and not reaches(scanner, 6)
          # On the list (its /32, and the /64 it shares), but in allowFile.
          assert reaches(client, 4) and reaches(client, 6)
          retry(lambda _: value('nixhost_banlist_matched_packets_total{family="ipv4",set="ban"}') > 0, timeout_seconds=60)
          assert mangle() == rules, (rules, mangle())

      with subtest("a list that's wrong is refused, and the last good one stays"):
          refused("too_wide", [scanner4 + "/32", "198.51.0.0/16"], 1002, 1001)
          refused("signature", [], 1003, 1001, key="/root/other")
          refused("stale", [], 1004, 1001, age=3600)
          flood = [f"198.18.{i // 250}.{i % 250 + 1}/32" for i in range(501)]
          refused("too_many_added", [scanner4 + "/32"] + flood, 1005, 1001)
          refused("invalid", [scanner4], 1006, 1001)
          publish([scanner4 + "/32", net6], 1010, 1001)
          wait_value("nixhost_banlist_generation", 1010)
          loaded = 1010
          refused("replay", [], 1007, 1001)
          assert not reaches(scanner, 4) and not reaches(scanner, 6)

      with subtest("the list's own shadow and empty modes, and lifting a ban, apply within seconds"):
          publish([scanner4 + "/32"], 1020, 1010, mode="shadow")
          wait_value("nixhost_banlist_generation", 1020)
          assert reaches(scanner, 4)
          publish([], 1021, 1020, mode="empty")
          wait_value("nixhost_banlist_generation", 1021)
          wait_value('nixhost_banlist_entries{family="ipv4",set="shadow"}', 0)
          publish([scanner4 + "/32"], 1022, 1021)
          wait_value("nixhost_banlist_generation", 1022)
          assert not reaches(scanner, 4)
          publish([], 1023, 1022)
          wait_value("nixhost_banlist_generation", 1023)
          assert reaches(scanner, 4)
          loaded = 1023

      with subtest("break-glass: stopping the sets unit takes the chain out at once"):
          publish([scanner4 + "/32"], 1030, 1023)
          wait_value("nixhost_banlist_generation", 1030)
          assert not reaches(scanner, 4)
          server.succeed("systemctl stop nixhost-banlist-sets.service")
          server.fail("systemctl is-active nixhost-banlist-pull.service")
          server.fail("iptables -w -t mangle -S nixos-ban")
          assert reaches(scanner, 4)
          server.succeed("systemctl start nixhost-banlist-sets.service nixhost-banlist-pull.service")
          wait_value('nixhost_banlist_entries{family="ipv4",set="ban"}', 1)
          assert not reaches(scanner, 4)
          assert mangle() == rules, (rules, mangle())

      with subtest("a generation above 2^53 or over a day ahead is refused; the standby key has its own replay floor"):
          loaded = 1030
          now = int(client.succeed("date +%s"))
          # 2^64 - 1 is past bash's integers, which once let it through.
          refused("invalid", [], 2**64 - 1, 1030)
          refused("invalid", [], 2**53 + 1, 1030)
          refused("invalid", [], now + 2 * 86400, 1030)
          # Up to a day ahead loads, and holds the active key's lists back.
          ahead = now + 3600
          publish([scanner4 + "/32"], ahead, 1030)
          wait_value("nixhost_banlist_generation", ahead)
          loaded = ahead
          refused("replay", [], now, ahead)
          # The same older generation written as a float is still a replay,
          # not a comparison bash gives up on.
          refused("replay", [], float(now), ahead)
          # The standby key isn't held back: rotating to it recovers.
          publish([], now, ahead, key="/root/standby")
          wait_value("nixhost_banlist_generation", now)
          loaded = now
          assert reaches(scanner, 4)
          assert f'key="{standby}"' in metrics(), metrics()
          refused("replay", [scanner4 + "/32"], now - 1, now, key="/root/standby")
          # Each floor is kept on disk, for the next boot.
          floors = server.succeed("grep -r . /var/lib/nixhost-banlist | sort")
          assert f"generation-{active.replace('/', '_')}:{ahead}" in floors, floors
          assert f"generation-{standby.replace('/', '_')}:{now}" in floors, floors

      with subtest("mode off takes the chain and the metrics out"):
          switch("off")
          server.fail("test -e /var/lib/node-exporter/nixhost_banlist.prom")
          server.fail("iptables -w -t mangle -S nixos-ban")
          server.fail("ip6tables -w -t mangle -S nixos-ban")
          assert reaches(scanner, 4) and reaches(scanner, 6)
          server.succeed("iptables -w -C INPUT -j nixos-fw")

      with subtest("sshd's Invalid user line ends with the real source, whatever the user name says"):
          scanner.fail("ssh -4 -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -l 'x from 192.0.2.7 port 1' server true")
          server.wait_until_succeeds("journalctl -u sshd.service -o cat | grep -q '^Invalid user x from 192.0.2.7 port 1 from '")
          line = server.succeed("journalctl -u sshd.service -o cat | grep '^Invalid user x from 192.0.2.7 port 1 from ' | tail -n 1").strip()
          m = re.search(r" from (\S+) port \d+$", line)
          assert m and m.group(1) == scanner4, line

      with subtest("under the module lock, turning the list on keeps the firewall and drops nothing"):
          publish([scanner4 + "/32"], 1040, 1030)
          locked.wait_until_succeeds("[ $(cat /proc/sys/kernel/modules_disabled) = 1 ]")
          locked_base = locked.succeed("readlink -f /run/current-system").strip()
          locked.succeed(f"{locked_base}/specialisation/on/bin/switch-to-configuration test")
          locked.succeed("systemctl is-active nixhost-banlist-sets.service")
          locked.succeed("journalctl -u nixhost-banlist-sets.service | grep -q 'IPv4: no ban list'")
          locked.fail("iptables -w -t mangle -S nixos-ban")
          locked.succeed("iptables -w -C INPUT -j nixos-fw")
          locked.succeed("ip6tables -w -C INPUT -j nixos-fw")
          locked.wait_for_file("/var/lib/node-exporter/nixhost_banlist.prom")
          wait_value("nixhost_banlist_ready", 0, locked)
          retry(lambda _: value('nixhost_banlist_rejected_total{reason="load"}', locked) > 0, timeout_seconds=60)
          locked.fail("systemctl is-failed nixhost-banlist-sets.service nixhost-banlist-pull.service")
    '';
}
