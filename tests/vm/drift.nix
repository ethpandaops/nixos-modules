# Drift from the configuration: a clean box reports none; accounts, group
# members, /etc edits, stray key files and logins with keys the configuration
# doesn't pin are all reported; activation puts the box back.
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
  name = "drift";

  nodes.server = {
    imports = [
      self.nixosModules.base
      self.nixosModules.users
      self.nixosModules.monitoring
      self.nixosModules.deploy
    ];
    ethpandaops.monitoring.tailscale.enable = false;
    ethpandaops.monitoring.drift.listeners.ignoreProcesses = [ "ignored-listener" ];
    # The deploy module only for deployed.json's place and the branch name.
    ethpandaops.deploy = {
      repository = "/var/lib/remote.git";
      deployKeyFile = null;
      healthCheck.enable = false;
    };
    services.comin.enable = lib.mkForce false;
    # Configured, but not in the system's /etc (the test creates them).
    boot.initrd.network.ssh.hostKeys = [ "/etc/ssh/initrd_ssh_host_ed25519_key" ];
    # Activation is part of the test.
    system.switch.enable = true;
    ethpandaops.users = {
      alice = {
        uid = 1001;
        sudo = true;
        keys = [ keys.snakeOilPublicKey ];
      };
      bob = {
        uid = 1002;
        keys = [ keys.snakeOilPublicKey ];
      };
    };
  };

  nodes.client = { };

  testScript = ''
    import re

    files = {"nixhost-drift": "nixhost_drift", "nixhost-ssh-logins": "nixhost_ssh"}

    def metrics(name):
        server.succeed(f"systemctl start {name}.service")
        return server.succeed(f"cat /var/lib/node-exporter/{files[name]}.prom")

    def value(text, series):
        m = re.search("^" + re.escape(series) + r" (\S+)$", text, re.M)
        assert m, f"{series} missing from:\n{text}"
        return float(m.group(1))

    def wait_logins(series, expected):
        # The login reaches the journal just after ssh returns.
        def counted(_):
            return value(metrics("nixhost-ssh-logins"), series) == expected
        retry(counted, timeout_seconds=30)
        return metrics("nixhost-ssh-logins")

    checks = [
        "unexpected_users",
        "uid0_users",
        "unexpected_group_members",
        "etc_modified_files",
        "etc_unmanaged_files",
        "home_authorized_keys",
        "unexpected_listeners",
    ]

    start_all()
    server.wait_for_unit("sshd.service")
    server.wait_for_unit("multi-user.target")
    # Only the test runs the checks: `systemctl start` joins a timer's run
    # in progress, which may have read the files before the test changed them.
    server.succeed("systemctl stop nixhost-drift.timer nixhost-ssh-logins.timer")
    server.wait_until_succeeds(
        "! systemctl show -p ActiveState --value nixhost-drift.service nixhost-ssh-logins.service | grep -qx activating"
    )
    client.succeed("install -m 600 ${keys.snakeOilPrivateKey} /root/key")
    client.succeed('ssh-keygen -q -t ed25519 -N "" -f /root/other')
    other_pub = client.succeed("cat /root/other.pub").strip()
    ssh = "ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10"

    with subtest("a box as configured reports no drift"):
        server.succeed("touch /etc/ssh/initrd_ssh_host_ed25519_key /etc/ssh/initrd_ssh_host_ed25519_key.pub")
        out = metrics("nixhost-drift")
        for check in checks:
            assert value(out, f"nixhost_drift_{check}") == 0, out
        assert "nixhost_comin_config_stale" not in out, out

    with subtest("a login with a pinned key counts as known"):
        # Counts from an earlier run: a seed for a key file's metadata (as the
        # first version wrote) and logins by a user without a key file.
        server.succeed(
            "install -d -m 700 /var/lib/nixhost-drift",
            "printf '%s\\n' 'alice.mode known 0' 'alice.mode unknown 0' 'carol unknown 2' > /var/lib/nixhost-drift/ssh-logins",
        )
        client.succeed(f"{ssh} -i /root/key alice@server true")
        out = wait_logins('nixhost_ssh_logins_total{user="alice",key="known"}', 1)
        assert value(out, 'nixhost_ssh_logins_total{user="alice",key="unknown"}') == 0, out
        assert value(out, 'nixhost_ssh_logins_total{user="bob",key="unknown"}') == 0, out
        assert value(out, 'nixhost_ssh_logins_total{user="carol",key="unknown"}') == 2, out
        users = set(re.findall(r'^nixhost_ssh_logins_total\{user="([^"]*)"', out, re.M))
        assert users == {"alice", "bob", "carol"}, out
        # Each run counts only what is new.
        out = metrics("nixhost-ssh-logins")
        assert value(out, 'nixhost_ssh_logins_total{user="alice",key="known"}') == 1, out

    with subtest("changes made as root are reported"):
        server.succeed(
            "useradd -m mallory",
            "useradd -o -u 0 -M toor",
            "gpasswd -a bob wheel",
            "echo 'mallory ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers",
            "install -d /etc/sudoers.d && touch /etc/sudoers.d/mallory",
            "install -d -o mallory ~mallory/.ssh && touch ~mallory/.ssh/authorized_keys",
            # Swap alice's pinned key for another one.
            f"rm /etc/ssh/authorized_keys.d/alice && echo '{other_pub}' > /etc/ssh/authorized_keys.d/alice",
        )
        out = metrics("nixhost-drift")
        assert value(out, "nixhost_drift_unexpected_users") == 2, out
        assert 'nixhost_drift_unexpected_users_info{user="mallory"} 1' in out, out
        assert value(out, "nixhost_drift_uid0_users") == 1, out
        assert 'nixhost_drift_uid0_users_info{user="toor"} 1' in out, out
        assert 'nixhost_drift_unexpected_group_members_info{member="wheel:bob"} 1' in out, out
        assert 'nixhost_drift_etc_modified_files_info{path="sudoers"} 1' in out, out
        assert 'nixhost_drift_etc_modified_files_info{path="ssh/authorized_keys.d/alice"} 1' in out, out
        assert 'nixhost_drift_etc_unmanaged_files_info{path="sudoers.d/mallory"} 1' in out, out
        assert 'nixhost_drift_home_authorized_keys_info{file="mallory:/home/mallory/.ssh/authorized_keys"} 1' in out, out

    with subtest("a login with a key the configuration doesn't pin counts as unknown"):
        client.succeed(f"{ssh} -i /root/other alice@server true")
        fingerprint = client.succeed("ssh-keygen -l -f /root/other.pub").split()[1]
        out = wait_logins('nixhost_ssh_logins_total{user="alice",key="unknown"}', 1)
        assert value(out, 'nixhost_ssh_logins_total{user="alice",key="known"}') == 1, out
        assert f'method="publickey",fingerprint="{fingerprint}"' in out, out

    with subtest("a running or boot system other than the deployed one is reported"):
        current = server.succeed("readlink -f /run/current-system").strip()
        other = server.succeed("readlink -f /run/current-system/sw").strip()

        def deployed(system, ref="origin/deploy"):
            server.succeed(
                "install -d -m 700 /var/lib/nixhost-deploy",
                f"""echo '{{"sha": "abc", "ref": "{ref}", "status": "done", "system": "{system}"}}' > /var/lib/nixhost-deploy/deployed.json""",
            )
            return metrics("nixhost-drift")

        def boot(system):
            # GRUB's default entry first, as switch-to-configuration writes it.
            server.succeed(
                "mkdir -p /boot/grub",
                f"printf '%s\\n' 'menuentry \"NixOS\" {{' '  linux /kernels/bzImage init={system}/init loglevel=4' '}}'"
                + " 'menuentry \"older\" {' '  linux /kernels/bzImage init=/nix/store/older-system/init' '}' > /boot/grub/grub.cfg",
            )

        # No bootloader configuration to read: no boot check.
        server.succeed("rm -f /boot/grub/grub.cfg")
        out = deployed(current)
        assert value(out, "nixhost_deploy_running_matches_deployed") == 1, out
        assert "nixhost_deploy_boot_matches_deployed" not in out, out
        boot(current)
        # comin switches with its own profile and never moves the system
        # profile; the bootloader's default entry is what boots.
        server.succeed(f"mkdir -p /nix/var/nix/profiles && ln -sfn {other} /nix/var/nix/profiles/system")
        out = deployed(current)
        assert value(out, "nixhost_deploy_running_matches_deployed") == 1, out
        assert value(out, "nixhost_deploy_boot_matches_deployed") == 1, out
        # A rollback: the box runs and boots another system than deployed.json says.
        out = deployed(other)
        assert value(out, "nixhost_deploy_running_matches_deployed") == 0, out
        assert value(out, "nixhost_deploy_boot_matches_deployed") == 0, out
        # Mid-deployment: just activated, and deployed.json not yet rewritten.
        server.succeed(
            "touch -h /run/current-system",
            "touch -d @$(($(stat -c %Y /run/current-system) - 60)) /var/lib/nixhost-deploy/deployed.json",
        )
        out = metrics("nixhost-drift")
        assert "nixhost_deploy_running_matches_deployed" not in out, out
        assert "nixhost_deploy_boot_matches_deployed" not in out, out
        assert "nixhost_deploy_system_info{" in out, out
        # Still older once the activation is 5 minutes past: drift.
        server.succeed(
            "touch -h -d '-10 min' /run/current-system",
            "touch -d '-20 min' /var/lib/nixhost-deploy/deployed.json",
        )
        out = metrics("nixhost-drift")
        assert value(out, "nixhost_deploy_running_matches_deployed") == 0, out
        # A testing-branch deployment doesn't change the boot default.
        boot(other)
        out = deployed(current, ref="origin/testing-server")
        assert value(out, "nixhost_deploy_running_matches_deployed") == 1, out
        assert "nixhost_deploy_boot_matches_deployed" not in out, out
        boot(current)

    with subtest("listeners and firewall rules the configuration doesn't have are reported"):
        # The firewall check leaves a firewall or system set up in the last
        # 2 minutes alone.
        server.wait_until_succeeds("[ $(cut -d. -f1 /proc/uptime) -ge 130 ]", timeout=180)
        server.succeed("touch -h -d '-10 min' /run/current-system")
        out = metrics("nixhost-drift")
        assert value(out, "nixhost_drift_unexpected_listeners") == 0, out
        assert value(out, "nixhost_drift_firewall_rules") == 0, out
        python = "${pkgs.python3.interpreter}"
        # An ignored program, named the way NixOS wraps programs, so ss shows
        # a cut command name (.ignored-listen).
        server.succeed(
            "cp ${pkgs.socat}/bin/socat /var/lib/.ignored-listener-wrapped",
            "systemd-run --unit=ignored-listener /var/lib/.ignored-listener-wrapped TCP-LISTEN:8083,fork,reuseaddr EXEC:true",
        )
        server.succeed(
            f"systemd-run --unit=stray-listener {python} -m http.server 8081",
            f"systemd-run --unit=loopback-listener {python} -m http.server 8082 --bind 127.0.0.1",
            "iptables -I INPUT -p tcp --dport 8081 -j ACCEPT",
        )
        server.wait_until_succeeds("ss -H -ltn | grep -q ':8081 '")
        server.wait_until_succeeds("ss -H -ltn | grep -q ':8082 '")
        server.wait_until_succeeds("ss -H -ltn | grep -q ':8083 '")
        out = metrics("nixhost-drift")
        assert value(out, "nixhost_drift_unexpected_listeners") == 1, out
        assert re.search(r'^nixhost_drift_unexpected_listeners_info\{listener="tcp:8081 python3[^"]*"\} 1$', out, re.M), out
        assert value(out, "nixhost_drift_firewall_rules") == 1, out
        assert 'nixhost_drift_firewall_rules_info{rule="+ iptables filter: -A INPUT -p tcp -m tcp --dport 8081 -j ACCEPT"} 1' in out, out
        server.succeed(
            "systemctl stop stray-listener loopback-listener ignored-listener",
            "iptables -D INPUT -p tcp --dport 8081 -j ACCEPT",
        )
        out = metrics("nixhost-drift")
        assert value(out, "nixhost_drift_unexpected_listeners") == 0, out
        assert value(out, "nixhost_drift_firewall_rules") == 0, out

    with subtest("activation puts accounts, groups and /etc back, but not stray files"):
        server.succeed("/run/current-system/bin/switch-to-configuration test")
        out = metrics("nixhost-drift")
        for check in ["unexpected_users", "uid0_users", "unexpected_group_members", "etc_modified_files", "home_authorized_keys"]:
            assert value(out, f"nixhost_drift_{check}") == 0, out
        assert value(out, "nixhost_drift_etc_unmanaged_files") == 1, out
        server.succeed("rm -r /etc/sudoers.d")
        out = metrics("nixhost-drift")
        assert value(out, "nixhost_drift_etc_unmanaged_files") == 0, out
  '';
}
