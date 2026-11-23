# sops-nix (sops-nix.nixosModules.sops, imported by nixosModules.secrets),
# decrypting with the server's SSH ed25519 host key as its age identity, so
# the secrets file is encrypted to that key and to the admins' keys.
#
#   ethpandaops.secrets.file = ./secrets.yaml;
#   sops.secrets.tailscale-authkey = { };
{ config, lib, ... }:
let
  cfg = config.ethpandaops.secrets;
in
{
  options.ethpandaops.secrets.file = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "The host's sops file, used for every sops.secrets entry by default.";
  };

  config = {
    sops.defaultSopsFile = lib.mkIf (cfg.file != null) cfg.file;
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # Don't also import the RSA host key as a GPG identity.
    sops.gnupg.sshKeyPaths = [ ];
  };
}
