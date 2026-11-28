# nixhost-smart: the SMART state of the drives smartd watches, as textfile
# metrics (monitoring/smart.nix). Read-only: smartctl -j -a on each.
# shellcheck shell=bash

accepted=$(jq -c '.acceptedSerials' "$SETTINGS")

# The scan smartd's DEVICESCAN uses: SATA, SAS, NVMe and drives behind
# MegaRAID controllers, each with a type (scsi, nvme, megaraid,N, a USB
# bridge's). It reads sysfs and doesn't open the drives. Before any output,
# so a failed scan leaves the last metrics in place.
devices=$(timeout 60 smartctl --scan -j | jq -r '.devices[]? | [.name, .type] | @tsv')

{
  echo "# HELP nixhost_smart_read_ok 1 when smartctl read the drive's SMART data, 0 when it couldn't open or read it, or hung."
  echo "# TYPE nixhost_smart_read_ok gauge"
  echo "# HELP nixhost_smart_healthy 1 while the drive's overall SMART health passes, 0 when it fails."
  echo "# TYPE nixhost_smart_healthy gauge"
  echo "# HELP nixhost_smart_accepted 1 for a drive kept on purpose although failing (smart.acceptedSerials)."
  echo "# TYPE nixhost_smart_accepted gauge"
  echo "# HELP nixhost_smart_nvme_critical_warning The NVMe critical warning bits (0 is none)."
  echo "# TYPE nixhost_smart_nvme_critical_warning gauge"
  echo "# HELP nixhost_smart_nvme_percentage_used The NVMe wear estimate, in percent of its rated endurance (can pass 100)."
  echo "# TYPE nixhost_smart_nvme_percentage_used gauge"
  echo "# HELP nixhost_smart_nvme_available_spare_percent The NVMe spare capacity left, in percent."
  echo "# TYPE nixhost_smart_nvme_available_spare_percent gauge"
  echo "# HELP nixhost_smart_nvme_available_spare_threshold_percent The spare below which the NVMe reports a critical warning."
  echo "# TYPE nixhost_smart_nvme_available_spare_threshold_percent gauge"
  echo "# HELP nixhost_smart_nvme_media_errors_total NVMe unrecovered data integrity errors."
  echo "# TYPE nixhost_smart_nvme_media_errors_total counter"
  echo "# HELP nixhost_smart_ata_reallocated_sectors ATA attribute 5, sectors remapped to spares."
  echo "# TYPE nixhost_smart_ata_reallocated_sectors gauge"
  echo "# HELP nixhost_smart_ata_pending_sectors ATA attribute 197, sectors waiting to be remapped."
  echo "# TYPE nixhost_smart_ata_pending_sectors gauge"
  echo "# HELP nixhost_smart_ata_offline_uncorrectable ATA attribute 198, sectors the offline scan couldn't read."
  echo "# TYPE nixhost_smart_ata_offline_uncorrectable gauge"
  echo "# HELP nixhost_smart_temperature_celsius The drive's temperature."
  echo "# TYPE nixhost_smart_temperature_celsius gauge"
  echo "# HELP nixhost_smart_power_on_seconds_total How long the drive has been powered on."
  echo "# TYPE nixhost_smart_power_on_seconds_total counter"
  while IFS=$'\t' read -r name type; do
    [ -n "$name" ] || continue
    # A plain "scsi" from the scan is detected when opened, so a SATA drive
    # behind it reads as sat. smartctl's exit status is a bit mask that is
    # non-zero for a failing drive; its JSON says what it read either way. A
    # failing drive can hang it, so each drive gets a minute.
    detect=$type
    [ "$detect" != scsi ] || detect=auto
    json=$(timeout 60 smartctl -j -a -d "$detect" "$name" 2>/dev/null || true)
    if ! jq -e '.smartctl' >/dev/null 2>&1 <<<"$json"; then
      printf 'nixhost_smart_read_ok{device="%s",type="%s",serial="",model=""} 0\n' "${name#/dev/}" "$type"
      continue
    fi
    jq -r --arg d "${name#/dev/}" --arg t "$type" --argjson accepted "$accepted" -f "$METRICS_JQ" <<<"$json"
  done <<<"$devices"
} | write_metrics smart
