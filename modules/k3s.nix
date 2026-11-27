# k3s for either role (ethpandaops.k3s), with an etcd guard and snapshots on
# servers, and the switch inhibitors, rollback guards and checks the deploy
# module needs. Each cluster sets its own k3s package.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.k3s;
  k3s = config.services.k3s;
  isServer = cfg.role == "server";
  initsEtcd = isServer && cfg.serverAddr == null;
  snapshots = isServer && cfg.etcdSnapshots.enable;
  defaultDataDir = "/var/lib/rancher/k3s";
  arg = lib.escapeShellArg;

  etcdGuard = pkgs.writeShellScript "k3s-etcd-guard" ''
    data=${arg cfg.dataDir}
    bootstrap=${arg cfg.bootstrapFile}
    if [ ! -d "$data/server/db/etcd/member" ] && [ ! -e "$bootstrap" ]; then
      {
        echo "$data has no etcd member: not starting a new cluster."
        echo "Check that $data is mounted."
        echo "To recover, restore a snapshot (k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>), or rejoin through serverAddr if other servers exist."
        echo "Only for a brand-new cluster: install -D /dev/null $bootstrap"
      } >&2
      exit 1
    fi
  '';
  bootstrapCleanup = pkgs.writeShellScript "k3s-bootstrap-cleanup" ''
    bootstrap=${arg cfg.bootstrapFile}
    if [ -e "$bootstrap" ] && [ -d ${arg cfg.dataDir}/server/db/etcd/member ]; then
      rm -f "$bootstrap"
      echo "etcd is up; removed $bootstrap"
    fi
    exit 0
  '';

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
        ${cfg.package}/bin/k3s etcd-snapshot save --data-dir ${arg cfg.dataDir} --name pre-minor-upgrade
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
      description = "The k3s this node runs. Set it per cluster: there's no default, so a module update never moves a cluster's k3s. An agent must never run a newer minor than its servers, since the kubelet may not be newer than the apiserver.";
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
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/k3s-token";
      description = "k3s --token-file: a path on the node (not a Nix path, which would put the token in the store), required with serverAddr. A server that starts a cluster without one generates it.";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = defaultDataDir;
      description = "k3s --data-dir. k3s waits for it to be mounted. nixpkgs writes services.k3s.images, manifests, charts, autoDeployCharts and containerdConfigTemplate under the default only, so they can't be used with another.";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--flannel-backend=none" ];
      description = "More k3s flags, after the ones the other options set. Kubelet settings go in services.k3s.extraKubeletConfig: a --kubelet-arg=config= here would replace the module's kubelet config.";
    };
    bootstrapFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixhost-k3s/bootstrap-etcd";
      description = "A server that would start embedded etcd refuses to while its data dir has no etcd member, unless this file exists; it's removed once etcd is up.";
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
      enable = lib.mkEnableOption "scheduled etcd snapshots to S3-compatible storage on servers, with the endpoint and keys from the sops secrets etcd-s3-endpoint, etcd-s3-access-key and etcd-s3-secret-key";
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
      {
        assertion = isServer || cfg.serverAddr != null;
        message = "ethpandaops.k3s.serverAddr is required on an agent.";
      }
      {
        assertion = cfg.serverAddr == null || cfg.tokenFile != null;
        message = "ethpandaops.k3s.tokenFile is required with serverAddr: a node can't join without the cluster's token.";
      }
      {
        assertion =
          cfg.dataDir == defaultDataDir
          || (
            k3s.images == [ ]
            && k3s.manifests == { }
            && k3s.charts == { }
            && k3s.autoDeployCharts == { }
            && k3s.containerdConfigTemplate == null
          );
        message = "ethpandaops.k3s.dataDir is ${cfg.dataDir}, but nixpkgs writes services.k3s.images, manifests, charts, autoDeployCharts and containerdConfigTemplate under ${defaultDataDir}, where this k3s never reads them. Leave them unset or keep the default data dir.";
      }
      {
        assertion = !lib.any (lib.hasPrefix "--kubelet-arg=config=") cfg.extraFlags;
        message = "ethpandaops.k3s.extraFlags has --kubelet-arg=config=, which replaces the module's kubelet config (graceful shutdown included); set services.k3s.extraKubeletConfig instead.";
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
      unitConfig.RequiresMountsFor = [ cfg.dataDir ];
      serviceConfig = lib.mkIf initsEtcd {
        ExecStartPre = [ etcdGuard ];
        ExecStartPost = [ bootstrapCleanup ];
      };
      # Restarting a server takes its apiserver and etcd down, an outage on a
      # one-server cluster, so a server picks changes up at its reboot.
      restartIfChanged = !isServer;
    };

    system.switch.inhibitors = {
      k3s-version = cfg.package.version;
    }
    // lib.optionalAttrs isServer {
      k3s-server-unit = builtins.hashString "sha256" (
        toString config.systemd.services.k3s.serviceConfig.ExecStart
      );
      # Not the secrets: any edit to the sops file would reboot the server.
      # Present while snapshots are off too, since NixOS compares only keys
      # both systems have.
      k3s-server-snapshots =
        if snapshots then builtins.hashString "sha256" (builtins.toJSON snapshotSettings) else "off";
    };

    # Patch releases keep the datastore format, so only a minor holds.
    ethpandaops.rollback.guard = {
      k3s-minor = lib.versions.majorMinor cfg.package.version;
    }
    // lib.optionalAttrs isServer {
      k3s-data-dir = cfg.dataDir;
    };

    environment.etc."nixhost/k3s-version".text = cfg.package.version;
    systemd.services.k3s-pre-minor-snapshot = lib.mkIf isServer {
      description = "etcd snapshot before a reboot into a new k3s minor";
      # Ordered after k3s, so it stops first, while etcd is still up.
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

    # NixOS, not sops-nix, owns the link, so it goes when snapshots are off:
    # sops-nix leaves a dropped template's link dangling, and k3s fails on
    # an unreadable drop-in.
    environment.etc."rancher/k3s/config.yaml.d/etcd-snapshots.yaml" = lib.mkIf snapshots {
      source = config.sops.templates."k3s-etcd-snapshots.yaml".path;
    };

    ethpandaops.kubernetes = {
      kubeconfig = lib.mkDefault "${cfg.dataDir}/agent/kubelet.kubeconfig";
      nodeName = lib.mkDefault cfg.nodeName;
      unit = lib.mkDefault "k3s.service";
      package = lib.mkDefault cfg.package;
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
