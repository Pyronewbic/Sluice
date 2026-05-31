# sluice config - scaffolded by 'sluice init' (detected: deno).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).
# NOTE: set SLUICE_PORTS to the port your server binds (Fresh defaults to 8000).

SLUICE_EXTRA_PKGS="deno"
SLUICE_PORTS="8000"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="deno task dev"
SLUICE_ALLOW_DOMAINS="deno.land jsr.io registry.npmjs.org esm.sh cdn.jsdelivr.net"    # runtime egress hosts (or run 'sluice learn')
