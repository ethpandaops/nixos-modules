# The node-exporter textfile directory every nixhost_* metric is written to,
# and the shell helpers the modules' scripts share.
{ config, lib, ... }:
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

  config.systemd.tmpfiles.rules = [ "d ${config.ethpandaops.metrics.textfileDir} 0755 root root -" ];
}
