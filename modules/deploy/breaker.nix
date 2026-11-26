# The rollback breaker: automatic rollbacks (the deploy health check's) and
# trial reverts (ethpandaops.reboot.trial's) are allowed only until it trips.
# It trips when a rollback is kept, when a trial reverts, and when a rollback
# would cross the rollback guard (ethpandaops.rollback.guard); while it's
# open the host keeps what it runs, the admins hear, and a person decides.
# A deployed system that passes its health checks, or a confirmed trial,
# closes it, and so does `sudo nixhost-breaker reset`.
#
# State: /var/lib/nixhost-deploy/breaker.json ({open, since, reason,
# system}), kept across reboots. Metrics, in nixhost_breaker.prom:
# nixhost_rollback_breaker_open and nixhost_rollback_breaker_blocked_total
# (rollbacks and reverts it refused).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  command = pkgs.writeShellApplication {
    name = "nixhost-breaker";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      NOTIFY=${lib.getExe config.ethpandaops.notify.package}
      ${config.ethpandaops.lib.shell}
      ${config.ethpandaops.lib.breaker}

      opened() {
        date -d "@$(breaker_get .since)" '+%F %T %Z'
      }

      case "''${1:-status}" in
      status)
        if breaker_open; then
          echo "The rollback breaker is open, since $(opened): $(breaker_get .reason)."
          echo "System: $(breaker_get .system)"
          echo "Nothing rolls back or reverts a trial by itself until a deployed system passes its"
          echo "health checks, a trial is confirmed, or someone runs: sudo nixhost-breaker reset"
        else
          reason=$(breaker_get .reason)
          echo "The rollback breaker is closed''${reason:+ ($reason)}."
        fi
        echo "Rollbacks and reverts it refused: $(breaker_blocked_total)"
        ;;
      reset)
        if [ "$(id -u)" -ne 0 ]; then
          echo "Run it as root: sudo nixhost-breaker reset" >&2
          exit 1
        fi
        if ! breaker_open; then
          echo "The rollback breaker is already closed."
          exit 0
        fi
        was="open since $(opened): $(breaker_get .reason)"
        by=''${SUDO_USER:-root}
        breaker_close "reset by $by"
        "$NOTIFY" --severity info --title "Rollback breaker reset" admins \
          "$by reset the rollback breaker ($was), so automatic rollbacks and trial reverts are back on." || true
        ;;
      *)
        echo "usage: nixhost-breaker status|reset" >&2
        exit 2
        ;;
      esac
    '';
  };
in
{
  imports = [
    ../metrics.nix
    ../notify.nix
  ];

  options.ethpandaops.lib.breaker = lib.mkOption {
    type = lib.types.lines;
    internal = true;
    readOnly = true;
    description = ''
      The rollback breaker's shell helpers (breaker.sh): breaker_open,
      breaker_trip, breaker_close, breaker_blocked and guard_differs, for
      scripts that have ethpandaops.lib.shell, and coreutils and jq on their
      PATH.
    '';
    default = builtins.readFile ./breaker.sh;
  };

  config = lib.mkIf (config.ethpandaops.deploy.enable or false) {
    environment.systemPackages = [ command ];
  };
}
