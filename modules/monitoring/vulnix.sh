# Scan the running system's runtime closure with vulnix and export what it
# reports (CVEs whitelisted in the configuration aside) as nixhost_vulnix_*.
# The results stay until the next successful scan; nixhost_vulnix_last_run_ok
# says whether the latest one worked.
now=$(date +%s)
report=$(mktemp)
trap 'rm -f "$report"' EXIT

args=(--closure --json --cache-dir "$CACHE_DIRECTORY")
[ -z "$WHITELIST" ] || args+=(--whitelist "$WHITELIST")
# 0: nothing found, 2: something found (or an error, which prints no JSON).
vulnix "${args[@]}" "$(readlink -f /run/current-system)" >"$report" || true

ok=0
if jq -e 'type == "array"' "$report" >/dev/null 2>&1; then
  ok=1
  jq -r --argjson max "$MAX_SERIES" --argjson now "$now" '
    def severity: if . == null then "unknown" elif . >= 9 then "critical" elif . >= 7 then "high"
      elif . >= 4 then "medium" else "low" end;
    # One entry per package name and CVE, with its CVSS v3 score if NVD has one.
    [.[] | . as $p | .affected_by[] | {package: $p.name, cve: ., score: $p.cvssv3_basescore[.]}]
    | unique_by([.package, .cve]) as $hits
    | ($hits | group_by(.package) | map({package: .[0].package, cves: length, max: (map(.score // 0) | max)})
       | sort_by(-.max, -.cves, .package)) as $packages
    | "# HELP nixhost_vulnix_vulnerable_packages Packages in the running system with CVEs vulnix reports.",
      "# TYPE nixhost_vulnix_vulnerable_packages gauge",
      "nixhost_vulnix_vulnerable_packages \($packages | length)",
      "# HELP nixhost_vulnix_cves CVEs reported per package, by CVSS v3 severity (critical >= 9, high >= 7, medium >= 4).",
      "# TYPE nixhost_vulnix_cves gauge",
      (["critical", "high", "medium", "low", "unknown"][] as $s
        | "nixhost_vulnix_cves{severity=\"\($s)\"} \([$hits[] | select((.score | severity) == $s)] | length)"),
      "# HELP nixhost_vulnix_package_cves CVEs per package, the most severe packages first, at most \($max).",
      "# TYPE nixhost_vulnix_package_cves gauge",
      ($packages[:$max][] | "nixhost_vulnix_package_cves{package=\"\(.package)\",max_cvss=\"\(.max)\"} \(.cves)"),
      "# HELP nixhost_vulnix_cve_info Critical and high CVEs, the most severe first, at most \($max).",
      "# TYPE nixhost_vulnix_cve_info gauge",
      ([$hits[] | select(.score != null and .score >= 7)] | sort_by(-.score, .package, .cve)
        | .[:$max][] | "nixhost_vulnix_cve_info{package=\"\(.package)\",cve=\"\(.cve)\",cvss=\"\(.score)\",severity=\"\(.score | severity)\"} 1"),
      "# HELP nixhost_vulnix_last_success_timestamp_seconds When the last successful scan finished.",
      "# TYPE nixhost_vulnix_last_success_timestamp_seconds gauge",
      "nixhost_vulnix_last_success_timestamp_seconds \($now)"
  ' "$report" | write_metrics nixhost_vulnix
fi

{
  echo "# HELP nixhost_vulnix_last_run_ok Whether the latest vulnix scan produced a report."
  echo "# TYPE nixhost_vulnix_last_run_ok gauge"
  echo "nixhost_vulnix_last_run_ok $ok"
  echo "# HELP nixhost_vulnix_last_run_timestamp_seconds When vulnix last ran."
  echo "# TYPE nixhost_vulnix_last_run_timestamp_seconds gauge"
  echo "nixhost_vulnix_last_run_timestamp_seconds $now"
} | write_metrics nixhost_vulnix_run
# A failed scan (NVD unreachable, say) shows in nixhost_vulnix_last_run_ok,
# not as a failed unit.
[ "$ok" = 1 ] || echo "vulnix produced no report; see its output above" >&2
