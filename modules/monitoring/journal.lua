-- Journal entries to OTLP log records: the message as the body, the syslog
-- priority as the severity, and the fields that say where an entry came from
-- as attributes. Container output (Docker's journald log driver) is dropped.
local severities = {
  [0] = { 21, "FATAL" },
  [1] = { 21, "FATAL" },
  [2] = { 21, "FATAL" },
  [3] = { 17, "ERROR" },
  [4] = { 13, "WARN" },
  [5] = { 9, "INFO" },
  [6] = { 9, "INFO" },
  [7] = { 5, "DEBUG" },
}

local fields = {
  _SYSTEMD_UNIT = "systemd.unit",
  SYSLOG_IDENTIFIER = "syslog.identifier",
  _TRANSPORT = "journal.transport",
  _BOOT_ID = "journal.boot_id",
  _PID = "process.pid",
  _UID = "process.uid",
  _COMM = "process.command",
  _EXE = "process.executable",
  _AUDIT_SESSION = "audit.session",
  _AUDIT_LOGINUID = "audit.loginuid",
  _AUDIT_TYPE_NAME = "audit.type",
  _AUDIT_ID = "audit.id",
}

function journal_to_otlp(tag, ts, record)
  if record.CONTAINER_ID ~= nil then
    return -1, ts, record
  end
  local sev = severities[tonumber(record.PRIORITY or 6)] or severities[6]
  local out = {
    body = record.MESSAGE or "",
    severity_number = sev[1],
    severity_text = sev[2],
  }
  for key, name in pairs(fields) do
    if record[key] ~= nil then
      out[name] = record[key]
    end
  end
  if record._TRANSPORT == "audit" then
    -- An audit record's command line is the audited process's, not a logger's.
    out["process.command_line"] = record._CMDLINE
    for key, value in pairs(record) do
      local field = key:match("^_AUDIT_FIELD_(.+)$")
      if field then
        out["audit." .. field:lower()] = value
      end
    end
  end
  return 1, ts, out
end
