{
  description = "NixOS modules";

  # Make these follow your own nixpkgs, so your flake.lock has one nixpkgs:
  #   inputs.nixos-modules.inputs.nixpkgs.follows = "nixpkgs";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    srvos = {
      url = "github:nix-community/srvos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      srvos,
      disko,
      sops-nix,
      comin,
    }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # A `key` lets the module system import each module once, even when a
      # configuration imports it directly and through `default`.
      module = name: imports: {
        key = "github:ethpandaops/nixos-modules#nixosModules.${name}";
        _file = "${self}/flake.nix#nixosModules.${name}";
        inherit imports;
      };
    in
    {
      nixosModules = {
        base = module "base" [
          srvos.nixosModules.server
          ./modules/base.nix
          ./modules/kernel-modules.nix
        ];
        users = module "users" [ ./modules/users.nix ];
        secrets = module "secrets" [
          sops-nix.nixosModules.sops
          ./modules/secrets.nix
        ];
        deploy = module "deploy" [
          comin.nixosModules.comin
          {
            # Read by the deploy lag check for nixhost_modules_last_modified_timestamp_seconds.
            environment.etc."nixhost/modules.json".text = builtins.toJSON {
              rev = self.rev or "dirty";
              lastModified = self.lastModified or 0;
            };
          }
          ./modules/deploy
          ./modules/fingerprint.nix
        ];
        reboot-detect = module "reboot-detect" [ ./modules/updates/reboot-detect.nix ];
        reboot-interactive = module "reboot-interactive" [
          self.nixosModules.reboot-detect
          self.nixosModules.users
          ./modules/updates/reboot-interactive.nix
        ];
        monitoring = module "monitoring" [ ./modules/monitoring ];
        static-network = module "static-network" [ ./modules/static-network.nix ];
        raid1-disks = module "raid1-disks" [
          disko.nixosModules.disko
          ./modules/raid1-disks.nix
        ];

        # What every server gets. Add static-network and raid1-disks for bare
        # metal, and reboot-interactive for a box with an interactive user.
        default = module "default" [
          self.nixosModules.base
          self.nixosModules.users
          self.nixosModules.secrets
          self.nixosModules.deploy
          self.nixosModules.reboot-detect
          self.nixosModules.monitoring
        ];
      };

      # The scripts behind the reusable workflows, for host repos' CI (ci/).
      packages.${system} = import ./ci { inherit pkgs lib; };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = import ./tests {
        inherit
          self
          pkgs
          lib
          nixpkgs
          disko
          ;
      };
    };
}
