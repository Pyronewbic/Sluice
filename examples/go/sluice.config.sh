# sluice config - scaffolded by 'sluice init' (detected: go).
# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist).

SLUICE_EXTRA_PKGS="go"
SLUICE_PORTS="8080"            # ports to publish (the app MUST bind 0.0.0.0)
SLUICE_RUN_CMD="go run ."
SLUICE_ALLOW_DOMAINS="proxy.golang.org sum.golang.org"    # runtime egress hosts (or run 'sluice learn')
