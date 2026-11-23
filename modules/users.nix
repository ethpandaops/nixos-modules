# People who log in.
#
#   ethpandaops.users.someone = {
#     uid = 1001;
#     keyFiles = [ ./keys/someone.keys ];
#     sudo = true;
#     expires = "2027-06-30";
#     comment = "Why this account exists";
#   };
{
  config,
  lib,
  ...
}:
let
  cfg = config.ethpandaops.users;
  target = import ./notify-target.nix { inherit lib; };
in
{
  options.ethpandaops.users = lib.mkOption {
    default = { };
    description = "Login accounts. Each becomes users.users.<name> in group ssh-users, the only group sshd accepts.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          uid = lib.mkOption {
            type = lib.types.ints.between 1000 59999;
            description = "Fixed UID, so file ownership survives a reinstall.";
          };
          keys = lib.mkOption {
            type = lib.types.listOf lib.types.singleLineStr;
            default = [ ];
            description = "SSH public keys.";
          };
          keyFiles = lib.mkOption {
            type = lib.types.listOf lib.types.path;
            default = [ ];
            description = "Files of SSH public keys.";
          };
          sudo = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Add the account to wheel: passwordless sudo, which is root.";
          };
          expires = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[0-9]{4}-[0-9]{2}-[0-9]{2}");
            default = null;
            description = "Date (YYYY-MM-DD, UTC) from which the account can no longer log in.";
          };
          comment = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Who this is and why they have an account.";
          };
          notify = lib.mkOption {
            type = lib.types.listOf target;
            default = [ ];
            description = "Where this person's notices (such as pending reboots) go. Empty means login message, prompt and wall only.";
          };
          extraGroups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      }
    );
  };

  config = {
    users.users = lib.mapAttrs (_: user: {
      isNormalUser = true;
      inherit (user) uid expires;
      description = user.comment;
      extraGroups = [ "ssh-users" ] ++ lib.optional user.sudo "wheel" ++ user.extraGroups;
      openssh.authorizedKeys = {
        inherit (user) keys keyFiles;
      };
    }) cfg;

    # userborn (which srvos turns on) ignores users.users.<name>.expires, so
    # use the NixOS user activation script, which writes the expiry date to
    # /etc/shadow where sshd and PAM enforce it.
    services.userborn.enable = false;

    assertions = lib.mapAttrsToList (name: user: {
      assertion = user.keys != [ ] || user.keyFiles != [ ];
      message = "ethpandaops.users.${name} has no SSH keys.";
    }) cfg;
  };
}
