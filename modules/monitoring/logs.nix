# The journal shipped off the box over OTLP/HTTP with fluent-bit, so a record
# of what happened on the box outlives the box: every unit's output, sshd and
# sudo, and audit records for changes to accounts, sudo rules, SSH
# configuration and kernel modules and for every command a person runs as
# root. Container output (Docker's journald log driver) stays on the box.
#
# Entries reach the endpoint as OTLP log records: the message as the body,
# the syslog priority as the severity, the unit, identifier, process and audit
# fields as attributes, and host.name as a resource attribute. fluent-bit
# keeps its place in the journal and buffers on disk while the endpoint is
# unreachable. nixhost_logs_up and fluent-bit's own counters
# (fluentbit_output_proc_records_total and others) go to node-exporter.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ethpandaops.monitoring.logs;
  fluentBit = config.services.fluent-bit;

  # scheme, host, port
  url = builtins.match "(https?)://([^:/]+)(:([0-9]+))?/?" cfg.endpoint;
  tls = lib.elemAt url 0 == "https";
  port =
    if lib.elemAt url 3 != null then
      lib.elemAt url 3
    else if tls then
      "443"
    else
      "80";

  # fluent-bit runs as a dynamic user; systemd links this to /var/lib/private.
  stateDir = "/var/lib/fluent-bit";
  metricsPort = 2020;

  metrics = pkgs.writeShellApplication {
    name = "nixhost-logs-metrics";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
    ];
    text = ''
      PORT=${toString metricsPort}
      ${config.ethpandaops.lib.shell}
      ${builtins.readFile ./logs-metrics.sh}
    '';
  };
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.monitoring.logs = {
    enable = lib.mkEnableOption "shipping the journal, with audit records, over OTLP/HTTP";
    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "https://otlp.example.org";
      description = "The OTLP/HTTP endpoint, without a path; logs go to its /v1/logs.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      description = "The endpoint's basic auth user.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression "config.sops.secrets.otlp-password.path";
      description = "A file holding the basic auth password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = url != null;
        message = "ethpandaops.monitoring.logs.endpoint must look like https://host[:port], not ${cfg.endpoint}.";
      }
    ];

    services.fluent-bit = {
      enable = true;
      graceLimit = 30;
      settings = {
        service = {
          flush = 5;
          grace = 20;
          http_server = "on";
          http_listen = "127.0.0.1";
          http_port = metricsPort;
          "storage.path" = "${stateDir}/storage";
          "storage.sync" = "normal";
        };
        pipeline = {
          inputs = [
            {
              name = "systemd";
              tag = "journal";
              # Where it got to in the journal; on first start, it begins now.
              db = "${stateDir}/journal.db";
              read_from_tail = "on";
              "storage.type" = "filesystem";
              processors.logs = [
                {
                  name = "lua";
                  script = "${./journal.lua}";
                  call = "journal_to_otlp";
                  type_int_key = "severity_number";
                }
                { name = "opentelemetry_envelope"; }
                {
                  name = "content_modifier";
                  context = "otel_resource_attributes";
                  action = "upsert";
                  key = "host.name";
                  value = config.networking.hostName;
                }
                {
                  name = "content_modifier";
                  context = "otel_resource_attributes";
                  action = "upsert";
                  key = "service.name";
                  value = "journald";
                }
              ];
            }
          ];
          outputs = [
            {
              name = "opentelemetry";
              match = "journal";
              host = lib.elemAt url 1;
              inherit port;
              tls = if tls then "on" else "off";
              "tls.verify" = "on";
              "tls.verify_hostname" = "on";
              http_user = cfg.user;
              # Set from the credential when the service starts.
              http_passwd = "\${OTLP_PASSWORD}";
              logs_body_key = "$body";
              logs_body_key_attributes = "on";
              logs_severity_text_message_key = "severity_text";
              logs_severity_number_message_key = "severity_number";
              compress = "gzip";
              # Keep retrying; the oldest chunks go once the buffer is full.
              retry_limit = "no_limits";
              "storage.total_limit_size" = "512M";
            }
          ];
        };
      };
    };

    systemd.services.fluent-bit = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        StateDirectory = "fluent-bit";
        LoadCredential = "otlp-password:${cfg.passwordFile}";
        ExecStart = lib.mkForce (
          pkgs.writeShellScript "fluent-bit-start" ''
            OTLP_PASSWORD=$(<"$CREDENTIALS_DIRECTORY/otlp-password")
            export OTLP_PASSWORD
            exec ${lib.getExe fluentBit.package} --config ${fluentBit.configurationFile}
          ''
        );
      };
    };

    # auditd takes the kernel's audit records; journald gets a copy (its
    # audit socket is always on), and fluent-bit ships it.
    security.auditd.enable = true;
    security.audit = {
      enable = true;
      rules = [
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/group -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        "-w /etc/sudoers -p wa -k sudoers"
        "-w /etc/sudoers.d -p wa -k sudoers"
        "-w /etc/ssh -p wa -k ssh"
        "-w /root/.ssh -p wa -k ssh"
        "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules"
        # Commands run as root by a person: after sudo (a login uid of a
        # user), or in a root login. Services have no login uid.
        "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root-exec"
        "-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root-exec"
        "-a always,exit -F arch=b64 -S execve -F auid=0 -k root-exec"
        "-a always,exit -F arch=b32 -S execve -F auid=0 -k root-exec"
      ];
    };

    systemd.services.nixhost-logs-metrics = {
      description = "Export fluent-bit's delivery counters";
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe metrics;
      };
    };
    systemd.timers.nixhost-logs-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
