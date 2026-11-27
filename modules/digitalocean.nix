# A DigitalOcean droplet, installed with nixos-anywhere over one of
# DigitalOcean's own images (Debian, say):
#
#   nixos-anywhere --flake .#<host> --extra-files <dir> root@<droplet>
#
# <dir> holds the host's SSH host key (etc/ssh/ssh_host_ed25519_key), made
# beforehand, so its sops recipient is known and its secrets, comin's deploy
# key among them (deploy.deployKeyFile), are encrypted before the first boot.
#
# - Disk: disko's layout on `disk` (/dev/vda): a BIOS boot partition for
#   GRUB, since droplets boot with SeaBIOS, and ext4 root on the rest, which
#   reboot trials support. Root grows when the droplet is resized with its
#   disk.
# - Network: DigitalOcean serves DHCP only to droplets made from custom
#   images. Its own images are configured from the droplet metadata,
#   reached over a link-local address on the public NIC, as cloud-init does,
#   and so is this. At each boot digitalocean-network.service fetches
#   http://169.254.169.254/metadata/v1.json into metadataFile and saves a
#   copy under /var/lib/digitalocean; if the service doesn't answer, it
#   configures the network from that copy, then fails and retries until a
#   fetch works. It checks both NICs' MACs against the metadata and gives
#   them their addresses: on the public NIC
#   IPv4, the anchor IP for reserved IPs, IPv6 if the droplet has it, the
#   default routes and the DNS servers; on the VPC NIC its address and the
#   routes to the rest of 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16
#   through the VPC gateway. network-online.target waits for it, and it's an
#   outside health check, so a trial whose network never comes up reverts.
# - Nothing runs from user data or vendor data. metadataKeysUser lets one
#   account accept the droplet's SSH keys.
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
  keysDir = "/run/digitalocean/authorized_keys.d";
  saved = "/var/lib/digitalocean/metadata.json";
  waitOnline = "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online";

  network = pkgs.writeShellApplication {
    name = "digitalocean-network";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      systemd
    ];
    text = ''
      metadata=${lib.escapeShellArg cfg.metadataFile}
      public=${lib.escapeShellArg cfg.interfaces.public}
      private=${lib.escapeShellArg cfg.interfaces.private}
      saved=${saved}

      ${waitOnline} --interface="$public:degraded" --timeout=120
      install -d -m 0755 "$(dirname "$metadata")"
      install -d -m 0700 "$(dirname "$saved")"
      rm -f "$metadata.tmp"
      attempts=30
      [ ! -s "$saved" ] || attempts=5
      for _ in $(seq "$attempts"); do
        if (umask 077 && curl -fsS --max-time 5 -o "$metadata.tmp" http://169.254.169.254/metadata/v1.json); then
          break
        fi
        sleep 2
      done
      stale=
      if [ -s "$metadata.tmp" ]; then
        mv "$metadata.tmp" "$metadata"
      elif [ -s "$saved" ]; then
        echo "no droplet metadata from 169.254.169.254 on $public; using the copy saved $(date -r "$saved" -u +%FT%TZ)" >&2
        install -m 0600 "$saved" "$metadata"
        stale=1
      else
        echo "no droplet metadata from 169.254.169.254 on $public" >&2
        exit 1
      fi

      get() { jq -r "$1 // empty" "$metadata"; }
      check_mac() {
        local nic=$1 kind=$2 want have
        want=$(get ".interfaces.''${kind}[0].mac")
        have=$(cat "/sys/class/net/$nic/address" 2>/dev/null || echo none)
        if [ "''${want,,}" != "''${have,,}" ]; then
          echo "the droplet's $kind NIC is ''${want:-missing}, but $nic is $have: set ethpandaops.digitalocean.interfaces.$kind" >&2
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
      drop_in() {
        local dir=/run/systemd/network/10-digitalocean-$1.network.d
        mkdir -p "$dir"
        cat >"$dir/metadata.conf.tmp"
        mv "$dir/metadata.conf.tmp" "$dir/metadata.conf"
      }

      check_mac "$public" public
      check_mac "$private" private

      p='.interfaces.public[0]'
      {
        echo "[Network]"
        echo "Address=$(get "$p.ipv4.ip_address")/$(prefix_length "$(get "$p.ipv4.netmask")")"
        echo "Gateway=$(get "$p.ipv4.gateway")"
        if [ -n "$(get "$p.anchor_ipv4.ip_address")" ]; then
          echo "Address=$(get "$p.anchor_ipv4.ip_address")/$(prefix_length "$(get "$p.anchor_ipv4.netmask")")"
        fi
        if [ -n "$(get "$p.ipv6.ip_address")" ]; then
          echo "Address=$(get "$p.ipv6.ip_address")/$(get "$p.ipv6.cidr")"
          echo "Gateway=$(get "$p.ipv6.gateway")"
        fi
        get '.dns.nameservers[]?' | sed 's/^/DNS=/'
      } | drop_in public

      v='.interfaces.private[0]'
      gateway=$(get "$v.ipv4.gateway")
      {
        echo "[Network]"
        echo "Address=$(get "$v.ipv4.ip_address")/$(prefix_length "$(get "$v.ipv4.netmask")")"
        if [ -n "$gateway" ]; then
          for destination in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
            printf '\n[Route]\nDestination=%s\nGateway=%s\n' "$destination" "$gateway"
          done
        fi
      } | drop_in private

      networkctl reload
      ${waitOnline} --interface="$public:routable" --interface="$private:routable" --timeout=60
      echo "$public: $(get "$p.ipv4.ip_address"); $private: $(get "$v.ipv4.ip_address")"
      ${lib.optionalString (cfg.metadataKeysUser != null) ''
        install -d -m 0755 ${keysDir}
        get '.public_keys[]?' >${keysDir}/.tmp
        chmod 0444 ${keysDir}/.tmp
        mv ${keysDir}/.tmp ${keysDir}/${cfg.metadataKeysUser}
      ''}
      if [ -n "$stale" ]; then
        echo "configured from the saved metadata; retrying the metadata service" >&2
        exit 1
      fi
      install -m 0600 "$metadata" "$saved"
    '';
  };
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./checks
  ];

  options.ethpandaops.digitalocean = {
    disk = lib.mkOption {
      type = lib.types.str;
      default = "/dev/vda";
      description = "The droplet's disk, which nixos-anywhere partitions (disko).";
    };
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
    metadataFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/digitalocean/metadata.json";
      description = "The droplet metadata (mode 0600) digitalocean-network.service last configured the network from: this boot's, or the last one saved if the metadata service didn't answer.";
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

    disko.devices = (import ./digitalocean-layout.nix cfg.disk).disko.devices;
    boot.loader.grub.enable = true;
    boot.growPartition = true;
    fileSystems."/".autoResize = true;

    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks = {
      "10-digitalocean-public" = {
        matchConfig.Name = cfg.interfaces.public;
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "ipv4";
          IPv6AcceptRA = false;
        };
      };
      "10-digitalocean-private" = {
        matchConfig.Name = cfg.interfaces.private;
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig.RequiredForOnline = "no";
      };
    };

    systemd.services.digitalocean-network = {
      description = "Configure the droplet's network from its metadata";
      wantedBy = [
        "multi-user.target"
        "network-online.target"
      ];
      before = [ "network-online.target" ];
      after = [ "systemd-networkd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe network;
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
  };
}
