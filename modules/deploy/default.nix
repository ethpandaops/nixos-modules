# Pull-based deploys with comin (comin.nixosModules.comin, imported by
# nixosModules.deploy): the box polls a branch of a git repository and
# switches to each new commit. After every deployment the health checks
# (ethpandaops.checks, ../checks) run and roll back to the last good system
# if one fails. This module defines the built-in ones from healthCheck:
# sshd, default-route, firewall, dns and git-remote (outside) and extra; a
# fleet can disable or override each. Automatic rollbacks stop at the
# rollback breaker (breaker.nix) and never cross ethpandaops.rollback.guard.
# Set allowedSignersFile to deploy only commits signed by listed keys.
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
  fw = config.networking.firewall;

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
        sourceBranch
        deployKeyFile
        knownHostsFile
        ;
      # Such as 26.05.20261121.94c3211, with the nixpkgs commit date.
      nixosVersion = config.system.nixos.version;
      healthCheck = { inherit (hc) enable; };
    }
  );

  script =
    name: text: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        SETTINGS=${settings}
        NOTIFY=${lib.getExe config.ethpandaops.notify.package}
        ${config.ethpandaops.lib.shell}
        ${builtins.readFile ./common.sh}
        ${text}
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

  postDeploy = script "nixhost-post-deploy" (builtins.readFile ./post-deploy.sh) common;
  healthCheck =
    script "nixhost-health-check"
      (
        config.ethpandaops.lib.checks + config.ethpandaops.lib.breaker + builtins.readFile ./health-check.sh
      )
      (
        common
        ++ [
          pkgs.gawk
          pkgs.nix
        ]
      );
  upstreamCheck = script "nixhost-deploy-lag" (builtins.readFile ./upstream-check.sh) (
    common ++ [ pkgs.gawk ]
  );

  # The built-in health checks' commands.
  ip = "${pkgs.iproute2}/bin/ip";
  sshPort = toString (builtins.head config.services.openssh.ports);
  gitRemote = script "nixhost-check-deploy-remote" ''
    branch=$(setting .branch)
    if ! err=$(git_remote --exit-code "refs/heads/$branch" 2>&1 >/dev/null); then
      echo "can't read the deploy branch $branch from the remote: $(head -n1 <<<"''${err:-no such branch}")"
      exit 1
    fi
    echo "the deploy branch $branch is on the remote"
  '' common;
in
{
  imports = [
    ./breaker.nix
    ../checks
    ../metrics.nix
    ../notify.nix
  ];

  options.ethpandaops.rollback.guard = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      k3s = "1.34";
      datastore = "etcd";
    };
    description = ''
      Values no automatic rollback may cross, such as a k3s minor version or
      a datastore setting. Each system carries its own, at
      /etc/nixhost/rollback-guard.json. A deploy whose health check fails
      isn't rolled back to a system whose guard differs: the rollback breaker
      trips and a person decides. A reboot into a system whose guard
      differs from the confirmed one's boots it without a trial.
    '';
  };

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
    sourceBranch = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "master";
      description = ''
        The branch the deploy branch is fast-forwarded from, if any. The lag
        check then also reports it differing from the deploy branch
        (nixhost_deploy_source_ahead*), which is how a commit that never
        reached the deploy branch shows: a failed check, a failed or
        cancelled deploy job.
      '';
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
        description = "Seconds to keep retrying a failing health check before rolling back: the default timeout of every health check (ethpandaops.checks).";
      };
      dnsName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "github.com";
        description = "A name that must resolve (the dns check). Null skips it.";
      };
      checkDefaultRoute = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Require an IPv4 or IPv6 default route (the default-route check).";
      };
      checkRemote = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Require `git ls-remote` of the repository to work with the deploy key (the git-remote check).";
      };
      extraScript = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          More bash run as a check (the extra check); a non-zero exit means
          unhealthy. It's shellchecked and runs with errexit, nounset and
          pipefail. Prefer a named check in ethpandaops.checks.
        '';
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

    # The built-in health checks, from healthCheck. Each field is a default, so
    # a fleet can turn one off (enable = false) or override it.
    ethpandaops.checks = {
      sshd.script = lib.mkDefault ''
        if [ -z "$(${pkgs.iproute2}/bin/ss -Hltn 'sport = :${sshPort}')" ]; then
          echo "nothing listens on TCP port ${sshPort}"
          exit 1
        fi
        echo "sshd listens on TCP port ${sshPort}"
      '';
      default-route = {
        enable = lib.mkDefault hc.checkDefaultRoute;
        script = lib.mkDefault ''
          if [ -z "$(${ip} -4 route show default)$(${ip} -6 route show default)" ]; then
            echo "no IPv4 or IPv6 default route"
            exit 1
          fi
          echo "there's a default route"
        '';
      };
      # Whether the NixOS firewall's rules are in force. A reload that fails
      # (say, a rule needs a kernel module that can't load any more) takes
      # them out and leaves the box without a firewall.
      firewall = {
        enable = lib.mkDefault fw.enable;
        script = lib.mkDefault (
          if config.networking.nftables.enable then
            ''
              if ! ${pkgs.nftables}/bin/nft list table inet nixos-fw >/dev/null 2>&1; then
                echo "the nixos-fw table isn't loaded"
                exit 1
              fi
              echo "the nixos-fw table is loaded"
            ''
          else
            ''
              if ! ${fw.package}/bin/iptables -w -C INPUT -j nixos-fw 2>/dev/null; then
                echo "INPUT doesn't jump to nixos-fw"
                exit 1
              fi
              ${lib.optionalString config.networking.enableIPv6 ''
                if ! ${fw.package}/bin/ip6tables -w -C INPUT -j nixos-fw 2>/dev/null; then
                  echo "IPv6 INPUT doesn't jump to nixos-fw"
                  exit 1
                fi
              ''}
              echo "INPUT jumps to nixos-fw"
            ''
        );
      };
      # Cached answers from before an activation (resolved's cache, and its
      # copy of /etc/hosts, reread at most every 2 s) could pass a system
      # whose DNS is broken, so flush them and let it settle first.
      dns = {
        enable = lib.mkDefault (hc.dnsName != null);
        outside = lib.mkDefault true;
        script = lib.mkDefault ''
          name=${lib.escapeShellArg hc.dnsName}
          resolvectl flush-caches 2>/dev/null || true
          sleep 3
          if ! timeout 10 getent ahosts "$name" >/dev/null; then
            echo "$name doesn't resolve"
            exit 1
          fi
          echo "$name resolves"
        '';
      };
      git-remote = {
        enable = lib.mkDefault hc.checkRemote;
        outside = lib.mkDefault true;
        script = lib.mkDefault (lib.getExe gitRemote);
      };
      extra = {
        enable = lib.mkDefault (hc.extraScript != "");
        script = lib.mkDefault hc.extraScript;
      };
    };

    environment.etc."nixhost/rollback-guard.json".text =
      builtins.toJSON config.ethpandaops.rollback.guard;

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

    # The same checks after a boot, without the rollback: it exits 0 once they
    # pass and fails when they still fail at the timeout. Nothing starts it
    # here; ethpandaops.reboot.trial runs it after every boot and hooks its
    # OnSuccess= and OnFailure=. It runs once the module lock is in force
    # (nixhost-module-lock-point, from monitoring), so a module the lock
    # refuses shows up as a failing check. It runs once per boot: a switch
    # starts multi-user.target again, which would otherwise run it again.
    systemd.services.nixhost-boot-check = lib.mkIf hc.enable {
      description = "Check the box after a boot";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "multi-user.target"
        "disable-kernel-module-loading.service"
        "nixhost-module-lock-point.service"
      ];
      restartIfChanged = false;
      unitConfig.ConditionPathExists = "!/run/nixhost-boot-check.started";
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/touch /run/nixhost-boot-check.started";
        ExecStart = "${lib.getExe healthCheck} boot";
      };
    };

    # Revision-lag watchdog: is the remote branch ahead of what comin deployed,
    # and the source branch ahead of the deploy branch?
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
