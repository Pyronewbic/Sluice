# Hard-cap demo: the README's honest caveat made PREVENTIVE. ONE allowlisted host the box is genuinely
# allowed to reach (httpbin.org), plus SLUICE_EGRESS_HARD_CAP_BYTES set just above the 1 MiB floor. The
# workload first proves the host is reachable (warm GET), then launders 4 MiB OUT to that same allowed
# host - and the in-box xt_quota DROP kills the flow mid-upload at the cap: curl aborts non-zero with a
# truncated body. The receipt shows bytes pinned near the cap - BOUNDED, not zero. Preventive (stops
# bytes on the wire), unlike the detective SLUICE_EGRESS_MAX_BYTES that only gates after the fact.
SLUICE_DESC="hard-cap: preventive per-boot egress byte ceiling"
SLUICE_ALLOW_DOMAINS="httpbin.org"
SLUICE_EGRESS_HARD_CAP_BYTES=1258291
SLUICE_RUN_CMD='printf ">> httpbin.org is allowlisted - the box really can reach it:\n"; curl -sS --max-time 8 -o /dev/null -w "   warm GET ok (http %{http_code})\n" https://httpbin.org/get; printf ">> now launder 4 MiB OUT to that same allowed host (the honest caveat):\n"; head -c 4194304 /dev/urandom | curl -sS --max-time 8 -o /dev/null -w "   uploaded %{size_upload} of 4194304 bytes before the wire went dead\n" -T - https://httpbin.org/anything; printf "   curl exit=%s (non-zero: killed mid-flight by the cap)\n" "$?"; sleep 1'
