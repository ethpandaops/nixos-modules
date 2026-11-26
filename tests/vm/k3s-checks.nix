# Kubernetes checks and the Node reporter on a single-node k3s server with
# no network (its one image is preloaded): a k8sNode health check and a
# k8sPod readiness check through the kubelet's own credentials, readiness
# pending until the pod on this node is Ready, and the
# nixos.ethpandaops.io/* annotations on the Node, whose boot-id and kernel
# match what the kubelet reports.
{
  self,
  lib,
  pkgs,
  ...
}:
let
  revision = "89abcdef0123456789abcdef0123456789abcdef";
  image = pkgs.dockerTools.buildLayeredImage {
    name = "test.local/pause";
    tag = "local";
    contents = pkgs.buildEnv {
      name = "nixhost-test-image";
      paths = [
        pkgs.tini
        (lib.hiPrio pkgs.coreutils)
        pkgs.busybox
      ];
    };
    config.Entrypoint = [
      "/bin/tini"
      "--"
      "/bin/sleep"
      "inf"
    ];
  };
  # Pinned to the node, so the scheduler isn't involved.
  pod = pkgs.writeText "pod.yaml" ''
    apiVersion: v1
    kind: Pod
    metadata:
      name: nixhost-test
      namespace: default
      labels:
        app: nixhost-test
    spec:
      nodeName: machine
      containers:
      - name: test
        image: test.local/pause:local
        imagePullPolicy: Never
        command: ["sleep", "inf"]
  '';
in
{
  name = "k3s-checks";

  nodes.machine = {
    imports = [
      self.nixosModules.deploy
      self.nixosModules.reboot-detect
      self.nixosModules.node-report
    ];
    virtualisation = {
      memorySize = 2560;
      diskSize = 4096;
      cores = 2;
    };
    services.k3s = {
      enable = true;
      role = "server";
      disable = [
        "coredns"
        "local-storage"
        "metrics-server"
        "servicelb"
        "traefik"
      ];
      images = [ image ];
      extraFlags = [ "--pause-image test.local/pause:local" ];
    };
    environment.systemPackages = [ pkgs.kubectl ];

    ethpandaops.deploy = {
      # comin isn't run here, nor the network checks.
      repository = "/var/lib/remote.git";
      deployKeyFile = null;
      healthCheck = {
        dnsName = null;
        checkRemote = false;
      };
    };
    services.comin.enable = lib.mkForce false;
    system.configurationRevision = revision;

    ethpandaops.kubernetes = {
      kubeconfig = "/var/lib/rancher/k3s/agent/kubelet.kubeconfig";
      nodeName = "machine";
    };
    ethpandaops.checks = {
      # No sshd in this VM: a fleet turns a built-in check off like this.
      sshd.enable = false;
      # A health check because it says so; Kubernetes checks are readiness
      # checks by default.
      node = {
        kind = "health";
        k8sNode = { };
      };
      node-ready.k8sNode = { };
      pod.k8sPod = {
        namespace = "default";
        selector = "app=nixhost-test";
      };
    };
  };

  testScript = ''
    import json
    import re

    admin = "kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
    prefix = "nixos.ethpandaops.io/"

    def sh(command):
        return machine.succeed(command).strip()

    def status():
        return json.loads(sh("cat /run/nixhost/checks/status.json"))

    def node():
        return json.loads(sh(f"{admin} get node machine -o json"))

    def annotations():
        a = node()["metadata"].get("annotations") or {}
        return {k.removeprefix(prefix): v for k, v in a.items() if k.startswith(prefix)}

    machine.wait_for_unit("k3s.service")
    machine.wait_until_succeeds(f"{admin} get node machine -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -qx True", timeout=300)
    machine.wait_until_succeeds("test -r /var/lib/rancher/k3s/agent/kubelet.kubeconfig")
    # The periodic runs are on timers; the test runs them itself.
    machine.succeed("systemctl stop nixhost-checks.timer nixhost-node-report.timer nixhost-checks.service nixhost-node-report.service")

    with subtest("the kubelet's credentials read the Node; with no pod yet, readiness is pending"):
        machine.wait_until_succeeds("systemctl start nixhost-checks.service && grep -qx 'nixhost_check_ok{check=\"node\",kind=\"health\"} 1' /var/lib/node-exporter/nixhost_checks.prom", timeout=120)
        s = status()
        assert s["health"] == "ok" and s["readiness"] == "pending", s
        assert s["checks"]["node"]["kind"] == "health" and s["checks"]["node"]["message"] == "Node machine is Ready", s
        assert s["checks"]["node-ready"]["kind"] == "readiness" and s["checks"]["node-ready"]["ok"], s
        p = s["checks"]["pod"]
        assert p["kind"] == "readiness" and not p["ok"] and p["timeout"] == 1800, p
        assert p["message"] == "0 of 0 pods app=nixhost-test in default on machine are Ready; 1 needed", p
        machine.succeed("systemctl start nixhost-reboot-detect.service nixhost-node-report.service")
        a = annotations()
        assert a["readiness"] == "pending" and a["readiness-failing"] == "pod", a

    with subtest("once the pod on this node is Ready, readiness is ok"):
        machine.wait_until_succeeds(f"{admin} get serviceaccount default")
        machine.succeed(f"{admin} apply -f ${pod}")
        machine.succeed(f"{admin} wait --for=condition=Ready pod/nixhost-test --timeout=180s")
        machine.succeed("systemctl start nixhost-checks.service")
        s = status()
        assert s["readiness"] == "ok" and s["health"] == "ok", s
        assert s["checks"]["pod"]["message"] == "1 of 1 pods app=nixhost-test in default on machine are Ready", s

    with subtest("the Node reporter's annotations, with the kubelet's boot ID and kernel"):
        machine.succeed("systemctl start nixhost-node-report.service")
        n = node()
        a = annotations()
        info = n["status"]["nodeInfo"]
        print(a)
        assert a["boot-id"] == info["bootID"] == sh("cat /proc/sys/kernel/random/boot_id"), (a, info)
        assert a["kernel"] == info["kernelVersion"] == sh("uname -r"), (a, info)
        assert a["revision"] == "${revision}" and a["boot-revision"] == "${revision}", a
        assert a["health"] == "ok" and a["readiness"] == "ok" and a["readiness-failing"] == "", a
        assert a["reboot-required"] == "false" and a["reboot-held"] == "", a
        assert a["rollbacks"] == "0" and a["rollback-breaker"] == "closed", a
        assert a["trial"] == "none" and a["boot-check"] == "none", a
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", a["reported-at"]), a
        # Unchanged values aren't written again within 10 minutes.
        machine.succeed("systemctl start nixhost-node-report.service")
        assert annotations()["reported-at"] == a["reported-at"]
  '';
}
