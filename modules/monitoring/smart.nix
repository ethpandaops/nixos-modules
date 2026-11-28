# Drives' SMART health, on bare metal: smartd watches every drive and tells
# the admins (nixhost-notify) when one starts failing, and nixhost-smart
# writes the state of the same drives (smartctl --scan, the scan smartd's
# DEVICESCAN uses) as textfile metrics every 10 minutes:
# - nixhost_smart_read_ok{device,type,serial,model}: 0 when smartctl couldn't
#   open or read the drive, or it hung for a minute. A device without SMART
#   (a RAID controller's logical drive, an iSCSI disk) has no series.
# - nixhost_smart_healthy: 1 while the overall SMART health passes.
# - nixhost_smart_accepted: 1 for a drive in smart.acceptedSerials.
# - NVMe: nixhost_smart_nvme_critical_warning, _percentage_used,
#   _available_spare_percent, _available_spare_threshold_percent,
#   _media_errors_total. ATA: nixhost_smart_ata_reallocated_sectors,
#   _pending_sectors, _offline_uncorrectable.
# - nixhost_smart_temperature_celsius, nixhost_smart_power_on_seconds_total.
#
# smartd sends a notice when a problem appears, then reminders 1, 2, 4, 8
# and 16 days apart while it lasts, then every 32 days (-M diminishing; with
# saved state its default would be daily). The state lives in
# /var/lib/smartd, so a restart doesn't repeat a notice.
# Neither runs in a virtual machine or a container (ConditionVirtualization):
# their disks have no SMART, and smartd fails when it finds no drive to watch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.monitoring.smart;

  settings = pkgs.writeText "nixhost-smart.json" (builtins.toJSON { inherit (cfg) acceptedSerials; });

  # smartd's -M exec: one notice a problem, critical unless the drive is
  # accepted. smartd sets SMARTD_DEVICEINFO ("<model>, S/N:<serial>, ..."
  # for ATA and NVMe, "[<vendor> <product> <rev>], S/N: <serial>, ..." for
  # SCSI).
  notify = pkgs.writeShellApplication {
    name = "nixhost-smartd-notify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.jq
    ];
    text = ''
      serial=$(sed -n 's/.*S\/N: *\([^,]*\).*/\1/p' <<<"''${SMARTD_DEVICEINFO:-}")
      severity=critical
      title="Drive problem: ''${SMARTD_FAILTYPE:-unknown}"
      if [ -n "$serial" ] && jq -e --arg s "$serial" 'any(.acceptedSerials[]; . == $s)' ${settings} >/dev/null; then
        severity=info
        title="$title (an accepted drive)"
      fi
      details="''${SMARTD_DEVICESTRING:-?}: ''${SMARTD_DEVICEINFO:-}"$'\n```\n'"''${SMARTD_FULLMESSAGE:-''${SMARTD_MESSAGE:-}}"$'\n```'
      exec ${lib.getExe config.ethpandaops.notify.package} --severity "$severity" --title "$title" admins "$details"
    '';
  };

  script = pkgs.writeShellApplication {
    name = "nixhost-smart";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.smartmontools
    ];
    text = ''
      SETTINGS=${settings}
      METRICS_JQ=${./smart.jq}
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./smart.sh}
    '';
  };
in
{
  imports = [
    ../metrics.nix
    ../notify.nix
  ];

  options.ethpandaops.monitoring.smart = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Watch the drives' SMART health, on bare metal: smartd notices to the admins, and textfile metrics.";
    };
    acceptedSerials = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "SERIAL0123" ];
      description = "Serials of drives kept on purpose although failing: their smartd notices are info rather than critical, and nixhost_smart_accepted is 1.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.smartd = {
      enable = true;
      autodetect = true;
      # Notices go through nixhost-notify alone.
      notifications.wall.enable = false;
      defaults.autodetected = "-a -m <nomailer> -M exec ${lib.getExe notify} -M diminishing";
      extraOptions = [
        "-s"
        "/var/lib/smartd/"
      ];
    };
    systemd.services.smartd = {
      unitConfig.ConditionVirtualization = "no";
      serviceConfig.StateDirectory = "smartd";
    };

    systemd.services.nixhost-smart = {
      description = "Write the drives' SMART state as metrics";
      startLimitIntervalSec = 0;
      unitConfig.ConditionVirtualization = "no";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe script;
      };
    };
    systemd.timers.nixhost-smart = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
      };
    };
  };
}
