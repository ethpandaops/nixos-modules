# A DigitalOcean droplet made from a custom image: nixpkgs' DigitalOcean
# image (system.build.digitalOceanImage, a gzipped qcow2 to upload as a
# custom image) with GRUB on /dev/vda and a root filesystem that grows to the
# droplet's disk, and networking from DigitalOcean's DHCP and the droplet
# metadata (http://169.254.169.254/metadata/v1.json):
#
# - the public NIC takes its address and DNS from DHCP, which DigitalOcean
#   serves droplets made from custom images, on UDP 67: a cloud firewall
#   in front must let it out. Custom images get no IPv6 and no anchor IP;
#   a reserved IP maps to the public address;
# - the VPC NIC takes its address from the metadata at each boot, with the
#   routes to the rest of 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16
#   through the VPC gateway, which DigitalOcean only sets up for its own
#   images. digitalocean-network.service fails if the NICs' MACs don't
#   match the metadata's, and network-online.target waits for it;
# - the image doesn't rebuild itself from user data, run the vendor data's
#   entropy script, write root's authorized_keys (root can't log in) or run
#   do-agent. metadataKeysUser lets one account accept the droplet's SSH keys.
# - nixpkgs adds panic=1 and boot.panic_on_fail to every boot, so an initrd
#   failure reboots after a second; the way back is GRUB's menu on the
#   droplet console. Trials are unaffected: their panic=60 comes later.
#
# The image has no host key and no deploy key: SSH makes the host key at the
# first boot, so a droplet's sops recipient is only known once it runs.
# Read it (ssh-keyscan, ssh-to-age), encrypt the host's secrets to it, with
# comin's deploy key among them (deploy.deployKeyFile), and switch the
# droplet to its configuration once with nixos-rebuild --target-host. Bake
# neither key into the image: DigitalOcean keeps it in the account, and
# every droplet made from it would share them.
#
# Droplets have no hardware watchdog, so reboot trials run without one.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.ethpandaops.digitalocean;
  metadata = "/run/do-metadata/v1.json";
  keysDir = "/run/do-metadata/authorized_keys.d";
  privateDropIn = "/run/systemd/network/10-digitalocean-private.network.d";

  privateNetwork = pkgs.writeShellApplication {
    name = "digitalocean-network";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      systemd
    ];
    text = ''
      metadata=${metadata}
      public=${lib.escapeShellArg cfg.interfaces.public}
      private=${lib.escapeShellArg cfg.interfaces.private}

      check_mac() {
        local nic=$1 kind=$2 want have
        want=$(jq -er --arg kind "$kind" '.interfaces[$kind][0].mac' "$metadata")
        have=$(cat "/sys/class/net/$nic/address" 2>/dev/null || echo none)
        if [ "''${want,,}" != "''${have,,}" ]; then
          echo "the droplet's $kind NIC is $want, but $nic is $have: set ethpandaops.digitalocean.interfaces.$kind" >&2
          exit 1
        fi
      }
      prefix_length() {
        local IFS=. octet bits=0
        for octet in $1; do
          while [ "$octet" -gt 0 ]; do
            bits=$((bits + (octet & 1)))
            octet=$((octet >> 1))
          done
        done
        echo "$bits"
      }

      check_mac "$public" public
      check_mac "$private" private
      address=$(jq -er '.interfaces.private[0].ipv4.ip_address' "$metadata")
      netmask=$(jq -er '.interfaces.private[0].ipv4.netmask' "$metadata")
      gateway=$(jq -r '.interfaces.private[0].ipv4.gateway // empty' "$metadata")

      mkdir -p ${privateDropIn}
      {
        echo "[Network]"
        echo "Address=$address/$(prefix_length "$netmask")"
        if [ -n "$gateway" ]; then
          for destination in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
            printf '\n[Route]\nDestination=%s\nGateway=%s\n' "$destination" "$gateway"
          done
        fi
      } >${privateDropIn}/metadata.conf.tmp
      mv ${privateDropIn}/metadata.conf.tmp ${privateDropIn}/metadata.conf
      networkctl reload
      ${config.systemd.package}/lib/systemd/systemd-networkd-wait-online --interface="$private:routable" --timeout=60
      echo "$private: $address/$(prefix_length "$netmask")''${gateway:+, other private networks through $gateway}"
    '';
  };
in
{
  imports = [
    (modulesPath + "/virtualisation/digital-ocean-image.nix")
    ./checks
  ];

  options.ethpandaops.digitalocean = {
    interfaces = {
      public = lib.mkOption {
        type = lib.types.str;
        default = "ens3";
        description = "The public NIC's name: the droplet's first virtio NIC, in PCI slot 3.";
      };
      private = lib.mkOption {
        type = lib.types.str;
        default = "ens4";
        description = "The VPC NIC's name: the droplet's second virtio NIC, in PCI slot 4.";
      };
    };
    metadataKeysUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "breakglass";
      description = ''
        An account from ethpandaops.users that also accepts the SSH keys the
        droplet was created with (the metadata's public_keys), read again at
        each boot. Whoever can create or rebuild the droplet chooses those
        keys. Null ignores them.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion =
          cfg.metadataKeysUser == null
          || lib.elem "ssh-users" (config.users.users.${cfg.metadataKeysUser}.extraGroups or [ ]);
        message = "ethpandaops.digitalocean.metadataKeysUser must be an account from ethpandaops.users.";
      }
    ];

    virtualisation.digitalOcean = {
      rebuildFromUserData = lib.mkDefault false;
      seedEntropy = lib.mkDefault false;
      setSshKeys = lib.mkDefault false;
    };
    services.do-agent.enable = lib.mkOverride 900 false;

    # The droplet console in DigitalOcean's control panel is the first virtual
    # terminal; the kernel's last console= is where an emergency shell goes.
    boot.kernelParams = lib.mkAfter [ "console=tty0" ];

    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks = {
      "10-digitalocean-public" = {
        matchConfig.Name = cfg.interfaces.public;
        networkConfig = {
          DHCP = "ipv4";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
          KeepConfiguration = "dynamic";
        };
        linkConfig.RequiredForOnline = "routable";
      };
      "10-digitalocean-private" = {
        matchConfig.Name = cfg.interfaces.private;
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
        linkConfig.RequiredForOnline = "no";
      };
    };

    systemd.services.digitalocean-metadata.serviceConfig.ExecStartPre =
      "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online --interface=${cfg.interfaces.public}:routable --timeout=120";

    systemd.services.digitalocean-network = {
      description = "Configure the VPC NIC from the droplet metadata";
      wantedBy = [
        "multi-user.target"
        "network-online.target"
      ];
      before = [ "network-online.target" ];
      requires = [ "digitalocean-metadata.service" ];
      after = [
        "digitalocean-metadata.service"
        "systemd-networkd.service"
      ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe privateNetwork;
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
    ethpandaops.checks.digitalocean-network = {
      unit = "digitalocean-network.service";
      outside = true;
    };

    # srvos sets this list with mkForce.
    services.openssh.authorizedKeysFiles = lib.mkIf (cfg.metadataKeysUser != null) (
      lib.mkOverride 49 [
        "/etc/ssh/authorized_keys.d/%u"
        "${keysDir}/%u"
      ]
    );
    systemd.services.digitalocean-authorized-keys = lib.mkIf (cfg.metadataKeysUser != null) {
      description = "Accept the droplet's SSH keys for ${cfg.metadataKeysUser}";
      wantedBy = [ "multi-user.target" ];
      requires = [ "digitalocean-metadata.service" ];
      after = [ "digitalocean-metadata.service" ];
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0755 ${keysDir}
        jq -r '.public_keys[]?' ${metadata} >${keysDir}/.tmp
        chmod 0444 ${keysDir}/.tmp
        mv ${keysDir}/.tmp ${keysDir}/${cfg.metadataKeysUser}
      '';
    };
  };
}
