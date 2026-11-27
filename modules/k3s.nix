# k3s from nixpkgs (services.k3s, one k3s.service for either role) on a
# node the other modules deploy, check and reboot:
#
# - A server without serverAddr starts embedded etcd (--cluster-init). If
#   its data dir has no etcd member, it refuses to start rather than create
#   a new, empty cluster (a new CA and token nothing else trusts), unless a
#   person creates bootstrapFile on purpose; that file is removed once the
#   new cluster is up. A restore (`k3s server --cluster-reset`) runs by hand
#   and needs no bootstrap file. A server with serverAddr joins an existing
#   etcd cluster.
# - With etcdSnapshots, servers snapshot etcd on a schedule to S3-compatible
#   storage. The endpoint and keys are sops secrets (etcd-s3-endpoint,
#   etcd-s3-access-key, etcd-s3-secret-key), written to a drop-in k3s reads
#   next to its config file.
# - A server takes a snapshot as it shuts down for a reboot into a new k3s
#   minor, while etcd is still up: the way back from a minor upgrade is a
#   snapshot the old minor took. A failed snapshot doesn't hold the reboot.
#   It reads the next system from GRUB's or systemd-boot's default entry;
#   with another bootloader it takes none.
# - A new k3s version, and on a server any change to its unit or snapshot
#   settings, is a switch inhibitor: the node picks it up in a reboot (which
#   a reboot policy such as kured drains first) instead of a live restart.
#   Agents restart k3s on a switch. No automatic rollback or trial boot
#   crosses a k3s version or a server's data dir (ethpandaops.rollback.guard):
#   k3s can't run an older minor on a datastore a newer one migrated.
# - Graceful node shutdown, with logind allowing the kubelet to delay a
#   shutdown that long.
# - Checks: k3s (the unit), kubelet (its /healthz) and node-ready (the Node
#   is Ready, through the kubelet's own credentials, ethpandaops.kubernetes).
#   On agents the first two are outside health checks, so a broken agent
#   rolls back, and a server outage that fails them too gets a second try;
#   on servers they're readiness checks. Set ethpandaops.checks.<name> to
#   change them.
#
# The k3s package is the consumer's: set it per cluster. An agent may never
# run a newer minor than its servers.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.k3s;
  isServer = cfg.role == "server";
  initsEtcd = isServer && cfg.serverAddr == null;
  snapshots = isServer && cfg.etcdSnapshots.enable;
  defaultDataDir = "/var/lib/rancher/k3s";

  etcdGuard = pkgs.writeShellScript "k3s-etcd-guard" ''
    if [ ! -d ${cfg.dataDir}/server/db/etcd/member ] && [ ! -e ${cfg.bootstrapFile} ]; then
      echo "${cfg.dataDir} has no etcd member: not starting a new cluster. To start one: install -D /dev/null ${cfg.bootstrapFile}" >&2
      exit 1
    fi
  '';
  bootstrapCleanup = pkgs.writeShellScript "k3s-bootstrap-cleanup" ''
    if [ -e ${cfg.bootstrapFile} ] && [ -d ${cfg.dataDir}/server/db/etcd/member ]; then
      rm -f ${cfg.bootstrapFile}
      echo "etcd is up; removed ${cfg.bootstrapFile}"
    fi
    exit 0
  '';

  # Snapshots when the system the bootloader boots next has another k3s
  # minor than the running one.
  preMinorSnapshot = pkgs.writeShellApplication {
    name = "k3s-pre-minor-snapshot";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      jq
      systemd
    ];
    text = ''
      ${config.ethpandaops.lib.bootDefault}
      minor() { cut -d. -f1-2 "$1/etc/nixhost/k3s-version" 2>/dev/null || echo unknown; }
      next=$(boot_default || true)
      if [ -n "$next" ] && [ "$(minor "$next")" != "$(minor /run/current-system)" ]; then
        ${cfg.package}/bin/k3s etcd-snapshot save --data-dir ${cfg.dataDir} --name pre-minor-upgrade
      fi
    '';
  };

  snapshotSettings = {
    inherit (cfg.etcdSnapshots)
      schedule
      retention
      bucket
      folder
      region
      ;
  };
in
{
  options.ethpandaops.k3s = {
    package = lib.mkOption {
      type = lib.types.package;
      example = lib.literalExpression "pkgs.k3s_1_35";
      description = "The k3s this node runs. Set it per cluster: there's no default, so a module update never moves a cluster's k3s.";
    };
    role = lib.mkOption {
      type = lib.types.enum [
        "server"
        "agent"
      ];
    };
    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "The Kubernetes Node name.";
    };
    nodeIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "k3s --node-ip, or null for k3s's own choice.";
    };
    nodeExternalIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "k3s --node-external-ip.";
    };
    labels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Node labels. k3s applies them only when the node first registers.";
    };
    taints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "node-role.kubernetes.io/control-plane:NoSchedule" ];
      description = "Node taints, applied only when the node first registers, like labels.";
    };
    serverAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://192.0.2.10:6443";
      description = "The server to register with: required on an agent; on a server, joins that server's etcd cluster instead of starting one.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "k3s --token-file: the cluster's token, required to join. A server that starts a cluster without one generates it.";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = defaultDataDir;
      description = "k3s --data-dir.";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--flannel-backend=none" ];
      description = "More k3s flags, after the ones the other options set.";
    };
    bootstrapFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixhost-k3s/bootstrap-etcd";
      description = "Create this file to let a server whose data dir has no etcd start a new cluster.";
    };
    gracefulShutdown = {
      period = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Seconds the kubelet delays a shutdown for its pods; at least their termination grace period plus criticalPods.";
      };
      criticalPods = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Seconds of the period kept for critical pods.";
      };
    };
    etcdSnapshots = {
      enable = lib.mkEnableOption "scheduled etcd snapshots to S3-compatible storage on servers";
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "0 */6 * * *";
        description = "Cron schedule.";
      };
      retention = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Scheduled snapshots each server keeps.";
      };
      bucket = lib.mkOption { type = lib.types.str; };
      folder = lib.mkOption {
        type = lib.types.str;
        description = "The folder in the bucket, one per cluster.";
      };
      region = lib.mkOption {
        type = lib.types.str;
        default = "us-east-1";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = !snapshots || config.services.k3s.configPath == null;
        message = "ethpandaops.k3s.etcdSnapshots writes a drop-in next to k3s's default config file; leave services.k3s.configPath unset.";
      }
      {
        assertion = cfg.gracefulShutdown.criticalPods < cfg.gracefulShutdown.period;
        message = "ethpandaops.k3s.gracefulShutdown.criticalPods must be less than its period.";
      }
    ];

    services.k3s = {
      enable = true;
      inherit (cfg) package role nodeName;
      nodeIP = cfg.nodeIP;
      nodeExternalIP = cfg.nodeExternalIP;
      nodeLabel = lib.mapAttrsToList (k: v: "${k}=${v}") cfg.labels;
      nodeTaint = cfg.taints;
      serverAddr = lib.mkIf (cfg.serverAddr != null) cfg.serverAddr;
      tokenFile = cfg.tokenFile;
      clusterInit = initsEtcd;
      gracefulNodeShutdown = {
        enable = true;
        shutdownGracePeriod = "${toString cfg.gracefulShutdown.period}s";
        shutdownGracePeriodCriticalPods = "${toString cfg.gracefulShutdown.criticalPods}s";
      };
      extraFlags =
        lib.optional (cfg.dataDir != defaultDataDir) "--data-dir=${cfg.dataDir}" ++ cfg.extraFlags;
    };

    systemd.services.k3s = {
      serviceConfig = lib.mkIf initsEtcd {
        ExecStartPre = [ etcdGuard ];
        ExecStartPost = [ bootstrapCleanup ];
      };
      # Restarting a server's apiserver and etcd is an outage on a cluster
      # with one server, so a server's change waits for its reboot.
      restartIfChanged = !isServer;
    };

    system.switch.inhibitors = {
      k3s-version = cfg.package.version;
    }
    // lib.optionalAttrs isServer {
      k3s-server-unit = builtins.hashString "sha256" (
        toString config.systemd.services.k3s.serviceConfig.ExecStart
      );
    }
    # The snapshot settings, not the endpoint and keys: they're in the sops
    # file with other secrets, whose every edit would then reboot the
    # server. Rotating them takes a k3s restart.
    // lib.optionalAttrs snapshots {
      k3s-server-snapshots = builtins.hashString "sha256" (builtins.toJSON snapshotSettings);
    };

    ethpandaops.rollback.guard = {
      k3s-version = cfg.package.version;
    }
    // lib.optionalAttrs isServer {
      k3s-data-dir = cfg.dataDir;
    };

    environment.etc."nixhost/k3s-version".text = cfg.package.version;
    # Stops before k3s does, so etcd is still up. The bootloader's default
    # entry is the next boot whichever profile installed it.
    systemd.services.k3s-pre-minor-snapshot = lib.mkIf isServer {
      description = "etcd snapshot before a reboot into a new k3s minor";
      after = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = lib.getExe preMinorSnapshot;
        TimeoutStopSec = "5min";
      };
    };

    # The kubelet can't raise this itself on NixOS.
    services.logind.settings.Login.InhibitDelayMaxSec = cfg.gracefulShutdown.period + 30;

    sops.secrets = lib.mkIf snapshots {
      etcd-s3-endpoint = { };
      etcd-s3-access-key = { };
      etcd-s3-secret-key = { };
    };
    sops.templates."k3s-etcd-snapshots.yaml" = lib.mkIf snapshots {
      path = "/etc/rancher/k3s/config.yaml.d/etcd-snapshots.yaml";
      content = ''
        etcd-snapshot-schedule-cron: "${cfg.etcdSnapshots.schedule}"
        etcd-snapshot-retention: ${toString cfg.etcdSnapshots.retention}
        etcd-s3: true
        etcd-s3-endpoint: "${config.sops.placeholder.etcd-s3-endpoint}"
        etcd-s3-access-key: "${config.sops.placeholder.etcd-s3-access-key}"
        etcd-s3-secret-key: "${config.sops.placeholder.etcd-s3-secret-key}"
        etcd-s3-bucket: "${cfg.etcdSnapshots.bucket}"
        etcd-s3-folder: "${cfg.etcdSnapshots.folder}"
        etcd-s3-region: "${cfg.etcdSnapshots.region}"
        etcd-s3-skip-ssl-verify: false
        etcd-s3-insecure: false
        etcd-s3-timeout: "5m0s"
      '';
    };

    ethpandaops.kubernetes = {
      kubeconfig = lib.mkDefault "${cfg.dataDir}/agent/kubelet.kubeconfig";
      nodeName = lib.mkDefault cfg.nodeName;
      unit = lib.mkDefault "k3s.service";
    };

    ethpandaops.checks = {
      k3s = {
        kind = lib.mkDefault (if isServer then "readiness" else "health");
        outside = lib.mkDefault (!isServer);
        unit = "k3s.service";
        timeout = lib.mkDefault (if isServer then 600 else 300);
      };
      kubelet = {
        kind = lib.mkDefault (if isServer then "readiness" else "health");
        outside = lib.mkDefault (!isServer);
        http = "http://127.0.0.1:10248/healthz";
        timeout = lib.mkDefault (if isServer then 600 else 300);
      };
      node-ready = {
        k8sNode = { };
        timeout = lib.mkDefault 900;
      };
    };
  };
}
