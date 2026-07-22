#!/bin/sh
# Hard-cap demo workload. Copied into the fixture as demo.sh; the config runs it via
# SLUICE_RUN_CMD='sh demo.sh' so `cat sluice.config.sh` shows POSTURE (the allowlist + the cap),
# not 500 characters of curl.
#
# Every verdict below is DERIVED from the observed result. The previous version printed
# "non-zero: killed mid-flight by the cap" as a literal string next to an interpolated "$?" - so a
# 503 from the upstream, a server-truncated upload and curl exiting 0 all still rendered as the cap
# working. A demo that cannot fail proves nothing; this one exits non-zero and says WHY.
set -u

CAP=1258291   # keep in sync with SLUICE_EGRESS_HARD_CAP_BYTES in sluice.config.sh
WANT=4194304  # 4 MiB - comfortably past the cap

printf '>> httpbin.org is allowlisted - prove the box really can reach it:\n'
# NB: capture without `|| echo 000` - curl's -w already emits 000 on failure, and appending another
# renders "000000". Normalise an empty capture instead.
code="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' https://httpbin.org/get 2>/dev/null)"
code="${code:-000}"
case "$code" in
  2*) printf '   warm GET ok (http %s)\n' "$code" ;;
  *)  printf '   ABORT: warm GET returned http %s - upstream is unhealthy, not a cap result.\n' "$code"
      printf '   (this run proves nothing about the cap; re-record when the host is up)\n'
      exit 1 ;;
esac

printf '>> now launder data OUT to that same allowed host (the honest caveat):\n'
# One upload cannot exhaust the cap: httpbin truncates a chunked PUT server-side well below it. So
# push repeatedly - every rejected body still crosses the wire and debits the in-box quota - until
# the cap severs the flow. The loop is bounded so a healthy upstream cannot hang the recording.
total=0; fired=0; i=0
while [ "$i" -lt 12 ]; do
  i=$((i + 1))
  sent="$(head -c "$WANT" /dev/urandom \
    | curl -sS --max-time 15 -o /dev/null -w '%{size_upload}' -T - https://httpbin.org/anything 2>/dev/null)"
  rc=$?
  total=$((total + ${sent:-0}))
  printf '   attempt %-2s  %8s bytes on the wire  (running total %s)\n' "$i" "${sent:-0}" "$total"
  # the cap severs the connection: curl dies non-zero having sent less than it was asked to.
  if [ "$rc" -ne 0 ] && [ "${sent:-0}" -lt "$WANT" ]; then fired=1; break; fi
done

if [ "$fired" -eq 1 ]; then
  printf '   => wire went dead after %s bytes (cap %s, curl exit=%s)\n' "$total" "$CAP" "$rc"
  # curl exit 28 is a TIMEOUT - which a merely slow upstream also produces. Distinguish them: the cap
  # is per-boot and severs ALL proxied egress, so the warm GET that worked seconds ago must now fail
  # too. A slow upstream would still serve it. This is what makes the run conclusive.
  printf '>> re-run the warm GET that succeeded above - the cap severs ALL egress, not one flow:\n'
  code2="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' https://httpbin.org/get)"
  code2="${code2:-000}"
  case "$code2" in
    2*) printf '   INCONCLUSIVE: http %s - egress still works, so the stall was upstream, not the cap.\n' "$code2"
        exit 1 ;;
    *)  printf '   http %s - egress is dead box-wide. CONFIRMED: the cap fired.\n' "$code2"
        exit 0 ;;
  esac
fi

printf '   => NOT capped: %s bytes crossed the wire over %s attempts without the cap severing.\n' \
  "$total" "$i"
printf '   (this run does NOT demonstrate the cap - do not ship it)\n'
exit 1
