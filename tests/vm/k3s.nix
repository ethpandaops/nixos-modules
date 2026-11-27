# The k3s module on a single server with no network (its one image is
# preloaded), its data in a non-default data dir, snapshotting to a local
# S3 server (rclone) over TLS with the endpoint and keys from sops: the etcd guard refuses an empty
# data dir until the bootstrap file is there and removes that file once etcd
# is up, scheduled and on-demand snapshots reach the bucket, the checks pass
# through the kubelet's credentials, and logind lets the kubelet hold its
# shutdown delay.
{
  self,
  lib,
  pkgs,
  ...
}:
let
  dataDir = "/var/lib/k3s-data";
  bootstrapFile = "/var/lib/k3s-test/bootstrap-etcd";
  accessKey = "k3s-test";
  secretKey = "k3s-test-secret";

  # A throwaway age key and the secrets encrypted to it, and the S3 server's
  # self-signed certificate for s3.test.
  fixtures =
    pkgs.runCommand "k3s-test-fixtures"
      {
        nativeBuildInputs = with pkgs; [
          age
          openssl
          sops
        ];
      }
      ''
        export HOME=$TMPDIR
        mkdir $out
        age-keygen -o $out/age.key 2>/dev/null
        cat >secrets.yaml <<EOF
        etcd-s3-endpoint: s3.test:9000
        etcd-s3-access-key: ${accessKey}
        etcd-s3-secret-key: ${secretKey}
        EOF
        sops --encrypt --age "$(age-keygen -y $out/age.key)" secrets.yaml >$out/secrets.yaml
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
          -subj /CN=s3.test -addext subjectAltName=DNS:s3.test \
          -keyout $out/s3.key -out $out/s3.crt
      '';

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
in
{
  name = "k3s";

  nodes.machine = {
    imports = [ self.nixosModules.k3s ];
    virtualisation = {
      memorySize = 3072;
      diskSize = 4096;
      cores = 2;
    };

    ethpandaops.k3s = {
      package = pkgs.k3s;
      role = "server";
      inherit dataDir bootstrapFile;
      labels."example.com/pool" = "test";
      extraFlags = [ "--pause-image=test.local/pause:local" ];
      gracefulShutdown.period = 45;
      etcdSnapshots = {
        enable = true;
        schedule = "* * * * *";
        bucket = "etcd";
        folder = "test-cluster";
      };
    };
    services.k3s = {
      disable = [
        "coredns"
        "local-storage"
        "metrics-server"
        "servicelb"
        "traefik"
      ];
      images = [ image ];
    };
    environment.systemPackages = [
      pkgs.jq
      pkgs.kubectl
    ];

    ethpandaops.secrets.file = "${fixtures}/secrets.yaml";
    sops = {
      age.keyFile = "/var/lib/sops-test/age.key";
      age.sshKeyPaths = lib.mkForce [ ];
      validateSopsFiles = false;
    };
    # sops-nix won't read a key from the store.
    system.activationScripts.sopsTestKey = "install -D -m 0400 ${fixtures}/age.key /var/lib/sops-test/age.key";
    system.activationScripts.setupSecrets.deps = [ "sopsTestKey" ];

    # Buckets are the directories in /var/lib/s3.
    systemd.services.s3 = {
      wantedBy = [ "multi-user.target" ];
      environment.HOME = "/var/lib/s3";
      serviceConfig = {
        StateDirectory = "s3";
        ExecStart = "${lib.getExe pkgs.rclone} serve s3 /var/lib/s3 --addr 127.0.0.1:9000 --cert ${fixtures}/s3.crt --key ${fixtures}/s3.key --auth-key ${accessKey},${secretKey}";
      };
    };
    networking.hosts."127.0.0.1" = [ "s3.test" ];
    security.pki.certificateFiles = [ "${fixtures}/s3.crt" ];

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
    ethpandaops.checks.sshd.enable = false;
  };

  testScript = ''
    import json

    admin = "kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
    bucket = "/var/lib/s3/etcd/test-cluster"

    def sh(command):
        return machine.succeed(command).strip()

    refusals = "journalctl -u k3s.service | grep -c 'has no etcd member: not starting a new cluster'"

    machine.succeed("mkdir -p /var/lib/s3/etcd")
    machine.wait_for_open_port(9000)

    with subtest("a server with no etcd refuses to start a new cluster"):
        machine.wait_until_succeeds("journalctl -u k3s.service | grep -q 'has no etcd member'", timeout=120)
        machine.fail("systemctl is-active k3s.service")
        machine.fail("test -e ${dataDir}/server/db/etcd")

    with subtest("the bootstrap file lets it start one, and is removed once etcd is up"):
        machine.succeed("install -D /dev/null ${bootstrapFile}")
        machine.wait_for_unit("k3s.service", timeout=300)
        machine.succeed("test -d ${dataDir}/server/db/etcd/member")
        machine.wait_until_succeeds("test ! -e ${bootstrapFile}", timeout=60)
        machine.wait_until_succeeds(f"{admin} get node machine -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -qx True", timeout=300)
        assert sh(f"{admin} get node machine -o jsonpath='{{.metadata.labels.example\\.com/pool}}'") == "test"

    with subtest("the checks pass through the kubelet's credentials in the data dir"):
        machine.succeed("test -r ${dataDir}/agent/kubelet.kubeconfig")
        machine.wait_until_succeeds("systemctl start nixhost-checks.service && jq -e '.checks | (.k3s.ok and .kubelet.ok and .\"node-ready\".ok)' /run/nixhost/checks/status.json", timeout=120)
        checks = json.loads(sh("cat /run/nixhost/checks/status.json"))["checks"]
        assert all(checks[c]["kind"] == "readiness" for c in ("k3s", "kubelet", "node-ready")), checks

    with subtest("logind lets the kubelet delay shutdown for its grace period"):
        assert sh("busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager InhibitDelayMaxUSec") == "t 75000000"
        machine.wait_until_succeeds("systemd-inhibit --list --mode=delay --no-pager | grep -q kubelet", timeout=120)
        machine.succeed("test ! -e /etc/systemd/logind.conf.d/99-kubelet.conf")

    with subtest("snapshots reach the bucket: on schedule, and on demand as the pre-minor snapshot takes them"):
        assert "etcd-s3-endpoint: \"s3.test:9000\"" in sh("cat /etc/rancher/k3s/config.yaml.d/etcd-snapshots.yaml")
        machine.wait_until_succeeds(f"ls {bucket} | grep -q '^etcd-snapshot-machine-'", timeout=180)
        machine.succeed("k3s etcd-snapshot save --data-dir ${dataDir} --name pre-minor-upgrade")
        machine.succeed(f"ls {bucket} | grep -q '^pre-minor-upgrade-machine-'")
        machine.succeed("systemctl is-active k3s-pre-minor-snapshot.service")

    with subtest("a k3s version is never rolled back, nor the server's data dir"):
        guard = json.loads(sh("cat /etc/nixhost/rollback-guard.json"))
        assert guard == {"k3s-version": "${pkgs.k3s.version}", "k3s-data-dir": "${dataDir}"}, guard
        assert sh("cat /etc/nixhost/k3s-version") == "${pkgs.k3s.version}"

    with subtest("losing etcd later doesn't start a new cluster"):
        before = int(sh(refusals))
        machine.succeed("systemctl stop k3s.service")
        machine.succeed("mv ${dataDir}/server/db/etcd /root/etcd-lost")
        machine.fail("systemctl start k3s.service")
        machine.wait_until_succeeds(f"[ $({refusals}) -gt {before} ]", timeout=30)
        machine.fail("test -e ${dataDir}/server/db/etcd")
  '';
}
