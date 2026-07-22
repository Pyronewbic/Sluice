# Hard-cap demo: the README's honest caveat made PREVENTIVE. ONE allowlisted host the box is genuinely
# allowed to reach (httpbin.org), plus SLUICE_EGRESS_HARD_CAP_BYTES set just above the 1 MiB floor. The
# workload first proves the host is reachable (warm GET), then launders 4 MiB OUT to that same allowed
# host - and the in-box xt_quota DROP kills the flow mid-upload at the cap: curl aborts non-zero with a
# truncated body. The receipt shows bytes pinned near the cap - BOUNDED, not zero. Preventive (stops
# bytes on the wire), unlike the detective SLUICE_EGRESS_MAX_BYTES that only gates after the fact.
SLUICE_DESC="hard-cap: preventive per-boot egress byte ceiling"
SLUICE_ALLOW_DOMAINS="httpbin.org"
SLUICE_EGRESS_HARD_CAP_BYTES=1258291
SLUICE_RUN_CMD='sh demo.sh'
