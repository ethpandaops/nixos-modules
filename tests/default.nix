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
in
{
  server = server.config.system.build.toplevel;

  access = vmTest ./vm/access.nix;
  hardening = vmTest ./vm/hardening.nix;
  reboot-policy = vmTest ./vm/reboot-policy.nix;
  health-check = vmTest ./vm/health-check.nix;
  monitoring = vmTest ./vm/monitoring.nix;
  drift = vmTest ./vm/drift.nix;
  logs = vmTest ./vm/logs.nix;
  vulnix = vmTest ./vm/vulnix.nix;
  kernel = vmTest ./vm/kernel.nix;
  raid1-disks-bios = raid1Test false;
  raid1-disks-uefi = raid1Test true;
  comin-ssh = vmTest ./vm/comin-ssh.nix;
  banlist = vmTest ./vm/banlist.nix;

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

  # The keys rollouts read (nixos-utility's promoter classifies changes by them).
  fingerprint =
    let
      keys = lib.attrNames server.config.ethpandaops.fingerprint;
      expected = [
        "inhibitors"
        "initrd"
        "kernel"
        "kernelModules"
        "kernelParams"
        "systemd"
        "toplevel"
      ];
    in
    pkgs.runCommand "fingerprint" { } (
      if keys == expected then "touch $out" else "echo 'fingerprint keys: ${toString keys}'; exit 1"
    );

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
