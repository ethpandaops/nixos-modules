# fluent-bit's input and delivery counters, as node-exporter textfile metrics.
# nixhost_logs_up is 0 while fluent-bit doesn't answer.
if metrics=$(curl -sf --max-time 10 "http://127.0.0.1:$PORT/api/v2/metrics/prometheus"); then
  {
    echo "# HELP nixhost_logs_up Whether fluent-bit, which ships the journal, answers."
    echo "# TYPE nixhost_logs_up gauge"
    echo "nixhost_logs_up 1"
    grep -E '^(# (HELP|TYPE) )?fluentbit_(input_records|output_(proc_records|errors|retries_failed|dropped_records))_total[ {]' <<<"$metrics"
  } | write_metrics nixhost_logs
else
  printf '%s\n' \
    "# HELP nixhost_logs_up Whether fluent-bit, which ships the journal, answers." \
    "# TYPE nixhost_logs_up gauge" \
    "nixhost_logs_up 0" | write_metrics nixhost_logs
fi
