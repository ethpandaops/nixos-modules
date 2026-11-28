# One drive's smartctl -j -a output to nixhost_smart_* lines, for
# smart.sh. $d is the device name, $t its smartctl type, $accepted the
# accepted serials. A device that has no SMART at all gets no lines; smartd
# skips it too.
def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
def line($name; $labels; $value): select($value != null) | "\($name){\($labels)} \($value)";
def ata($id): [.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value] | first;

select(.smart_support.available != false)
| (.serial_number // "") as $serial
| "device=\"\($d)\",type=\"\($t)\",serial=\"\($serial | esc)\",model=\"\(.model_name // "" | esc)\"" as $l
| (.nvme_smart_health_information_log // null) as $n
| (if .smart_status.passed == null then null elif .smart_status.passed then 1 else 0 end) as $healthy
| line("nixhost_smart_read_ok"; $l; if .smart_status == null then 0 else 1 end),
  line("nixhost_smart_healthy"; $l; $healthy),
  line("nixhost_smart_accepted"; $l; if any($accepted[]; . == $serial) then 1 else 0 end),
  (if $n then
    line("nixhost_smart_nvme_critical_warning"; $l; $n.critical_warning),
    line("nixhost_smart_nvme_percentage_used"; $l; $n.percentage_used),
    line("nixhost_smart_nvme_available_spare_percent"; $l; $n.available_spare),
    line("nixhost_smart_nvme_available_spare_threshold_percent"; $l; $n.available_spare_threshold),
    line("nixhost_smart_nvme_media_errors_total"; $l; $n.media_errors)
  else
    line("nixhost_smart_ata_reallocated_sectors"; $l; ata(5)),
    line("nixhost_smart_ata_pending_sectors"; $l; ata(197)),
    line("nixhost_smart_ata_offline_uncorrectable"; $l; ata(198))
  end),
  line("nixhost_smart_temperature_celsius"; $l; .temperature.current),
  line("nixhost_smart_power_on_seconds_total"; $l; .power_on_time | select(.hours != null) | .hours * 3600 + (.minutes // 0) * 60)
