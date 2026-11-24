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
        How to deliver: `discord` posts an embed to a Discord webhook (a Slack
        attachment to its /slack form), `ntfy` posts the text with a title and
        priority to an ntfy topic URL, and `webhook` posts a Slack-compatible
        attachment to any URL. Each posts under the host's name.
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
