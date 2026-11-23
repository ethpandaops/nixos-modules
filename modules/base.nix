# What every server gets on top of srvos's server profile
# (srvos.nixosModules.server, imported by nixosModules.base). srvos already
# sets immutable users, passwordless sudo for wheel only (execWheelOnly),
# key-only SSH reading keys only from /etc/ssh/authorized_keys.d, flakes, the
# firewall, UTC and pinned GitHub host keys. This adds the rest.
#
# srvos also makes @wheel a trusted Nix user. That is kept: wheel is root
# through sudo anyway, and it lets an admin use `nixos-rebuild --target-host`
# as a break-glass deploy.
{ lib, ... }:
{
  services.openssh = {
    authorizedKeysInHomedir = false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Only accounts from ethpandaops.users are in this group.
      AllowGroups = [ "ssh-users" ];
    };
  };
  users.groups.ssh-users = { };

  security.sudo = {
    execWheelOnly = true;
    wheelNeedsPassword = false;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = lib.mkDefault "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  boot.loader.grub.configurationLimit = 10;
  boot.loader.systemd-boot.configurationLimit = 10;

  services.journald.storage = "persistent";
  services.journald.extraConfig = lib.mkDefault ''
    SystemMaxUse=2G
  '';

  # srvos enables the firewall; openssh opens 22. Everything else stays closed
  # unless a host opens it, and monitoring opens its ports on tailscale0 only.
  networking.firewall.enable = true;
}
