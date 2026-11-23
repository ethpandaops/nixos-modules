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
  reboot-policy = vmTest ./vm/reboot-policy.nix;
  health-check = vmTest ./vm/health-check.nix;
  monitoring = vmTest ./vm/monitoring.nix;
  drift = vmTest ./vm/drift.nix;
  logs = vmTest ./vm/logs.nix;
  vulnix = vmTest ./vm/vulnix.nix;
  raid1-disks-bios = raid1Test false;
  raid1-disks-uefi = raid1Test true;
  comin-ssh = vmTest ./vm/comin-ssh.nix;

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
