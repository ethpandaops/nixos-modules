# Known vulnerabilities in the running system, as nixhost_vulnix_* textfile
# metrics: vulnix matches the runtime closure of /run/current-system against
# NVD's CVE feeds, less what the configuration whitelists.
#
# vulnix refreshes from NVD's small "modified" feed when its cache is under a
# week old and otherwise downloads and parses the last six yearly feeds
# (about 200 MB compressed, several GB of memory). A daily scan keeps the
# cache warm, so only the first one pays that.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.monitoring.vulnix;

  scan = pkgs.writeShellApplication {
    name = "nixhost-vulnix";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      WHITELIST=${
        lib.optionalString (cfg.whitelist != "") (pkgs.writeText "vulnix-whitelist.toml" cfg.whitelist)
      }
      MAX_SERIES=20
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./vulnix.sh}
    '';
  };
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.monitoring.vulnix = {
    enable = lib.mkEnableOption "a daily vulnix scan of the running system";
    package = lib.mkPackageOption pkgs "vulnix" { };
    whitelist = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        ["openssl-3.0.15"]
        cve = ["CVE-2024-0001"]
        comment = "not reachable here: we don't use the affected API"
      '';
      description = "vulnix whitelist (TOML, see vulnix-whitelist(5)): triaged CVEs not to report. Pin versions and list CVEs, so a new version or CVE is reported again.";
    };
    calendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "When to scan (systemd OnCalendar).";
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "Memory limit for the scan. The first one parses NVD's yearly feeds and needs several GB.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixhost-vulnix = {
      description = "Scan the running system for known vulnerabilities (vulnix)";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      environment = {
        LANG = "C.UTF-8";
        # Through the daemon: the store database is read-only here, and so
        # is /root, so nix keeps its cache with vulnix's.
        NIX_REMOTE = "daemon";
        XDG_CACHE_HOME = "/var/cache/nixhost-vulnix";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe scan;
        CacheDirectory = "nixhost-vulnix";
        TimeoutStartSec = "2h";
        MemoryMax = cfg.memoryMax;
        Nice = 19;
        IOSchedulingClass = "idle";
        ProtectSystem = "strict";
        ReadWritePaths = [ config.ethpandaops.metrics.textfileDir ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
    systemd.timers.nixhost-vulnix = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.calendar;
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
