# The vulnix scan's report becomes nixhost_vulnix_* metrics, and a failed scan
# keeps the last report and says so. vulnix itself is a stub here: the VM has
# no NVD to download and no derivers for --closure to follow.
{
  self,
  pkgs,
  ...
}:
let
  report = pkgs.writeText "vulnix-report.json" (
    builtins.toJSON [
      {
        name = "openssl-3.0.1";
        affected_by = [
          "CVE-2026-0001"
          "CVE-2026-0002"
        ];
        cvssv3_basescore = {
          "CVE-2026-0001" = 9.8;
          "CVE-2026-0002" = 7.5;
        };
      }
      # The same package from a second derivation.
      {
        name = "openssl-3.0.1";
        affected_by = [ "CVE-2026-0001" ];
        cvssv3_basescore = {
          "CVE-2026-0001" = 9.8;
        };
      }
      {
        name = "bash-5.2";
        affected_by = [ "CVE-2026-0003" ];
        cvssv3_basescore = {
          "CVE-2026-0003" = 5.3;
        };
      }
      {
        name = "coreutils-9.5";
        affected_by = [ "CVE-2026-0004" ];
        cvssv3_basescore = { };
      }
    ]
  );
  # Records its arguments; prints the report, or fails without one when the
  # test asks it to.
  stub = pkgs.writeShellScriptBin "vulnix" ''
    echo "$@" > "$CACHE_DIRECTORY/args"
    if [ -e "$CACHE_DIRECTORY/fail" ]; then
      echo "requests.exceptions.ConnectionError: nvd.nist.gov" >&2
      exit 2
    fi
    cat ${report}
    exit 2
  '';
in
{
  name = "vulnix";

  nodes.server = {
    imports = [
      self.nixosModules.base
      self.nixosModules.monitoring
    ];
    ethpandaops.monitoring.tailscale.enable = false;
    ethpandaops.host.environment = "test";
    ethpandaops.monitoring.vulnix = {
      enable = true;
      package = stub;
      whitelist = ''
        ["zlib-1.3"]
        cve = ["CVE-2026-0005"]
      '';
    };
  };

  testScript = ''
    import re

    def value(text, series):
        m = re.search("^" + re.escape(series) + r" (\S+)$", text, re.M)
        assert m, f"{series} missing from:\n{text}"
        return float(m.group(1))

    def scan():
        server.succeed("systemctl start nixhost-vulnix.service")
        return server.succeed("cat /var/lib/node-exporter/nixhost_vulnix.prom /var/lib/node-exporter/nixhost_vulnix_run.prom")

    start_all()
    server.wait_for_unit("multi-user.target")
    server.succeed("systemctl is-active nixhost-vulnix.timer")

    with subtest("a report becomes metrics"):
        out = scan()
        assert value(out, "nixhost_vulnix_vulnerable_packages") == 3, out
        for severity, count in [("critical", 1), ("high", 1), ("medium", 1), ("low", 0), ("unknown", 1)]:
            assert value(out, f'nixhost_vulnix_cves{{severity="{severity}"}}') == count, (severity, out)
        assert value(out, 'nixhost_vulnix_package_cves{package="openssl-3.0.1",max_cvss="9.8"}') == 2, out
        assert 'nixhost_vulnix_cve_info{package="openssl-3.0.1",cve="CVE-2026-0001",cvss="9.8",severity="critical"} 1' in out, out
        assert 'nixhost_vulnix_cve_info{package="openssl-3.0.1",cve="CVE-2026-0002",cvss="7.5",severity="high"} 1' in out, out
        assert "CVE-2026-0003" not in out, "only critical and high CVEs are named"
        assert value(out, "nixhost_vulnix_last_run_ok") == 1, out

    with subtest("vulnix scans the running system's closure with the configured whitelist"):
        args = server.succeed("cat /var/cache/nixhost-vulnix/args").split()
        current = server.succeed("readlink -f /run/current-system").strip()
        assert args[-1] == current, args
        assert "--closure" in args and "--json" in args, args
        assert args[args.index("--cache-dir") + 1] == "/var/cache/nixhost-vulnix", args
        whitelist = args[args.index("--whitelist") + 1]
        server.succeed(f"grep -q CVE-2026-0005 {whitelist}")

    with subtest("a failed scan keeps the last report and says so"):
        success = value(scan(), "nixhost_vulnix_last_success_timestamp_seconds")
        server.succeed("touch /var/cache/nixhost-vulnix/fail")
        out = scan()
        assert value(out, "nixhost_vulnix_last_run_ok") == 0, out
        assert value(out, "nixhost_vulnix_last_success_timestamp_seconds") == success, out
        assert value(out, "nixhost_vulnix_vulnerable_packages") == 3, out
        server.fail("systemctl is-failed --quiet nixhost-vulnix.service")
  '';
}
