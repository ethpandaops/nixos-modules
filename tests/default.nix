# Everything `nix flake check` runs. The VM tests need KVM; GitHub's hosted
# Linux runners have it.
{
  self,
  pkgs,
  lib,
  nixpkgs,
  disko,
}:
let
  # Every module together, the way a server configuration uses them.
  server = nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.default
      self.nixosModules.static-network
      self.nixosModules.raid1-disks
      self.nixosModules.reboot-interactive
      ./server.nix
    ];
  };

  vmTest =
    file:
    pkgs.testers.runNixOSTest {
      imports = [ (import file { inherit self lib pkgs; }) ];
      # Fail with a log well before CI's job timeout cancels the run.
      globalTimeout = 1200;
    };
  raid1Test =
    efi:
    import ./vm/raid1-disks.nix {
      inherit
        self
        pkgs
        nixpkgs
        disko
        efi
        ;
    };
  trialTest =
    efi: scenario:
    import ./vm/reboot-trial.nix {
      inherit
        self
        pkgs
        nixpkgs
        disko
        efi
        scenario
        ;
    };
in
{
  server = server.config.system.build.toplevel;

  access = vmTest ./vm/access.nix;
  hardening = vmTest ./vm/hardening.nix;
  reboot-policy = vmTest ./vm/reboot-policy.nix;
  health-check = vmTest ./vm/health-check.nix;
  checks = vmTest ./vm/checks.nix;
  k3s-checks = vmTest ./vm/k3s-checks.nix;
  monitoring = vmTest ./vm/monitoring.nix;
  drift = vmTest ./vm/drift.nix;
  logs = vmTest ./vm/logs.nix;
  vulnix = vmTest ./vm/vulnix.nix;
  kernel = vmTest ./vm/kernel.nix;
  raid1-disks-bios = raid1Test false;
  raid1-disks-uefi = raid1Test true;
  reboot-trial-bios = trialTest false "core";
  reboot-trial-uefi = trialTest true "core";
  reboot-trial-hangs = trialTest false "hangs";
  reboot-trial-boot-md12 = trialTest false "md12";
  reboot-trial-boot-md10 = trialTest false "md10";
  comin-ssh = vmTest ./vm/comin-ssh.nix;
  banlist = vmTest ./vm/banlist.nix;
  k3s = vmTest ./vm/k3s.nix;
  digitalocean = vmTest ./vm/digitalocean.nix;
  digitalocean-disk = import ./vm/digitalocean-disk.nix {
    inherit
      self
      pkgs
      nixpkgs
      disko
      ;
  };

  # The k3s module's agents and joining servers, which the VM test's single
  # server doesn't show. Evaluated, not built.
  k3s-roles =
    let
      node =
        settings:
        (server.extendModules {
          modules = [
            self.nixosModules.k3s
            {
              ethpandaops.k3s = {
                package = pkgs.k3s;
              }
              // settings;
            }
          ];
        }).config;
      join = {
        serverAddr = "https://192.0.2.1:6443";
        tokenFile = "/run/k3s-token";
      };
      snapshots = {
        enable = true;
        bucket = "etcd";
        folder = "example";
      };
      agent = node ({ role = "agent"; } // join);
      first = node {
        role = "server";
        etcdSnapshots = snapshots;
      };
      joining = node ({ role = "server"; } // join);

      execStart = c: c.systemd.services.k3s.serviceConfig.ExecStart;
      guarded =
        c:
        lib.hasInfix "k3s-etcd-guard" (toString (c.systemd.services.k3s.serviceConfig.ExecStartPre or [ ]));
      inhibitors = c: lib.filter (lib.hasPrefix "k3s") (lib.attrNames c.system.switch.inhibitors);
      kubeletConfigRefused =
        flags:
        refused "ethpandaops.k3s.extraFlags sets the kubelet's config file" (node {
          role = "server";
          extraFlags = flags;
        });
      results = {
        "every spelling of the kubelet's config file in extraFlags is refused" =
          lib.all kubeletConfigRefused
            [
              [ "--kubelet-arg=config=/x" ]
              [
                "--kubelet-arg"
                "config=/x"
              ]
              [ "--kubelet-arg config=/x" ]
              [ "--kubelet-arg=--config=/x" ]
            ];
        "other kubelet args are accepted" =
          !kubeletConfigRefused [
            "--kubelet-arg=max-pods=200"
            "--node-label=config=x"
          ];
        "agent registers with its server" = lib.hasInfix "--server https://192.0.2.1:6443" (
          execStart agent
        );
        "agent restarts on a switch" = agent.systemd.services.k3s.restartIfChanged;
        "agent has no etcd guard" = !guarded agent;
        "agent has no pre-minor snapshot" = !(agent.systemd.services ? k3s-pre-minor-snapshot);
        "agent's switch inhibitors" = inhibitors agent == [ "k3s-version" ];
        "agent's rollback guard" = lib.attrNames agent.ethpandaops.rollback.guard == [ "k3s-minor" ];
        "agent's k3s checks are outside health checks" =
          lib.all (c: agent.ethpandaops.checks.${c}.kind == "health" && agent.ethpandaops.checks.${c}.outside)
            [
              "k3s"
              "kubelet"
            ];
        "server's k3s checks are readiness checks" =
          lib.all
            (c: first.ethpandaops.checks.${c}.kind == "readiness" && !first.ethpandaops.checks.${c}.outside)
            [
              "k3s"
              "kubelet"
            ];
        "first server starts etcd" = lib.hasInfix "--cluster-init" (execStart first);
        "first server has the etcd guard" = guarded first;
        "first server waits for a reboot" = !first.systemd.services.k3s.restartIfChanged;
        "first server's switch inhibitors" =
          inhibitors first == [
            "k3s-server-snapshots"
            "k3s-server-unit"
            "k3s-version"
          ];
        "joining server joins" =
          lib.hasInfix "--server https://192.0.2.1:6443" (execStart joining)
          && !lib.hasInfix "--cluster-init" (execStart joining);
        "joining server has no etcd guard" = !guarded joining;
        "joining server's snapshot inhibitor is off" =
          joining.system.switch.inhibitors.k3s-server-snapshots == "off";
      };
      # Settings the module refuses, each by the start of its message.
      refusals = {
        "ethpandaops.k3s.serverAddr is required" = node { role = "agent"; };
        "ethpandaops.k3s.tokenFile is required" = node {
          role = "agent";
          serverAddr = "https://192.0.2.1:6443";
        };
        "ethpandaops.k3s.dataDir is" =
          (server.extendModules {
            modules = [
              self.nixosModules.k3s
              {
                ethpandaops.k3s = {
                  package = pkgs.k3s;
                  role = "server";
                  dataDir = "/srv/k3s";
                };
                services.k3s.manifests.example.content = { };
              }
            ];
          }).config;
      };
      refused = message: c: lib.any (a: !a.assertion && lib.hasPrefix message a.message) c.assertions;
      failed =
        lib.attrNames (lib.filterAttrs (_: ok: !ok) results)
        ++ map (m: "accepted: ${m}") (lib.attrNames (lib.filterAttrs (m: c: !refused m c) refusals));
    in
    pkgs.runCommand "k3s-roles" { failed = lib.concatStringsSep "; " failed; } ''
      if [ -n "$failed" ]; then
        echo "k3s-roles failed: $failed"
        exit 1
      fi
      touch $out
    '';

  # raid1-disks refuses a kernel that can't assemble arrays made by a newer one.
  raid1-rejects-old-kernel =
    let
      failed =
        lib.filter (a: !a.assertion)
          (server.extendModules {
            modules = [ { boot.kernelPackages = lib.mkForce pkgs.linuxPackages_6_18; } ];
          }).config.assertions;
    in
    pkgs.runCommand "raid1-rejects-old-kernel" { } (
      if lib.any (a: lib.hasInfix "can't assemble md arrays" a.message) failed then
        "touch $out"
      else
        "echo 'raid1-disks accepted a 6.18 kernel'; exit 1"
    );

  # The keys rollouts read (the promoter classifies changes by them).
  fingerprint =
    let
      keys = lib.attrNames server.config.ethpandaops.fingerprint;
      expected = [
        "inhibitors"
        "initrd"
        "kernel"
        "kernelModules"
        "kernelParams"
        "kernelVersion"
        "nixosRelease"
        "systemd"
        "toplevel"
      ];
    in
    pkgs.runCommand "fingerprint" { } (
      if keys == expected then "touch $out" else "echo 'fingerprint keys: ${toString keys}'; exit 1"
    );

  # fingerprint.toplevel ignores the configuration revision, which changes
  # the system itself (nixos-version reports it). Evaluated, not built.
  fingerprint-revision =
    let
      at =
        rev:
        (server.extendModules {
          modules = [ { system.configurationRevision = rev; } ];
        }).config;
      a = at "1111111111111111111111111111111111111111";
      b = at "2222222222222222222222222222222222222222";
    in
    pkgs.runCommand "fingerprint-revision" { } (
      if a.ethpandaops.fingerprint.toplevel != b.ethpandaops.fingerprint.toplevel then
        "echo 'fingerprint.toplevel changes with the configuration revision'; exit 1"
      else if a.system.build.toplevel.drvPath == b.system.build.toplevel.drvPath then
        "echo 'the configuration revision does not change the system, so this proves nothing'; exit 1"
      else
        "touch $out"
    );

  # lib.rolloutPlan over a small fleet made from the example server: the
  # order it promises (canaries cheapest group first, groups in order with
  # their lead host first, `last` groups at the end), and the JSON the
  # promoter's tests check they can step through (promoter, PLAN_JSON).
  rollout-plan =
    let
      host =
        name: env: group: extra:
        server.extendModules {
          modules = [
            {
              networking.hostName = lib.mkForce name;
              ethpandaops.host = {
                fleet = "example";
                environment = lib.mkForce env;
              };
              ethpandaops.deploy.branch = "deploy/${name}";
              ethpandaops.rollout = {
                inherit group;
              }
              // extra;
            }
          ];
        };
      plan = self.lib.rolloutPlan {
        hosts = {
          s-small-1 = host "s-small-1" "staging" "small" { };
          s-server = host "s-server" "staging" "server" { };
          p-large-1 = host "p-large-1" "production" "large" { canary = true; };
          p-small-1 = host "p-small-1" "production" "small" { canary = true; };
          p-small-2 = host "p-small-2" "production" "small" { };
          p-small-3 = host "p-small-3" "production" "small" { lead = true; };
          p-server = host "p-server" "production" "server" { };
          p-precious = host "p-precious" "production" "precious" { };
        };
        groups = [
          "small"
          "large"
          "server"
        ];
        last = [ "precious" ];
        windows.production = {
          start = "07:00";
          end = "16:00";
        };
      };
      waves = env: map (w: [ w.name ] ++ w.hosts) plan.environments.${env}.waves;
      expected = {
        staging = [
          [
            "small"
            "s-small-1"
          ]
          [
            "server"
            "s-server"
          ]
        ];
        production = [
          [
            "canary"
            "p-small-1"
            "p-large-1"
          ]
          [
            "small"
            "p-small-3"
            "p-small-2"
          ]
          [
            "server"
            "p-server"
          ]
          [
            "precious"
            "p-precious"
          ]
        ];
      };
      ok =
        waves "staging" == expected.staging
        && waves "production" == expected.production
        && plan.hosts.p-small-2.deployBranch == "deploy/p-small-2"
        && plan.windows.production.start == 420;
    in
    pkgs.writeText "rollout-plan.json" (
      assert lib.assertMsg ok
        "rolloutPlan: ${
          builtins.toJSON {
            staging = waves "staging";
            production = waves "production";
          }
        }";
      builtins.toJSON plan
    );

  # The promoter's tests: its decisions, and promote.py against a real git
  # remote with SSH-signed commits and fake nix, kubectl and gh.
  promoter =
    pkgs.runCommand "promoter"
      {
        nativeBuildInputs = with pkgs; [
          python3
          ruff
          git
          openssh
        ];
        PLAN_JSON = self.checks.x86_64-linux.rollout-plan;
      }
      ''
        export HOME=$TMPDIR
        cp -r ${../rollout/promoter} promoter
        chmod -R u+w promoter
        cd promoter
        ruff check --no-cache .
        ruff format --no-cache --check .
        PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v
        touch $out
      '';

  # cve-scan's evidence, on NVD's records of CVEs vulnix matched to the wrong
  # package (each gets the reason a person found when triaging it) and of the
  # same CVEs against versions they do affect (no reason, so no whitelist
  # entry: a wrong one would hide a real CVE).
  cve-evidence =
    pkgs.runCommand "cve-evidence"
      {
        nativeBuildInputs = [ self.packages.x86_64-linux.cve-evidence ];
        nvd = ./fixtures/nvd;
        patch = ./fixtures/2.42-master.patch;
      }
      ''
        # check <expected kinds> <cve> <pname> <version> <source url> [patch]
        check() {
          local want=$1 cve=$2 got
          shift 2
          got=$(cve-evidence "$nvd/$cve.json" "$@" | cut -d: -f1 | paste -sd' ' -)
          if [ "$got" != "$want" ]; then
            echo "$cve $1 $2: got '$got', want '$want'"
            cve-evidence "$nvd/$cve.json" "$@"
            exit 1
          fi
        }
        zlib=https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz
        brotli=https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz
        perl=mirror://cpan/src/5.0/perl-5.42.3.tar.xz
        glibc=mirror://gnu/glibc/glibc-2.42.tar.xz

        # Ruby's zlib gem, not the C library.
        check "vendor" CVE-2026-27820 zlib 1.3.2 $zlib
        # Go's brotli; Google's was fixed in 1.2.1.
        check "vendor version version" CVE-2026-111497 brotli 1.2.1 $brotli
        check "" CVE-2026-111497 brotli 1.2.0 $brotli
        check "" CVE-2026-111497 brotli 1.2.0 ""
        # Fixed in 5.42.3-RC1, though NVD's range runs to 5.43.10.
        check "version" CVE-2026-8376 perl 5.42.3 $perl
        check "version" CVE-2026-13221 perl 5.42.3-env ""
        check "" CVE-2026-8376 perl 5.42.2 $perl
        check "" CVE-2026-8376 perl 5.40.4 $perl
        check "" CVE-2026-8376 perl 5.43.10 $perl
        # Fixed by a patch nixpkgs applies.
        check "patch" CVE-2026-5450 glibc 2.42-103 $glibc $patch
        check "" CVE-2026-5450 glibc 2.42-103 $glibc
        touch $out
      '';

  # The CI scripts build, which shellchecks them.
  ci = pkgs.symlinkJoin {
    name = "ci";
    paths = lib.attrValues self.packages.x86_64-linux;
  };

  formatting = pkgs.runCommand "formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
    cd ${self}
    find . -name '*.nix' -print0 | xargs -0 nixfmt --check
    touch $out
  '';

  workflows =
    pkgs.runCommand "workflows"
      {
        nativeBuildInputs = [
          pkgs.actionlint
          pkgs.shellcheck
        ];
      }
      ''
        cd ${self}
        actionlint .github/workflows/*.yaml
        touch $out
      '';
}
