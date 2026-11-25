# A ban list payload (verified already) -> {error, detail}, or what to load:
# {generation, previous, generated_at, mode, entries: [{family, cidr, timeout}]}
# with expired entries left out. Fields it doesn't know are ignored.
# Arguments: $now (unix seconds).
def whole: type == "number" and . == floor and . >= 0;
def fail($reason; $detail): {error: $reason, detail: $detail};
def v4: "^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}/(?<p>[0-9]{1,2})$";
def v6: "^[0-9a-fA-F:.]*:[0-9a-fA-F:.]*/(?<p>[0-9]{1,3})$";
def entry:
  if type != "object" or (.cidr | type) != "string" or (.expires | whole | not) then null
  elif .cidr | test(v4) then {family: 4, cidr, expires, prefix: (.cidr | capture(v4).p | tonumber)}
  elif .cidr | test(v6) then {family: 6, cidr, expires, prefix: (.cidr | capture(v6).p | tonumber)}
  else null end;

if type != "object" or .version != 1 then fail("invalid"; "not a version 1 list")
elif (.generation | whole | not) or ((.previous_generation // 0) | whole | not) or (.generated_at | whole | not) then
  fail("invalid"; "generation, previous_generation or generated_at isn't a whole number")
elif (.mode | IN("enforce", "shadow", "empty") | not) then fail("invalid"; "unknown mode \(.mode)")
elif (.entries | type) != "array" then fail("invalid"; "entries isn't a list")
elif .generated_at < $now - 600 then fail("stale"; "generation \(.generation) was signed \($now - .generated_at)s ago")
elif .generated_at > $now + 300 then fail("stale"; "generation \(.generation) is signed \(.generated_at - $now)s in the future")
elif .mode == "empty" and (.entries | length) > 0 then fail("invalid"; "mode empty, with entries")
elif (.entries | length) > 5000 then fail("too_many"; "\(.entries | length) entries, more than 5000")
else
  (.entries | map(entry)) as $e
  | ($e | map(select(. != null and ((.family == 4 and .prefix <= 32) or (.family == 6 and .prefix <= 128))))) as $ok
  | ($ok | map(select((.family == 4 and .prefix < 24) or (.family == 6 and .prefix < 48)))) as $wide
  | ($ok | map(select(.family == 4) | pow(2; 32 - .prefix)) | add // 0) as $v4
  | ($ok | map(select(.family == 6) | pow(2; 64 - ([.prefix, 64] | min))) | add // 0) as $v6
  | if ($ok | length) < ($e | length) then fail("invalid"; "\(($e | length) - ($ok | length)) entries aren't an IPv4 or IPv6 CIDR with an expiry")
    elif $wide != [] then fail("too_wide"; "wider than /24 or /48: \($wide | map(.cidr) | .[:5] | join(" "))")
    elif $v4 > 1048576 then fail("coverage"; "covers \($v4) IPv4 addresses, more than 2^20")
    elif $v6 > 1048576 then fail("coverage"; "covers \($v6) IPv6 /64s, more than 2^20")
    else {
      generation,
      previous: (.previous_generation // 0),
      generated_at,
      mode,
      entries: [$ok[] | select(.expires > $now) | {family, cidr, timeout: ([.expires - $now, 2147483] | min)}]
    } end
end
