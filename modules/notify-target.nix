# The option type for one notification target, shared by ethpandaops.notify
# (admins) and ethpandaops.users.<name>.notify.
{ lib }:
lib.types.submodule {
  options = {
    type = lib.mkOption {
      type = lib.types.enum [
        "discord"
        "ntfy"
        "webhook"
      ];
      description = ''
        How to deliver: `discord` posts `{"content": ...}` to a Discord webhook,
        `ntfy` posts the text to an ntfy topic URL, and `webhook` posts
        `{"text": ...}` (Slack-compatible) to any URL.
      '';
    };
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The URL. It ends up in the Nix store, so use urlFile for anything secret.";
    };
    urlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression "config.sops.secrets.admin-webhook.path";
      description = "A root-readable file holding the URL, such as a sops-nix secret.";
    };
  };
}
