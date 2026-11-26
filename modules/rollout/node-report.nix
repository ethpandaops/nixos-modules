# The host writes its NixOS state onto its own Kubernetes Node, so a
# rollout reads every host's state with one read-only call. Every minute,
# when a value changed or every 10 minutes, it sets these annotations
# (nixos.ethpandaops.io/<key>) with `kubectl annotate node`, as the
# kubelet (ethpandaops.kubernetes): annotating its own Node is the only
# write.
#
#   revision          the running system's configuration revision, or unknown
#   boot-revision     that of the bootloader's default
#   reboot-required   true or false (true while held too), from reboot-detect
#   reboot-held       why the reboot is held (trial-reverted, trial-not-armed), or empty
#   health            ok, failed or unknown: the checks' status
#                     (/run/nixhost/checks/status.json)
#   readiness         ok, pending, failed or unknown, from the same
#   readiness-failing the readiness checks failing, comma-separated
#   rollbacks         deploy rollbacks plus trial reverts
#   rollback-breaker  open or closed: whether automatic rollbacks are off
#   boot-id           this boot's ID, which the kubelet reports too
#   kernel            the running kernel (uname -r), which the kubelet reports too
#   trial             this boot's trial (none, pending, confirmed, reverted, held)
#   boot-check        this boot's boot check (none, pending, ok, failed)
#   reported-at       when it last wrote, UTC (2026-11-25T10:00:00Z)
#
# On when ethpandaops.kubernetes.kubeconfig and nodeName are set.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  k8s = config.ethpandaops.kubernetes;

  report = pkgs.writeShellApplication {
    name = "nixhost-node-report";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      jq
      systemd
      k8s.package
    ];
    text = ''
      KUBECONFIG_FILE=${lib.escapeShellArg k8s.kubeconfig}
      NODE=${lib.escapeShellArg k8s.nodeName}
      ${config.ethpandaops.lib.shell}
      ${config.ethpandaops.lib.bootDefault}
      ${builtins.readFile ./node-report.sh}
    '';
  };
in
{
  imports = [
    ../checks
    ../metrics.nix
  ];

  config = lib.mkIf (k8s.kubeconfig != null && k8s.nodeName != null) {
    systemd.services.nixhost-node-report = {
      description = "Report this host's NixOS state on its Kubernetes Node";
      startLimitIntervalSec = 0;
      after = [
        "nixhost-checks.service"
        "nixhost-reboot-detect.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe report;
      };
    };
    systemd.timers.nixhost-node-report = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        AccuracySec = "5s";
      };
    };
  };
}
