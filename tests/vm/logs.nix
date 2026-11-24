# The journal reaches the OTLP endpoint with the configured basic auth: an
# ordinary entry, an audit record for a sudoers change, a command a
# logged-in user runs as root and a BPF program load; container output
# doesn't. fluent-bit's counters reach node-exporter's textfile directory.
{
  self,
  pkgs,
  ...
}:
let
  # Appends each request's Authorization header and its (gunzipped) protobuf
  # body to /var/lib/otlp-sink.log. The strings the test looks for appear
  # verbatim in the protobuf.
  sink = pkgs.writeText "otlp-sink.py" ''
    import gzip, http.server

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            with open("/var/lib/otlp-sink.log", "ab") as log:
                log.write(f"{self.path} {self.headers.get('Authorization')}\n".encode() + body + b"\n")
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

    http.server.HTTPServer(("127.0.0.1", 4318), Handler).serve_forever()
  '';

  # Loads a two-instruction socket filter (r0 = 0; exit) with
  # bpf(BPF_PROG_LOAD), under a command name the test looks for.
  bpfLoad = pkgs.writeText "bpf-load.py" ''
    import ctypes, struct

    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl(15, b"bpf-marker", 0, 0, 0)  # PR_SET_NAME
    insns = ctypes.create_string_buffer(struct.pack("<BBhiBBhi", 0xB7, 0, 0, 0, 0x95, 0, 0, 0))
    license = ctypes.create_string_buffer(b"GPL")
    # union bpf_attr: prog_type (socket filter), insn_cnt, insns, license.
    attr = ctypes.create_string_buffer(
        struct.pack("<IIQQ", 1, 2, ctypes.addressof(insns), ctypes.addressof(license)), 128
    )
    if libc.syscall(321, 5, attr, 128) < 0:  # bpf(BPF_PROG_LOAD) on x86_64
        raise OSError(ctypes.get_errno(), "bpf")
  '';
in
{
  name = "logs";

  nodes.server = {
    imports = [
      self.nixosModules.base
      self.nixosModules.monitoring
    ];
    networking.hostName = "logbox";
    ethpandaops.monitoring.tailscale.enable = false;
    ethpandaops.host = {
      fleet = "logfleet";
      environment = "staging";
    };
    ethpandaops.monitoring.logs = {
      enable = true;
      endpoint = "http://127.0.0.1:4318";
      user = "nixhost-test";
      passwordFile = "${pkgs.writeText "otlp-password" "s3cret"}";
    };
    systemd.services.otlp-sink = {
      wantedBy = [ "multi-user.target" ];
      before = [ "fluent-bit.service" ];
      serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${sink}";
    };
  };

  testScript = ''
    import base64
    import re

    auth = "Basic " + base64.b64encode(b"nixhost-test:s3cret").decode()

    def shipped(text):
        status, _ = server.execute(f"grep -q -a -F -- '{text}' /var/lib/otlp-sink.log")
        return status == 0

    def wait_shipped(text):
        retry(lambda _: shipped(text), timeout_seconds=60)

    start_all()
    server.wait_for_unit("fluent-bit.service")
    server.wait_for_unit("auditd.service")
    server.wait_for_unit("audit-rules-nixos.service")

    with subtest("journal entries reach the endpoint with basic auth"):
        server.succeed("logger -t logtest -p user.err marker-ordinary-entry")
        wait_shipped("marker-ordinary-entry")
        assert shipped(f"/v1/logs {auth}"), "no request with the configured basic auth"
        for text in ["host.name", "logbox", "ethpandaops.fleet", "logfleet", "deployment.environment", "staging", "syslog.identifier", "logtest", "ERROR"]:
            assert shipped(text), text

    with subtest("a sudoers change is shipped as an audit record"):
        server.succeed("echo '# audit test' >> /etc/sudoers")
        wait_shipped('key="sudoers"')
        assert shipped("audit.type"), "no audit attributes"

    with subtest("a command a logged-in user runs as root is shipped"):
        # As after an SSH login (pam_loginuid) and sudo: login uid 1001, euid 0.
        server.succeed("sh -c 'echo 1001 > /proc/self/loginuid && exec /run/current-system/sw/bin/true marker-root-exec'")
        wait_shipped('key="root-exec"')
        assert shipped("marker-root-exec"), "the command's arguments are missing"
        # The audit.key attribute is the bare key, not the kernel's quoted
        # field: OTLP's KeyValue{"audit.key", AnyValue{string_value}}.
        sink = base64.b64decode(server.succeed("base64 -w0 /var/lib/otlp-sink.log"))
        assert re.search(rb"audit\.key\x12.\x0a.root-exec", sink, re.S), "audit.key isn't the bare key"
        # Services have no login uid, so their commands aren't recorded.
        server.succeed("systemd-run --wait --description=service-exec-test /run/current-system/sw/bin/true marker-service-exec")
        server.succeed("logger -t logtest marker-after-service")
        wait_shipped("marker-after-service")
        assert not shipped("marker-service-exec"), "a service's command was recorded"

    with subtest("a BPF program load is shipped with the process and login uid"):
        server.succeed("sh -c 'echo 1001 > /proc/self/loginuid && exec ${pkgs.python3.interpreter} ${bpfLoad}'")
        wait_shipped('comm="bpf-marker"')
        sink = base64.b64decode(server.succeed("base64 -w0 /var/lib/otlp-sink.log"))
        assert re.search(
            rb'syscall=321 [^\n]*auid=1001 [^\n]*comm="bpf-marker"[^\n]*key="bpf"', sink
        ), "no bpf record with the loader's login uid"

    with subtest("a module loaded after boot counts as one the module lock would refuse"):
        server.wait_for_unit("nixhost-module-lock-point.service")
        # An audit record with unprintable bytes, which journalctl writes as an
        # array, before the load doesn't stop the count at that entry.
        server.succeed("sh -c 'printf \"bad\\001name\" > /proc/self/comm && echo >> /etc/sudoers'")
        server.wait_until_succeeds("journalctl _TRANSPORT=audit -o json | jq -e -s 'any(.[]; ._COMM | type == \"array\")'", timeout=30)
        server.succeed("modprobe dummy")
        def late(_):
            server.succeed("systemctl start nixhost-kernel.service")
            return 'nixhost_kernel_module_late_loads_total{module="dummy"} 1' in server.succeed("cat /var/lib/node-exporter/nixhost_kernel.prom")
        retry(late, timeout_seconds=60)
        out = server.succeed("cat /var/lib/node-exporter/nixhost_kernel.prom")
        # Modules loaded at boot aren't late, nor are the drivers udev was
        # still loading when multi-user.target was reached.
        assert re.search(r"^nixhost_kernel_module_late_modules 1$", out, re.M), out

    with subtest("container output stays on the box"):
        server.succeed(
            "printf 'MESSAGE=marker-docker-output\\nCONTAINER_ID=abc\\n' | logger --journald",
            "logger -t logtest marker-after-docker",
        )
        wait_shipped("marker-after-docker")
        server.succeed("journalctl -o cat MESSAGE=marker-docker-output | grep -q marker-docker-output")
        assert not shipped("marker-docker-output"), "container output was shipped"

    with subtest("fluent-bit's counters reach node-exporter"):
        server.succeed("systemctl start nixhost-logs-metrics.service")
        out = server.succeed("cat /var/lib/node-exporter/nixhost_logs.prom")
        assert "nixhost_logs_up 1" in out, out
        assert 'fluentbit_output_proc_records_total{name="opentelemetry.0"}' in out, out
        server.systemctl("stop fluent-bit.service")
        server.succeed("systemctl start nixhost-logs-metrics.service")
        out = server.succeed("cat /var/lib/node-exporter/nixhost_logs.prom")
        assert "nixhost_logs_up 0" in out, out
  '';
}
