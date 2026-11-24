# The node-exporter textfile directory every nixhost_* metric is written to,
# and the shell helpers the modules' scripts share.
{ config, lib, ... }:
let
  # Where the bootloader's default entry names its system. GRUB's first entry
  # (default 0) and systemd-boot's default are the system the last
  # switch-to-configuration switch or boot installed, whichever profile it
  # came from; comin switches with its own profile
  # (/nix/var/nix/profiles/system-profiles/comin), so
  # /nix/var/nix/profiles/system is no guide.
  grub = config.boot.loader.grub;
  initSystem = "awk 'match($0, /init=\\/nix\\/store\\/[^ ]*\\/init/) { print substr($0, RSTART + 5, RLENGTH - 10); exit }'";
  bootDefault =
    if config.boot.loader.systemd-boot.enable then
      "bootctl list --json=short | jq -r 'first(.[] | select(.isDefault)) | .options // empty' | ${initSystem}"
    else if
      grub.enable
      && toString grub.default == "0"
      && !grub.extraEntriesBeforeNixOS
      && grub.mirroredBoots != [ ]
    then
      "${initSystem} <${lib.escapeShellArg "${(lib.head grub.mirroredBoots).path}/grub/grub.cfg"}"
    else
      "true";
in
{
  options.ethpandaops.metrics.textfileDir = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/node-exporter";
    description = "Where scripts write *.prom files for node-exporter's textfile collector.";
  };

  options.ethpandaops.lib.shell = lib.mkOption {
    type = lib.types.lines;
    internal = true;
    readOnly = true;
    default = ''
      METRICS_DIR=${lib.escapeShellArg config.ethpandaops.metrics.textfileDir}

      # write_metrics <name>: replace $METRICS_DIR/<name>.prom with stdin atomically.
      write_metrics() {
        local tmp
        mkdir -p "$METRICS_DIR"
        tmp=$(mktemp "$METRICS_DIR/.$1.XXXXXX")
        cat >"$tmp"
        chmod 0644 "$tmp"
        mv -f "$tmp" "$METRICS_DIR/$1.prom"
      }
    '';
  };

  options.ethpandaops.lib.bootDefault = lib.mkOption {
    type = lib.types.lines;
    internal = true;
    readOnly = true;
    description = "A boot_default shell function, for scripts with gawk, jq and systemd on their PATH.";
    default = ''
      # boot_default: the system the bootloader's default entry boots (its
      # init=/nix/store/<system>/init), or nothing if that can't be read.
      boot_default() {
        ${bootDefault}
      }
    '';
  };

  config.systemd.tmpfiles.rules = [ "d ${config.ethpandaops.metrics.textfileDir} 0755 root root -" ];
}
