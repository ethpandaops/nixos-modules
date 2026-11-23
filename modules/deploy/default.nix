# Pull-based deploys with comin (comin.nixosModules.comin, imported by
# nixosModules.deploy): the box polls a branch of a git repository and
# switches to each new commit. After every deployment a health check runs
# and rolls back to the last good system if it fails. Set
# allowedSignersFile to deploy only commits signed by listed keys.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.deploy;
  hc = cfg.healthCheck;
  hostName = config.networking.hostName;

  # comin's git client (go-git) logs in as auth.username, comin's default
  # "comin", not as the user in the URL; GitHub only accepts "git".
  sshUser =
    let
      m = builtins.match "(ssh://)?([^@/:]+)@.*" cfg.repository;
    in
    if m == null then "git" else builtins.elemAt m 1;

  settings = pkgs.writeText "nixhost-deploy.json" (
    builtins.toJSON {
      inherit (cfg)
        repository
        branch
        deployKeyFile
        knownHostsFile
        ;
      # Such as 26.05.20261121.94c3211, with the nixpkgs commit date.
      nixosVersion = config.system.nixos.version;
      healthCheck = {
        inherit (hc)
          enable
          timeout
          dnsName
          checkDefaultRoute
          checkRemote
          ;
        sshPort = builtins.head config.services.openssh.ports;
        extraScript = pkgs.writeShellScript "nixhost-health-check-extra" hc.extraScript;
      };
    }
  );

  script =
    name: file: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        SETTINGS=${settings}
        NOTIFY=${lib.getExe config.ethpandaops.notify.package}
        ${config.ethpandaops.lib.shell}
        ${builtins.readFile ./common.sh}
        ${builtins.readFile file}
      '';
    };

  common = with pkgs; [
    coreutils
    gitMinimal
    openssh
    jq
    systemd
    util-linux
  ];

  postDeploy = script "nixhost-post-deploy" ./post-deploy.sh common;
  healthCheck = script "nixhost-health-check" ./health-check.sh (
    common
    ++ (with pkgs; [
      iproute2
      getent
      nix
    ])
  );
  upstreamCheck = script "nixhost-deploy-lag" ./upstream-check.sh common;
in
{
  imports = [
    ../metrics.nix
    ../notify.nix
  ];

  options.ethpandaops.deploy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run comin and the post-deploy health check.";
    };
    repository = lib.mkOption {
      type = lib.types.str;
      example = "ssh://git@github.com/example/nixos-config.git";
      description = "The repository comin pulls.";
    };
    branch = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = "The branch comin deploys with switch. Only ever fast-forward it.";
    };
    testingBranch = lib.mkOption {
      type = lib.types.str;
      default = "testing-${hostName}";
      defaultText = lib.literalExpression ''"testing-''${config.networking.hostName}"'';
      description = "A branch comin applies with `test` (not kept across reboots) when it is ahead of the main branch.";
    };
    deployKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/comin/deploy_key";
      description = ''
        The repo's read-only deploy key on the box (root, 0400), copied in at
        install with `nixos-anywhere --extra-files`. Null for a public repo.
      '';
    };
    knownHostsFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssh/ssh_known_hosts";
      description = "Pinned host keys for the remote. GitHub's are added by this module.";
    };
    pollInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds between fetches.";
    };
    allowedSignersFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../allowed_signers";
      description = ''
        An OpenSSH allowed_signers file. When set, comin deploys only commits
        signed by a key listed in it. Null deploys any commit on the branch.
      '';
    };

    healthCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Check the box after each deployment and roll back if it is broken.";
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 180;
        description = "Seconds to keep retrying the checks before rolling back.";
      };
      dnsName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "github.com";
        description = "A name that must resolve. Null skips the DNS check.";
      };
      checkDefaultRoute = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Require an IPv4 or IPv6 default route.";
      };
      checkRemote = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Require `git ls-remote` of the repository to work with the deploy key.";
      };
      extraScript = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "More bash run as a check; a non-zero exit means unhealthy.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.comin = {
      enable = true;
      remotes = [
        {
          name = "origin";
          url = cfg.repository;
          auth = lib.optionalAttrs (cfg.deployKeyFile != null) {
            username = sshUser;
            ssh_deploy_key_path = cfg.deployKeyFile;
            ssh_known_hosts_path = cfg.knownHostsFile;
          };
          branches.main.name = cfg.branch;
          branches.testing.name = cfg.testingBranch;
          poller.period = cfg.pollInterval;
        }
      ];
      # Listens on all interfaces; the firewall opens it on tailscale0 only.
      exporter.port = 4243;
      sshAllowedSignersPath = lib.mkIf (cfg.allowedSignersFile != null) "${cfg.allowedSignersFile}";
      postDeploymentCommand = lib.getExe postDeploy;
    };

    # All of GitHub's published host keys (srvos pins only ed25519), so either
    # SSH client picks a key type it can verify.
    programs.ssh.knownHosts = {
      github-ecdsa = {
        hostNames = [ "github.com" ];
        publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
      };
      github-rsa = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
      };
    };

    systemd.tmpfiles.rules = [ "d /var/lib/nixhost-deploy 0700 root root -" ];

    systemd.services.nixhost-health-check = lib.mkIf hc.enable {
      description = "Check the box after a deployment and roll back if it is broken";
      startLimitIntervalSec = 0;
      # It may switch configurations itself, so a switch must not restart or stop it.
      restartIfChanged = false;
      stopIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe healthCheck;
      };
    };

    # Revision-lag watchdog: is the remote branch ahead of what comin deployed?
    systemd.services.nixhost-deploy-lag = {
      description = "Compare the deploy branch with the deployed commit";
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe upstreamCheck;
      };
    };
    systemd.timers.nixhost-deploy-lag = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        RandomizedDelaySec = "30s";
      };
    };

    environment.systemPackages = [ healthCheck ];
  };
}
