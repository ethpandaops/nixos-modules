# Named, typed checks (ethpandaops.checks.<name>), each its own executable:
# exit 0 passes, and the first line of its output is its message.
#
# - health checks decide deploys and boots: the deploy health check retries
#   them for their timeout and rolls back if one still fails, and
#   nixhost-boot-check decides a trial boot by them. The deploy module
#   defines the built-in ones from ethpandaops.deploy.healthCheck (sshd,
#   default-route, firewall, dns, git-remote, extra); a fleet adds its own,
#   and may disable or override those. An outside check depends on things
#   outside the box: when only outside checks fail, the deployed system
#   gets a second try before a rollback is kept, and on a trial boot they
#   keep being retried until near the trial's deadline.
# - readiness checks say whether the box is doing its job again after a
#   deploy or a boot, such as its pods being Ready, for a rollout to wait
#   for, and halt it when they fail. They never roll anything back. The
#   Kubernetes checks are readiness checks unless they set kind.
#
# Each check is one of: unit (a systemd unit is active), http (a URL
# answers 2xx), k8sNode (this host's Node is Ready), k8sPod (enough pods on
# this host matching a selector are Ready) or script (bash; exit 0 passes).
# The Kubernetes checks read with this node's own kubelet credentials
# (ethpandaops.kubernetes), and only ever get or list.
#
# Every deploy and boot check, and nixhost-checks.service every minute (all
# checks, once, no retry, no rollback), write /run/nixhost/checks/status.json:
# revision, system, phase (deploy, boot or periodic), updatedAt, since (the
# later of the boot and the deploy of the running system), checks.<name>
# (kind, outside, ok, since: when its result last changed, message,
# timeout), health (ok or failed) and readiness (ok, every readiness check
# passes; failed, one fails past since + its timeout; pending otherwise).
# Metrics, in nixhost_checks.prom: nixhost_check_ok{check,kind},
# nixhost_checks_health_ok and nixhost_checks_readiness{verdict}.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  k8s = config.ethpandaops.kubernetes;
  enabled = lib.filterAttrs (_: c: c.enable) config.ethpandaops.checks;
  kinds = [
    "unit"
    "http"
    "k8sNode"
    "k8sPod"
    "script"
  ];
  typesOf = c: lib.filter (t: c.${t} != null) kinds;
  isK8s = c: c.k8sNode != null || c.k8sPod != null;
  arg = lib.escapeShellArg;

  kubectl = "kubectl --kubeconfig ${arg k8s.kubeconfig} --request-timeout=10s --cache-dir=/run/nixhost/kubectl-cache";
  # kubectl's stderr goes to $err, for the message.
  kubePrelude = ''
    node=${arg k8s.nodeName}
    err=$(mktemp)
    trap 'rm -f "$err"' EXIT
  '';

  check =
    c:
    if c.unit != null then
      {
        runtimeInputs = [ pkgs.systemd ];
        text = ''
          unit=${arg c.unit}
          state=$(systemctl is-active "$unit" || true)
          if [ "$state" != active ]; then
            echo "$unit is ''${state:-unknown}"
            exit 1
          fi
          echo "$unit is active"
        '';
      }
    else if c.http != null then
      {
        runtimeInputs = [ pkgs.curl ];
        text = ''
          url=${arg c.http}
          out=$(curl --silent --output /dev/null --max-time 10 --write-out '%{http_code} %{errormsg}' "$url" || true)
          code=''${out%% *}
          case $code in
          2??) echo "$url answered $code" ;;
          000 | "")
            echo "$url doesn't answer: ''${out#* }"
            exit 1
            ;;
          *)
            echo "$url answered $code"
            exit 1
            ;;
          esac
        '';
      }
    else if c.k8sNode != null then
      {
        runtimeInputs = [
          pkgs.coreutils
          k8s.package
        ];
        text = ''
          ${kubePrelude}
          if ! ready=$(${kubectl} get node "$node" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>"$err"); then
            echo "can't read Node $node: $(head -n1 "$err")"
            exit 1
          fi
          if [ "$ready" != True ]; then
            echo "Node $node isn't Ready (''${ready:-no Ready condition})"
            exit 1
          fi
          echo "Node $node is Ready"
        '';
      }
    else if c.k8sPod != null then
      {
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          k8s.package
        ];
        text = ''
          ${kubePrelude}
          namespace=${arg c.k8sPod.namespace}
          selector=${arg c.k8sPod.selector}
          min=${toString c.k8sPod.min}
          if ! pods=$(${kubectl} get pods --namespace "$namespace" --selector "$selector" \
            --field-selector "spec.nodeName=$node" --output json 2>"$err"); then
            echo "can't list the pods $selector in $namespace: $(head -n1 "$err")"
            exit 1
          fi
          read -r ready total < <(jq -r '[.items[] | any(.status.conditions[]?; .type == "Ready" and .status == "True")]
            | "\(map(select(.)) | length) \(length)"' <<<"$pods")
          message="$ready of $total pods $selector in $namespace on $node are Ready"
          if [ "$ready" -lt "$min" ]; then
            echo "$message; $min needed"
            exit 1
          fi
          echo "$message"
        '';
      }
    else
      {
        # What a fleet's script can count on, wherever it runs.
        runtimeInputs = with pkgs; [
          coreutils
          gawk
          getent
          gnugrep
          gnused
          iproute2
          jq
          systemd
          util-linux
        ];
        text = toString c.script;
      };

  package =
    name: c:
    pkgs.writeShellApplication (
      {
        name = "nixhost-check-${name}";
      }
      // check c
    );

  list = pkgs.writeText "nixhost-checks.json" (
    builtins.toJSON {
      checks = lib.mapAttrsToList (name: c: {
        inherit name;
        inherit (c) kind outside timeout;
        command = lib.getExe (package name c);
      }) enabled;
    }
  );

  periodic = pkgs.writeShellApplication {
    name = "nixhost-checks";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      jq
      util-linux
    ];
    text = ''
      ${config.ethpandaops.lib.shell}
      ${config.ethpandaops.lib.checks}
      if ! run_checks health readiness; then
        echo "failing:$failures"
      fi
      write_status periodic
      jq -r '"health \(.health), readiness \(.readiness)"' "$CHECKS_STATUS"
    '';
  };

  checkType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run this check.";
        };
        kind = lib.mkOption {
          type = lib.types.enum [
            "health"
            "readiness"
          ];
          default = if config.k8sNode != null || config.k8sPod != null then "readiness" else "health";
          defaultText = lib.literalMD ''`"readiness"` for k8sNode and k8sPod checks, `"health"` for the others'';
          description = ''
            health: the deploy and boot checks retry it for its timeout, and
            a deploy that still fails it is rolled back, a trial boot
            reverted. readiness: whether the box does its job again after a
            deploy or a boot, for a rollout to wait for (it halts on a failed
            one); never rolls back. Kubernetes checks are readiness by
            default, since a rollback under k3s could leave a node worse off.
          '';
        };
        timeout = lib.mkOption {
          type = lib.types.ints.positive;
          default = if config.kind == "health" then healthTimeout else 1800;
          defaultText = lib.literalExpression ''
            if kind == "health" then config.ethpandaops.deploy.healthCheck.timeout else 1800
          '';
          description = ''
            Seconds it may fail: a health check, from the start of a deploy
            or boot check, before the check gives up; a readiness check, from
            the boot or the deploy of the running system, before readiness
            is failed rather than pending. Each run is cut off after 60 s.
          '';
        };
        outside = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            It depends on things outside the box, such as DNS or a remote:
            failing alone, it gives the deployed system a second try before a
            rollback is kept, and on a trial boot it keeps being retried until
            near the deadline. Health checks only.
          '';
        };
        unit = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "k3s.service";
          description = "Passes while this systemd unit is active.";
        };
        http = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "http://127.0.0.1:10248/healthz";
          description = "Passes when this URL answers 2xx within 10 s (redirects aren't followed).";
        };
        k8sNode = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule { });
          default = null;
          example = { };
          description = "`{ }`: passes when this host's Node (ethpandaops.kubernetes.nodeName) has condition Ready=True.";
        };
        k8sPod = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                namespace = lib.mkOption {
                  type = lib.types.str;
                  description = "The pods' namespace.";
                };
                selector = lib.mkOption {
                  type = lib.types.str;
                  example = "app.kubernetes.io/name=beacon";
                  description = "A label selector.";
                };
                min = lib.mkOption {
                  type = lib.types.ints.positive;
                  default = 1;
                  description = "How many of them must be Ready.";
                };
              };
            }
          );
          default = null;
          description = "Passes when at least `min` pods on this host matching `selector` in `namespace` have condition Ready=True.";
        };
        script = lib.mkOption {
          type = lib.types.nullOr lib.types.lines;
          default = null;
          description = ''
            Bash, shellchecked and run with errexit, nounset and pipefail;
            exit 0 passes, and the first line it prints is its message.
          '';
        };
      };
    }
  );
  healthTimeout = config.ethpandaops.deploy.healthCheck.timeout or 180;
in
{
  imports = [ ../metrics.nix ];

  options.ethpandaops.checks = lib.mkOption {
    type = lib.types.attrsOf checkType;
    default = { };
    example = lib.literalExpression ''
      {
        kubelet.http = "http://127.0.0.1:10248/healthz";
        node.k8sNode = { };
        beacon = {
          kind = "readiness";
          k8sPod = { namespace = "ethereum"; selector = "app=beacon"; };
        };
      }
    '';
    description = "Named checks, each with exactly one of unit, http, k8sNode, k8sPod and script. Names may have letters, digits, `.`, `_` and `-`.";
  };

  options.ethpandaops.kubernetes = {
    kubeconfig = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/rancher/k3s/agent/kubelet.kubeconfig";
      description = ''
        This node's own kubelet kubeconfig, for the k8sNode and k8sPod checks
        (which only get and list) and the Node reporter (which annotates
        this host's own Node).
      '';
    };
    nodeName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "This host's Kubernetes Node.";
    };
    package = lib.mkPackageOption pkgs "kubectl" {
      extraDescription = "Any package with bin/kubectl, such as k3s.";
    };
  };

  options.ethpandaops.lib.checks = lib.mkOption {
    type = lib.types.lines;
    internal = true;
    readOnly = true;
    description = ''
      run_checks and write_status (checks.sh) with the enabled checks, for
      scripts that have ethpandaops.lib.shell, and coreutils, gawk, jq and
      util-linux on their PATH.
    '';
    default = ''
      CHECKS=${list}
      ${builtins.readFile ./checks.sh}
    '';
  };

  config = {
    assertions =
      lib.concatLists (
        lib.mapAttrsToList (name: c: [
          {
            assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null;
            message = "ethpandaops.checks.\"${name}\": a check's name may only have letters, digits, '.', '_' and '-'.";
          }
          {
            assertion = lib.length (typesOf c) == 1;
            message = "ethpandaops.checks.${name}: set exactly one of ${lib.concatStringsSep ", " kinds}; it has ${
              if typesOf c == [ ] then "none" else lib.concatStringsSep " and " (typesOf c)
            }.";
          }
          {
            assertion = !(c.outside && c.kind == "readiness");
            message = "ethpandaops.checks.${name}: only health checks can be outside.";
          }
        ]) enabled
      )
      ++ [
        {
          assertion =
            !lib.any isK8s (lib.attrValues enabled) || (k8s.kubeconfig != null && k8s.nodeName != null);
          message = "ethpandaops.checks: the k8sNode and k8sPod checks need ethpandaops.kubernetes.kubeconfig and nodeName.";
        }
      ];

    systemd.services.nixhost-checks = lib.mkIf (enabled != { }) {
      description = "Run every named check once and record their status";
      startLimitIntervalSec = 0;
      # A deploy or boot check that's running records the status itself.
      after = [
        "nixhost-health-check.service"
        "nixhost-boot-check.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe periodic;
      };
    };
    systemd.timers.nixhost-checks = lib.mkIf (enabled != { }) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
        AccuracySec = "5s";
      };
    };

    environment.systemPackages = lib.mkIf (enabled != { }) [ periodic ];
  };
}
