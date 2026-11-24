# Kernel tampering metrics on a booted, hardened server with audit=1: every
# protection the configuration turns on reads as in force; a command-line
# protection the running kernel lacks is tampering, or pending when the
# booted system never had it; deleting an audit rule or turning auditing off
# is reported; systemd's BPF loads are known and another program's aren't.
{ self, pkgs, ... }:
let
  # bpf(BPF_PROG_LOAD) of a two-instruction socket filter, as in the logs test.
  bpfLoad = pkgs.writeText "bpf-load.py" ''
    import ctypes, struct

    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl(15, b"bpf-marker", 0, 0, 0)  # PR_SET_NAME
    insns = ctypes.create_string_buffer(struct.pack("<BBhiBBhi", 0xB7, 0, 0, 0, 0x95, 0, 0, 0))
    license = ctypes.create_string_buffer(b"GPL")
    attr = ctypes.create_string_buffer(
        struct.pack("<IIQQ", 1, 2, ctypes.addressof(insns), ctypes.addressof(license)), 128
    )
    if libc.syscall(321, 5, attr, 128) < 0:  # bpf(BPF_PROG_LOAD) on x86_64
        raise OSError(ctypes.get_errno(), "bpf")
  '';
in
{
  name = "kernel";

  nodes.server = {
    imports = [
      self.nixosModules.base
      self.nixosModules.monitoring
    ];
    ethpandaops.monitoring.tailscale.enable = false;
    ethpandaops.host.environment = "test";
    # Log shipping brings auditd and the bpf audit rule; nothing listens on
    # the endpoint, which doesn't matter here.
    ethpandaops.monitoring.logs = {
      enable = true;
      endpoint = "http://127.0.0.1:4318";
      user = "test";
      passwordFile = "${pkgs.writeText "otlp-password" "test"}";
    };
    security.lockKernelModules = true;
  };

  testScript = ''
    import re

    def metrics():
        server.succeed("systemctl start nixhost-kernel.service")
        return server.succeed("cat /var/lib/node-exporter/nixhost_kernel.prom")

    def value(text, series):
        m = re.search("^" + re.escape(series) + r" (\S+)$", text, re.M)
        assert m, f"{series} missing from:\n{text}"
        return float(m.group(1))

    protections = ["modules_disabled", "kexec_load_disabled", "cmdline:nohibernate", "cmdline:audit=1", "audit_enabled"]

    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("audit-rules-nixos.service")
    server.wait_until_succeeds("[ $(cat /proc/sys/kernel/modules_disabled) = 1 ]")
    server.succeed("systemctl stop nixhost-kernel.timer")

    with subtest("every protection the configuration turns on is in force"):
        out = metrics()
        for check in protections:
            assert value(out, f'nixhost_kernel_protection{{check="{check}"}}') == 1, (check, out)
        assert "nixhost_kernel_protection_pending{" not in out, out

    with subtest("a command-line protection the kernel lacks is tampering, or pending if the booted system never had it"):
        server.succeed(
            "sed 's/ audit=1 / /; s/^audit=1 //' /proc/cmdline > /run/fake-cmdline",
            "mount --bind /run/fake-cmdline /proc/cmdline",
        )
        out = metrics()
        assert value(out, 'nixhost_kernel_protection{check="cmdline:audit=1"}') == 0, out
        assert 'nixhost_kernel_protection_pending{check="cmdline:audit=1"}' not in out, out
        # A booted system without audit=1: the protection waits for a reboot.
        booted = server.succeed("readlink -f /run/booted-system").strip()
        server.succeed(
            "mkdir /run/fake-booted",
            f"for f in {booted}/*; do ln -s $f /run/fake-booted/; done",
            f"rm /run/fake-booted/kernel-params && sed 's/audit=1//' {booted}/kernel-params > /run/fake-booted/kernel-params",
            "ln -sfn /run/fake-booted /run/booted-system",
        )
        out = metrics()
        assert value(out, 'nixhost_kernel_protection_pending{check="cmdline:audit=1"}') == 1, out
        server.succeed("umount /proc/cmdline", f"ln -sfn {booted} /run/booted-system")
        out = metrics()
        assert value(out, 'nixhost_kernel_protection{check="cmdline:audit=1"}') == 1, out

    with subtest("systemd's BPF loads are known, another program's aren't"):
        # A unit with an IP filter makes systemd (PID 1) load BPF programs.
        server.succeed("systemd-run --wait -p IPAddressDeny=any true")
        server.succeed("${pkgs.python3.interpreter} ${bpfLoad}")
        def counted(_):
            out = metrics()
            return 'loader="python3.13",known="false"' in out and value(out, 'nixhost_bpf_loads_total{loader="systemd",known="true"}') > 0
        retry(counted, timeout_seconds=30)
        out = metrics()
        assert value(out, 'nixhost_bpf_loads_total{loader="python3.13",known="false"}') == 1, out
        assert re.search(r'^nixhost_bpf_last_unknown_load_timestamp_seconds\{exe="/nix/store/[^"]*/python3.13",comm="bpf-marker",auid="unset"\} \d+$', out, re.M), out
        # Each run counts only what is new.
        assert value(metrics(), 'nixhost_bpf_loads_total{loader="python3.13",known="false"}') == 1

    with subtest("deleting an audit rule or turning auditing off is reported"):
        # The rule check leaves the 2 minutes after a load or activation alone.
        server.wait_until_succeeds("[ $(cut -d. -f1 /proc/uptime) -ge 130 ]", timeout=180)
        server.succeed("touch -h -d '-10 min' /run/current-system")
        out = metrics()
        assert value(out, "nixhost_audit_rules_changed") == 0, out
        assert value(out, "nixhost_audit_rules") > 5, out
        server.succeed("auditctl -d always,exit -F arch=b64 -S bpf -F a0=5 -k bpf")
        out = metrics()
        assert value(out, "nixhost_audit_rules_changed") == 1, out
        assert re.search(r'^nixhost_audit_rules_changed_info\{rule="- -a always,exit -F arch=b64 -S bpf [^"]*key=bpf"\} 1$', out, re.M), out
        server.succeed("auditctl -e 0")
        out = metrics()
        assert value(out, 'nixhost_kernel_protection{check="audit_enabled"}') == 0, out
        # Reloading the rules puts both back.
        server.succeed("systemctl restart audit-rules-nixos.service")
        out = metrics()
        assert value(out, 'nixhost_kernel_protection{check="audit_enabled"}') == 1, out
  '';
}
