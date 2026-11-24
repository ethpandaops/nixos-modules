# Kernel tampering, as textfile metrics (nixhost-kernel, every minute):
# - nixhost_kernel_protection{check}: each protection the configuration turns
#   on, 1 while in force: kernel module loading off (lockKernelModules), kexec
#   off (protectKernelImage), the kernel command line's nohibernate and
#   audit=1, the audit system enabled, and the NixOS firewall's rules loaded
#   (a failed firewall reload takes them out). A command-line protection that the
#   booted system didn't have yet is nixhost_kernel_protection_pending until
#   the reboot.
# - nixhost_audit_rules_changed{,_info}: audit rules added or deleted since
#   audit-rules-nixos loaded them, nixhost_audit_lost and nixhost_audit_backlog:
#   how someone would hide what the audit rules record.
# - nixhost_bpf_loads_total{loader,known}: BPF programs loaded, from the audit
#   rule with key bpf (monitoring.logs). systemd (PID 1), the programs in
#   bpf.knownLoaders and the executables in bpf.knownExecutables are known
#   loaders; any other load is worth a look.
# - nixhost_kernel_module_late_loads_total{module}: modules loaded after boot,
#   from the audit rule with key modules (monitoring.logs). That's what
#   security.lockKernelModules would refuse, so it's the list to load at boot
#   before turning the lock on (ethpandaops.kernelModules).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.monitoring.kernel;
  auditOn = config.security.audit.enable != false;
  fw = config.networking.firewall;
  nftables = config.networking.nftables.enable;

  checks =
    lib.optional config.security.lockKernelModules {
      check = "modules_disabled";
      kind = "sysctl";
      arg = "kernel/modules_disabled";
      want = "1";
    }
    ++ lib.optionals config.security.protectKernelImage [
      {
        check = "kexec_load_disabled";
        kind = "sysctl";
        arg = "kernel/kexec_load_disabled";
        want = "1";
      }
      {
        check = "cmdline:nohibernate";
        kind = "cmdline";
        arg = "nohibernate";
      }
    ]
    ++ lib.optional fw.enable {
      check = "firewall";
      kind = "firewall";
      # The commands whose rules jump to nixos-fw, or nftables.
      arg =
        if nftables then
          "nftables"
        else
          lib.concatStringsSep " " ([ "iptables" ] ++ lib.optional config.networking.enableIPv6 "ip6tables");
    }
    ++ lib.optionals auditOn [
      {
        check = "cmdline:audit=1";
        kind = "cmdline";
        arg = "audit=1";
      }
      {
        check = "audit_enabled";
        kind = "audit";
        want = if config.security.audit.enable == "lock" then "2" else "1";
      }
    ];

  settings = pkgs.writeText "nixhost-kernel.json" (
    builtins.toJSON {
      inherit checks;
      audit = auditOn;
      inherit (cfg.bpf) knownLoaders knownExecutables;
    }
  );

  script = pkgs.writeShellApplication {
    name = "nixhost-kernel";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.jq
      pkgs.systemd
    ]
    ++ lib.optional auditOn config.security.audit.package
    ++ lib.optional fw.enable (if nftables then pkgs.nftables else fw.package);
    text = ''
      SETTINGS=${settings}
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./drift-common.sh}
      ${builtins.readFile ./kernel.sh}
    '';
  };
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.monitoring.kernel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Report kernel protections, the audit system and BPF program loads as textfile metrics.";
    };
    bpf.knownLoaders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optionals config.virtualisation.docker.enable [
        "runc"
        "dockerd"
        "containerd"
      ];
      defaultText = lib.literalExpression ''lib.optionals config.virtualisation.docker.enable [ "runc" "dockerd" "containerd" ]'';
      example = [ "tailscaled" ];
      description = ''
        Programs whose BPF loads are expected, by executable name without
        NixOS's wrapper (.<name>-wrapped), for executables in the Nix store.
        systemd (PID 1) is always known: it loads programs for units' IP
        filters and device and filesystem restrictions. runc loads cgroup
        device filters for every container.
      '';
    };
    bpf.knownExecutables = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/usr/bin/falco" ];
      description = ''
        Executables whose BPF loads are expected, by exact path as the audit
        record shows it, for loaders outside the Nix store. Inside a container
        that is the path in its image, such as /usr/bin/falco. Any container
        can put a program at that path, so this quiets an expected loader; it
        doesn't prove which program loaded.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixhost-kernel = {
      description = "Check kernel protections, the audit system and BPF loads";
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe script;
        StateDirectory = "nixhost-kernel";
        StateDirectoryMode = "0700";
      };
    };
    systemd.timers.nixhost-kernel = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
