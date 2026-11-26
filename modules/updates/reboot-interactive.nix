# The reboot policy for a box with an interactive user. When reboot-detect
# says a reboot is needed, this tells people (a panda at each SSH login with
# a terminal, worked out then, a line at the prompt of open shells when it
# changes, the system tmux status line, wall, and each user's notify targets)
# and reboots:
#
# - in the nightly window, once minDelay has passed, when nobody is logged in,
#   no hold is set and nothing holds a `systemd-inhibit --what=shutdown` lock;
# - at the time a user chose with `reboot-at`;
# - or at the deadline (maxDelay after the reboot became pending), after a
#   deadlineWarningMinutes countdown with wall warnings, overriding holds,
#   logins and inhibitors.
#
# A kernel of a new series (7.3 to 7.4) is the exception: it never reboots
# by itself, because if it doesn't boot on this hardware someone with console
# access has to be on hand. The admins hear about it and reboot with
# reboot-at or reboot-now; the deadline only becomes an alert.
#
# A deployed system whose trial boot failed (ethpandaops.reboot.trial) is
# held too: the box went back to the last confirmed system, and another
# reboot wouldn't try it again. It waits for a fix or `nixhost-boot retry`.
#
# Users run reboot-status, reboot-hold <duration>, reboot-at <time> and
# reboot-now. Changing the schedule needs sudo. Admins set critical,
# maxDelay or pauseUntil in the host repo.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.reboot;
  duration = lib.types.strMatching "[0-9]+[smhdw]";
  seconds =
    d:
    let
      m = builtins.match "([0-9]+)([smhdw])" d;
      unit = {
        s = 1;
        m = 60;
        h = 3600;
        d = 86400;
        w = 604800;
      };
    in
    lib.toIntBase10 (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};
  clock = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";
  minutes =
    t:
    let
      m = builtins.match "([0-9]+):([0-9]+)" t;
    in
    lib.toIntBase10 (builtins.elemAt m 0) * 60 + lib.toIntBase10 (builtins.elemAt m 1);

  settings = pkgs.writeText "nixhost-reboot.json" (
    builtins.toJSON {
      windowStart = minutes cfg.window.start;
      windowEnd = minutes cfg.window.end;
      minDelay = seconds cfg.minDelay;
      maxDelay = seconds (if cfg.critical then cfg.criticalMaxDelay else cfg.maxDelay);
      inherit (cfg)
        critical
        pauseUntil
        deadlineWarningMinutes
        holdKernelSeriesChange
        ;
    }
  );

  package = pkgs.writeShellApplication {
    name = "nixhost-reboot";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      systemd
      util-linux # wall
    ];
    text = ''
      SETTINGS=${settings}
      NOTIFY=${lib.getExe config.ethpandaops.notify.package}
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./reboot-policy.sh}
    '';
  };

  command =
    name: subcommand: pkgs.writeShellScriptBin name ''exec ${lib.getExe package} ${subcommand} "$@"'';

  statusLine = "/run/nixhost/reboot/status-line";
in
{
  imports = [
    ../metrics.nix
    ../notify.nix
  ];

  options.ethpandaops.reboot = {
    window = {
      start = lib.mkOption {
        type = clock;
        default = "02:00";
        description = "Start of the nightly reboot window, UTC (HH:MM).";
      };
      end = lib.mkOption {
        type = clock;
        default = "05:00";
        description = "End of the window, UTC. It may be earlier than start to cross midnight.";
      };
    };
    minDelay = lib.mkOption {
      type = duration;
      default = "1d";
      description = "How long a reboot is pending before the first window may use it, so people see the notices first.";
    };
    maxDelay = lib.mkOption {
      type = duration;
      default = "7d";
      description = "The deadline: how long after the reboot became pending the box reboots regardless.";
    };
    critical = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use criticalMaxDelay as the deadline, for an urgent fix. Set it with a commit and unset it after the reboot.";
    };
    criticalMaxDelay = lib.mkOption {
      type = duration;
      default = "24h";
    };
    holdKernelSeriesChange = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Leave a kernel update to a new series (major.minor, such as 7.3 to 7.4)
        to a person: no reboot in the window or at the deadline, and the admins
        are told to run reboot-at or reboot-now while someone with console
        access is on hand. The deadline becomes theirs, an alert rather than a
        reboot. critical lifts it.
      '';
    };
    pauseUntil = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9]{4}-[0-9]{2}-[0-9]{2}");
      default = null;
      description = ''
        No automatic reboot before this date (00:00 UTC). The deadline moves to
        at least that time. It expires by itself, so a forgotten pause can't
        stop reboots for good.
      '';
    };
    deadlineWarningMinutes = lib.mkOption {
      type = lib.types.ints.between 1 720;
      default = 60;
      description = "Countdown, with wall warnings, between reaching the deadline and the reboot.";
    };
    tmuxStatus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Show the pending-reboot line in the system tmux status bar (/etc/tmux.conf).";
    };
  };

  config = {
    assertions = [
      {
        assertion =
          config.systemd.services.nixhost-reboot-policy.enable
          && config.systemd.timers.nixhost-reboot-policy.enable;
        message = "Don't disable the reboot policy; set ethpandaops.reboot.pauseUntil to a date instead.";
      }
      {
        assertion = seconds cfg.minDelay < seconds cfg.maxDelay;
        message = "ethpandaops.reboot.minDelay must be shorter than maxDelay.";
      }
    ];

    environment.systemPackages = [
      package
      (command "reboot-status" "status")
      (command "reboot-hold" "hold")
      (command "reboot-at" "at")
      (command "reboot-now" "now")
    ];

    systemd.tmpfiles.rules = [ "d /var/lib/nixhost-reboot 0700 root root -" ];

    systemd.services.nixhost-reboot-policy = {
      # Started on demand (by deploys and the reboot-* commands), so never rate-limit it.
      startLimitIntervalSec = 0;
      description = "Notify about and schedule a pending reboot";
      after = [ "nixhost-reboot-detect.service" ];
      requires = [ "nixhost-reboot-detect.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe package} policy";
      };
    };
    systemd.timers.nixhost-reboot-policy = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnCalendar = "*:0/15";
      };
    };

    # The login message, worked out from the state at login (nothing while no
    # reboot is pending). sshd passes on what PAM says when a session opens
    # only to sessions with a terminal, so scp, sftp, rsync, git and
    # `ssh host cmd` get nothing.
    security.pam.services.sshd.rules.session.nixhost-reboot = {
      # Where pam_motd goes: after pam_systemd has registered the session.
      order = config.security.pam.services.sshd.rules.session.motd.order + 1;
      control = "optional";
      modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
      args = [
        "type=open_session"
        "stdout"
        "quiet"
        # It takes well under a second; this only stops a hang blocking logins.
        "${pkgs.coreutils}/bin/timeout"
        "10"
        (lib.getExe package)
        "login"
      ];
    };

    # Already-open shells, including tmux and screen panes, print the status
    # line at their next prompt whenever it changes. A new shell starts from
    # the current line: a login has just shown it.
    programs.bash.interactiveShellInit = ''
      __nixhost_reboot_last=""
      [ -r ${statusLine} ] && __nixhost_reboot_last=$(<${statusLine})
      __nixhost_reboot_notice() {
        local line=""
        [ -r ${statusLine} ] && line=$(<${statusLine})
        if [ -n "$line" ] && [ "$line" != "$__nixhost_reboot_last" ]; then
          printf '\n*** %s\n' "$line" >&2
        fi
        __nixhost_reboot_last=$line
      }
      PROMPT_COMMAND+=(__nixhost_reboot_notice)
    '';
    programs.zsh.interactiveShellInit = ''
      __nixhost_reboot_last=""
      [ -r ${statusLine} ] && __nixhost_reboot_last=$(<${statusLine})
      __nixhost_reboot_notice() {
        local line=""
        [ -r ${statusLine} ] && line=$(<${statusLine})
        if [ -n "$line" ] && [ "$line" != "$__nixhost_reboot_last" ]; then
          printf '\n*** %s\n' "$line" >&2
        fi
        __nixhost_reboot_last=$line
      }
      precmd_functions+=(__nixhost_reboot_notice)
    '';

    programs.tmux = lib.mkIf cfg.tmuxStatus {
      enable = true;
      extraConfig = ''
        set -g status-right-length 120
        set -ag status-right "#(cat ${statusLine} 2>/dev/null)"
      '';
    };
  };
}
