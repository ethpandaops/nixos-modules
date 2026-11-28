# smartd and nixhost-smart on QEMU's emulated drives: two NVMe drives, one
# of them accepted, and a SATA disk. The VM stands in for bare metal (both
# units skip VMs), its virtio root disk for a device without SMART, and
# QEMU's smart_critical_warning for a failing drive.
{ self, lib, ... }:
let
  drive = id: "-blockdev driver=null-co,node-name=${id},size=1073741824,read-zeroes=on";
in
{
  name = "smart";

  nodes.server = {
    imports = [
      self.nixosModules.base
      self.nixosModules.monitoring
      ./notify-sink.nix
    ];
    networking.hostName = "smartbox";
    ethpandaops.host.environment = "test";
    ethpandaops.monitoring.tailscale.enable = false;
    ethpandaops.monitoring.smart.acceptedSerials = [ "NVMEACCEPTED" ];
    ethpandaops.notify.admins = [
      {
        type = "webhook";
        url = "http://127.0.0.1:8000/";
      }
    ];
    systemd.services.smartd.unitConfig.ConditionVirtualization = lib.mkForce "vm";
    systemd.services.nixhost-smart.unitConfig.ConditionVirtualization = lib.mkForce "vm";
    virtualisation.qemu.options = [
      (drive "accepted")
      "-device nvme,id=accepted,serial=NVMEACCEPTED,drive=accepted"
      (drive "failing")
      "-device nvme,id=failing,serial=NVMEFAILING,drive=failing"
      (drive "sata")
      "-device ahci,id=ahci"
      "-device ide-hd,drive=sata,bus=ahci.0,serial=SATADISK,model=TestDisk"
    ];
  };

  testScript = ''
    import json, re

    def metrics():
        server.succeed("systemctl start nixhost-smart.service")
        return server.succeed("cat /var/lib/node-exporter/smart.prom")

    def value(text, name, serial):
        m = re.search(rf'^{name}{{device="[^"]+",type="[^"]+",serial="{serial}",model="[^"]*"}} (\S+)$', text, re.M)
        assert m, f"no {name} for {serial} in:\n{text}"
        return m.group(1)

    def notices():
        log = server.succeed("cat /var/lib/notify-sink.log || true")
        return [json.loads(line.split(" ", 1)[1])["attachments"][0] for line in log.splitlines()]

    def severity(notice):
        return next(f["value"] for f in notice["fields"] if f["title"] == "Severity")

    start_all()
    server.wait_for_unit("notify-sink.service")
    server.wait_for_unit("smartd.service")
    server.succeed("systemctl stop nixhost-smart.timer")

    with subtest("every drive smartd watches has metrics, the virtio disk none"):
        m = metrics()
        print(m)
        assert len(re.findall("^nixhost_smart_read_ok", m, re.M)) == 3, m
        for serial in ["NVMEACCEPTED", "NVMEFAILING", "SATADISK"]:
            assert value(m, "nixhost_smart_read_ok", serial) == "1"
            assert value(m, "nixhost_smart_healthy", serial) == "1"
            value(m, "nixhost_smart_temperature_celsius", serial)
            value(m, "nixhost_smart_power_on_seconds_total", serial)
        assert value(m, "nixhost_smart_accepted", "NVMEACCEPTED") == "1"
        assert value(m, "nixhost_smart_accepted", "NVMEFAILING") == "0"
        assert value(m, "nixhost_smart_nvme_critical_warning", "NVMEFAILING") == "0"
        assert value(m, "nixhost_smart_ata_reallocated_sectors", "SATADISK") == "0"
        assert notices() == [], notices()

    with subtest("a failing drive is a critical notice, an accepted one info"):
        for dev in ["accepted", "failing"]:
            server.send_monitor_command(f"qom-set /machine/peripheral/{dev} smart_critical_warning 4")
        server.succeed("systemctl kill -s USR1 smartd.service")
        server.wait_until_succeeds("test $(grep -c 'Drive problem: Health' /var/lib/notify-sink.log) -eq 2", timeout=120)
        sent = {n["text"].split("S/N:")[1].split(",")[0]: n for n in notices()}
        assert severity(sent["NVMEFAILING"]) == "critical", sent
        assert severity(sent["NVMEACCEPTED"]) == "info", sent
        assert sent["NVMEACCEPTED"]["title"] == "Drive problem: Health (an accepted drive)", sent
        m = metrics()
        for serial in ["NVMEACCEPTED", "NVMEFAILING"]:
            assert value(m, "nixhost_smart_healthy", serial) == "0"
            assert value(m, "nixhost_smart_nvme_critical_warning", serial) == "4"

    with subtest("a restart doesn't repeat the notices"):
        server.succeed("systemctl restart smartd.service")
        pid = server.succeed("systemctl show -P MainPID smartd.service").strip()
        # smartd saves its state once its first check, and any notice that
        # check sends, is done.
        server.wait_until_succeeds(f"journalctl _PID={pid} -o cat | grep -q 'state written to .*NVMEFAILING'", timeout=120)
        server.succeed(f"test $(journalctl _PID={pid} -o cat | grep -c 'Critical Warning (0x04)') -eq 2")
        assert len(notices()) == 2, notices()
  '';
}
