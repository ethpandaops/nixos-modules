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

  # Hardening beyond the defaults, which already cover most of the usual list:
  # the kernel is built with init_on_alloc, stack offset randomisation, freelist
  # hardening, unprivileged BPF off and dmesg restricted; NixOS sets
  # kptr_restrict and maximum ASLR entropy; systemd sets the protected_*
  # links and files, loose rp_filter and no source routing.

  # No kexec, so root can't swap the running kernel for another without a
  # firmware reboot, and no hibernation. Reinstalling with nixos-anywhere has
  # to start from the rescue system rather than the running one.
  security.protectKernelImage = true;

  # Network protocols nothing here uses, which any process, including a
  # container or a service account, could otherwise have the kernel load by
  # opening a socket: the ones Ubuntu and the CIS benchmarks disable that this
  # kernel builds. A blacklist stops only that autoloading; root can still
  # modprobe them by name.
  boot.blacklistedKernelModules = [
    "sctp"
    "rds"
    "x25"
    "can"
    "atm"
    "ieee802154_socket"
  ];

  boot.kernel.sysctl = {
    # Only CAP_SYS_MODULE loads tty line disciplines, so a container's pty
    # can't pull in n_gsm or n_hdlc, both with privilege escalation bugs.
    "dev.tty.ldisc_autoload" = 0;
    # Ignore ICMP redirects, which a neighbour on the provider's network
    # segment can forge, and send none. The glob also covers interfaces that
    # existed before sysctl ran, such as the uplink; all and default alone
    # don't.
    "net.ipv4.conf.*.accept_redirects" = 0;
    "net.ipv6.conf.*.accept_redirects" = 0;
    "net.ipv4.conf.*.send_redirects" = 0;
  };

  # Only people's accounts (group users) use the Nix daemon, besides root and
  # wheel, which srvos trusts. Service accounts can't, which keeps them away
  # from bugs like the 2025 daemon privilege escalations. Add a service's user
  # here if it needs Nix.
  nix.settings.allowed-users = [ "@users" ];
}
