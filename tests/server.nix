# A complete server using every module, with placeholder values, so the
# modules are checked together the way a real configuration uses them.
{ config, pkgs, ... }:
{
  networking.hostName = "example";
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  # raid1-disks needs 6.19 or newer.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  ethpandaops = {
    network = {
      mac = "00:00:5e:00:53:00";
      ipv4.address = "192.0.2.10";
      ipv4.gateway = "192.0.2.1";
      ipv6.address = "2001:db8::2/64";
    };
    raid1.disks = [
      "/dev/disk/by-id/disk-a"
      "/dev/disk/by-id/disk-b"
    ];
    deploy.repository = "ssh://git@github.com/example/config.git";
    secrets.file = ./fixtures/secrets.yaml;
    monitoring.tailscale = {
      loginServer = "https://login.example.org";
      authKeyFile = config.sops.secrets.tailscale-authkey.path;
    };
    notify.admins = [
      {
        type = "discord";
        urlFile = config.sops.secrets.admin-webhook.path;
      }
    ];
    users.example = {
      uid = 1001;
      sudo = true;
      keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyNotARealKeyAAAAAAAAAAAAAAAAAAAA" ];
      notify = [
        {
          type = "ntfy";
          url = "https://ntfy.example.org/topic";
        }
      ];
    };
  };
  networking.nameservers = [ "192.0.2.53" ];

  sops.secrets.tailscale-authkey = { };
  sops.secrets.admin-webhook = { };
}
